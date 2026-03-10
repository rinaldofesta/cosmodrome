import AppKit
import Core
import Metal
import MetalKit
import simd

/// Renders terminal sessions into a single MTKView using Metal.
final class TerminalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let bgPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    private let cursorPipeline: MTLRenderPipelineState
    let atlas: GlyphAtlas
    let fontManager: FontManager

    // Triple-buffered vertex data
    private let maxVertices = 200_000
    private var vertexBuffers: [MTLBuffer]
    private var bufferIndex = 0
    private let inflightSemaphore = DispatchSemaphore(value: 3)

    // Uniforms buffer
    private var uniformsBuffer: MTLBuffer

    // Current render state
    struct SessionRenderEntry {
        let backend: TerminalBackend
        let viewport: MTLViewport
        let scissor: MTLScissorRect
    }
    var visibleSessions: [SessionRenderEntry] = []

    // Text selection (set by content view)
    var selection: TerminalSelection?

    // Theme colors (mutable for theme switching)
    private(set) var theme: ResolvedTheme

    init?(metalView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device

        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        self.theme = ResolvedTheme(theme: .dark)

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let fm = FontManager(scale: scale)
        self.fontManager = fm
        self.atlas = GlyphAtlas(device: device, fontManager: fm)

        // Create vertex buffers (triple-buffered)
        let bufferSize = maxVertices * MemoryLayout<TerminalVertex>.stride
        self.vertexBuffers = (0..<3).map { _ in
            device.makeBuffer(length: bufferSize, options: .storageModeShared)!
        }

        // Create uniforms buffer
        self.uniformsBuffer = device.makeBuffer(
            length: MemoryLayout<TerminalUniforms>.stride,
            options: .storageModeShared
        )!

        // Compile shaders
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: metalShaderSource, options: nil)
        } catch {
            FileHandle.standardError.write("[Cosmodrome] Failed to compile Metal shaders: \(error)\n".data(using: .utf8)!)
            return nil
        }

        // Vertex descriptor
        let vertexDesc = MTLVertexDescriptor()
        vertexDesc.attributes[0].format = .float2
        vertexDesc.attributes[0].offset = 0
        vertexDesc.attributes[0].bufferIndex = 0
        vertexDesc.attributes[1].format = .float2
        vertexDesc.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
        vertexDesc.attributes[1].bufferIndex = 0
        vertexDesc.attributes[2].format = .float4
        vertexDesc.attributes[2].offset = MemoryLayout<SIMD2<Float>>.stride * 2
        vertexDesc.attributes[2].bufferIndex = 0
        vertexDesc.layouts[0].stride = MemoryLayout<TerminalVertex>.stride
        vertexDesc.layouts[0].stepRate = 1
        vertexDesc.layouts[0].stepFunction = .perVertex

        func makePipeline(vertex: String, fragment: String) -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: vertex)
            desc.fragmentFunction = library.makeFunction(name: fragment)
            desc.vertexDescriptor = vertexDesc
            desc.colorAttachments[0].pixelFormat = metalView.colorPixelFormat
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try! device.makeRenderPipelineState(descriptor: desc)
        }

        self.bgPipeline = makePipeline(vertex: "bg_vert", fragment: "bg_frag")
        self.glyphPipeline = makePipeline(vertex: "glyph_vert", fragment: "glyph_frag")
        self.cursorPipeline = makePipeline(vertex: "cursor_vert", fragment: "cursor_frag")

        super.init()

        metalView.device = device
        metalView.delegate = self
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.layer?.isOpaque = true
        metalView.clearColor = MTLClearColor(
            red: Double(theme.background.x),
            green: Double(theme.background.y),
            blue: Double(theme.background.z),
            alpha: 1.0
        )
        // Continuous rendering at display refresh rate
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
        metalView.preferredFramesPerSecond = 60
    }

    /// Apply a new theme. Call from main thread.
    func applyTheme(_ newTheme: Theme, metalView: MTKView) {
        theme = ResolvedTheme(theme: newTheme)
        metalView.clearColor = MTLClearColor(
            red: Double(theme.background.x),
            green: Double(theme.background.y),
            blue: Double(theme.background.z),
            alpha: 1.0
        )
        metalView.needsDisplay = true
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor else { return }

        inflightSemaphore.wait()

        let buffer = vertexBuffers[bufferIndex]
        bufferIndex = (bufferIndex + 1) % 3

        let viewWidth = Float(view.drawableSize.width)
        let viewHeight = Float(view.drawableSize.height)

        // Update uniforms
        var uniforms = TerminalUniforms(
            projectionMatrix: orthographicProjection(width: viewWidth, height: viewHeight)
        )
        memcpy(uniformsBuffer.contents(), &uniforms, MemoryLayout<TerminalUniforms>.stride)

        // We use 3 passes through the vertex buffer:
        // 1. Background quads
        // 2. Glyph quads
        // 3. Cursor quads
        // All written sequentially into the buffer.

        let vertexPtr = buffer.contents().bindMemory(to: TerminalVertex.self, capacity: maxVertices)
        var bgCount = 0
        var glyphCount = 0
        var cursorCount = 0

        // Reserve sections: backgrounds from 0, glyphs from maxVertices/3, cursors from 2*maxVertices/3
        let bgBase = 0
        let glyphBase = maxVertices / 3
        let cursorBase = 2 * maxVertices / 3

        for entry in visibleSessions {
            let backend = entry.backend
            let cellW = Float(fontManager.cellMetrics.width)
            let cellH = Float(fontManager.cellMetrics.height)
            let baseline = Float(fontManager.cellMetrics.baseline)

            let offsetX = Float(entry.viewport.originX)
            let offsetY = Float(entry.viewport.originY)

            // Hold the backend lock for the entire read pass — prevents the I/O
            // thread from mutating SwiftTerm's internal buffers while we read cells.
            backend.lock()

            let rows = backend.rows
            let cols = backend.cols

            for row in 0..<rows {
                let y = offsetY + Float(row) * cellH

                for col in 0..<cols {
                    let cell = backend.cell(row: row, col: col)
                    let x = offsetX + Float(col) * cellW

                    // Resolve colors, swapping fg/bg if inverse attribute is set
                    let isInverse = cell.attrs.contains(.inverse)
                    var bgColor = resolveColor(isInverse ? cell.fg : cell.bg, isBackground: !isInverse)
                    var fgColor = resolveColor(isInverse ? cell.bg : cell.fg, isBackground: isInverse)

                    // For inverse cells with default colors, use theme fg/bg swap
                    if isInverse {
                        if cell.fg == .default { bgColor = theme.foreground }
                        if cell.bg == .default { fgColor = theme.background }
                    }

                    // Background (including selection highlight)
                    let isSelected = selection?.contains(row: row, col: col) ?? false
                    if isSelected {
                        bgColor = SIMD4<Float>(0.3, 0.5, 0.8, 0.5) // Blue selection highlight
                    }
                    if bgColor != theme.background || isSelected || isInverse {
                        let idx = bgBase + bgCount
                        guard idx + 6 <= glyphBase else { break }
                        addQuad(
                            ptr: vertexPtr, at: idx,
                            x: x, y: y, w: cellW, h: cellH,
                            u0: 0, v0: 0, u1: 0, v1: 0,
                            color: bgColor
                        )
                        bgCount += 6
                    }

                    // Glyph
                    let cp = cell.codepoint
                    guard cp > 32 else { continue }

                    let variant = FontManager.variant(from: cell.attrs)
                    let key = GlyphAtlas.GlyphKey(codepoint: cp, fontVariant: variant)
                    let glyph = atlas.lookup(key)
                    guard glyph.size.x > 0 && glyph.size.y > 0 else { continue }

                    let idx = glyphBase + glyphCount
                    guard idx + 6 <= cursorBase else { break }
                    // Snap to integer pixel positions for crisp rendering with nearest-neighbor sampling
                    let gx = roundf(x + glyph.bearing.x)
                    let gy = roundf(y + baseline - glyph.bearing.y)

                    addQuad(
                        ptr: vertexPtr, at: idx,
                        x: gx, y: gy, w: glyph.size.x, h: glyph.size.y,
                        u0: glyph.uv.x, v0: glyph.uv.y,
                        u1: glyph.uv.z, v1: glyph.uv.w,
                        color: fgColor
                    )
                    glyphCount += 6
                }
            }

            // Cursor (only if visible)
            if backend.isCursorVisible {
                let (cursorRow, cursorCol) = backend.cursorPosition()
                let cursorX = offsetX + Float(cursorCol) * cellW
                let cursorY = offsetY + Float(cursorRow) * cellH

                // Adjust cursor size based on style
                let cursorW: Float
                let cursorH: Float
                let cursorYOffset: Float
                switch backend.cursorStyle {
                case .block:
                    cursorW = cellW
                    cursorH = cellH
                    cursorYOffset = 0
                case .bar:
                    cursorW = max(2, cellW * 0.12)
                    cursorH = cellH
                    cursorYOffset = 0
                case .underline:
                    cursorW = cellW
                    cursorH = max(2, cellH * 0.1)
                    cursorYOffset = cellH - max(2, cellH * 0.1)
                }

                let idx = cursorBase + cursorCount
                if idx + 6 <= maxVertices {
                    addQuad(
                        ptr: vertexPtr, at: idx,
                        x: cursorX, y: cursorY + cursorYOffset, w: cursorW, h: cursorH,
                        u0: 0, v0: 0, u1: 0, v1: 0,
                        color: SIMD4<Float>(theme.cursor.x, theme.cursor.y, theme.cursor.z, 0.85)
                    )
                    cursorCount += 6
                }
            }

            backend.clearDirty()
            backend.unlock()
        }

        // Encode
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inflightSemaphore.signal()
            return
        }

        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inflightSemaphore.signal()
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            inflightSemaphore.signal()
            return
        }

        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uniformsBuffer, offset: 0, index: 1)

        // Draw backgrounds
        if bgCount > 0 {
            encoder.setRenderPipelineState(bgPipeline)
            encoder.drawPrimitives(type: .triangle, vertexStart: bgBase, vertexCount: bgCount)
        }

        // Draw glyphs
        if glyphCount > 0 {
            encoder.setRenderPipelineState(glyphPipeline)
            if let tex = atlas.currentTexture {
                encoder.setFragmentTexture(tex, index: 0)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: glyphBase, vertexCount: glyphCount)
        }

        // Draw cursors
        if cursorCount > 0 {
            encoder.setRenderPipelineState(cursorPipeline)
            encoder.drawPrimitives(type: .triangle, vertexStart: cursorBase, vertexCount: cursorCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Vertex Helpers

    private func addQuad(
        ptr: UnsafeMutablePointer<TerminalVertex>,
        at index: Int,
        x: Float, y: Float, w: Float, h: Float,
        u0: Float, v0: Float, u1: Float, v1: Float,
        color: SIMD4<Float>
    ) {
        let p = ptr.advanced(by: index)
        p[0] = TerminalVertex(position: SIMD2(x, y), texCoord: SIMD2(u0, v0), color: color)
        p[1] = TerminalVertex(position: SIMD2(x + w, y), texCoord: SIMD2(u1, v0), color: color)
        p[2] = TerminalVertex(position: SIMD2(x, y + h), texCoord: SIMD2(u0, v1), color: color)
        p[3] = TerminalVertex(position: SIMD2(x + w, y), texCoord: SIMD2(u1, v0), color: color)
        p[4] = TerminalVertex(position: SIMD2(x + w, y + h), texCoord: SIMD2(u1, v1), color: color)
        p[5] = TerminalVertex(position: SIMD2(x, y + h), texCoord: SIMD2(u0, v1), color: color)
    }

    // MARK: - Color Resolution

    private func resolveColor(_ color: TerminalColor, isBackground: Bool) -> SIMD4<Float> {
        switch color {
        case .default:
            return isBackground ? theme.background : theme.foreground
        case .indexed(let idx):
            if idx < 16 {
                return theme.ansiColors[Int(idx)]
            } else if idx < 232 {
                let i = Int(idx) - 16
                let r = Float(i / 36) / 5.0
                let g = Float((i / 6) % 6) / 5.0
                let b = Float(i % 6) / 5.0
                return SIMD4<Float>(r, g, b, 1.0)
            } else {
                let gray = Float(Int(idx) - 232) / 23.0
                return SIMD4<Float>(gray, gray, gray, 1.0)
            }
        case .rgb(let r, let g, let b):
            return SIMD4<Float>(Float(r) / 255.0, Float(g) / 255.0, Float(b) / 255.0, 1.0)
        }
    }
}
