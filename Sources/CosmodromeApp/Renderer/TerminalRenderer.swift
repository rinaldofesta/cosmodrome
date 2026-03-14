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
        var isFocused: Bool = true
    }
    var visibleSessions: [SessionRenderEntry] = []

    // Text selection (set by content view)
    var selection: TerminalSelection?

    // Cursor blink opacity (set by content view's smooth blink timer)
    // Focused sessions use this animated value; unfocused sessions show a static dim cursor.
    var cursorOpacity: Float = 1.0

    // Theme colors (mutable for theme switching)
    private(set) var theme: ResolvedTheme

    init?(metalView: MTKView, userConfig: UserConfig? = nil) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device

        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        self.theme = ResolvedTheme(theme: .dark)

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let fm = FontManager(config: userConfig?.font, scale: scale)
        self.fontManager = fm
        self.atlas = GlyphAtlas(device: device, fontManager: fm)

        // Create vertex buffers (triple-buffered)
        let bufferSize = maxVertices * MemoryLayout<TerminalVertex>.stride
        let buffers = (0..<3).compactMap { _ in
            device.makeBuffer(length: bufferSize, options: .storageModeShared)
        }
        guard buffers.count == 3 else { return nil }
        self.vertexBuffers = buffers

        // Create uniforms buffer
        guard let uniformsBuf = device.makeBuffer(
            length: MemoryLayout<TerminalUniforms>.stride,
            options: .storageModeShared
        ) else { return nil }
        self.uniformsBuffer = uniformsBuf

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

        func makePipeline(vertex: String, fragment: String) -> MTLRenderPipelineState? {
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
            return try? device.makeRenderPipelineState(descriptor: desc)
        }

        guard let bg = makePipeline(vertex: "bg_vert", fragment: "bg_frag"),
              let glyph = makePipeline(vertex: "glyph_vert", fragment: "glyph_frag"),
              let cursor = makePipeline(vertex: "cursor_vert", fragment: "cursor_frag") else {
            FileHandle.standardError.write("[Cosmodrome] Failed to create render pipelines\n".data(using: .utf8)!)
            return nil
        }
        self.bgPipeline = bg
        self.glyphPipeline = glyph
        self.cursorPipeline = cursor

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

    /// Per-session vertex range for scissor-isolated drawing.
    private struct DrawRange {
        let scissor: MTLScissorRect
        let bgStart: Int
        var bgCount: Int
        let glyphStart: Int
        var glyphCount: Int
        let cursorStart: Int
        var cursorCount: Int
    }

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

        var drawRanges: [DrawRange] = []

        for entry in visibleSessions {
            let backend = entry.backend
            let cellW = Float(fontManager.cellMetrics.width)
            let cellH = Float(fontManager.cellMetrics.height)
            let baseline = Float(fontManager.cellMetrics.baseline)

            let offsetX = Float(entry.viewport.originX)
            let offsetY = Float(entry.viewport.originY)

            // Track per-session vertex offsets for scissor-rect drawing
            let sessionBgStart = bgCount
            let sessionGlyphStart = glyphCount
            let sessionCursorStart = cursorCount

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

                    // Block drawing characters (U+2580-U+259F): render procedurally
                    // as exact-cell-sized rectangles instead of font glyphs. This ensures
                    // block elements tile seamlessly (no gaps from font metrics mismatch).
                    if cp >= 0x2580 && cp <= 0x259F {
                        let rects = blockElementRects(cp, cellW: cellW, cellH: cellH)
                        var blockOverflow = false
                        for rect in rects {
                            let idx = bgBase + bgCount
                            guard idx + 6 <= glyphBase else { blockOverflow = true; break }
                            addQuad(
                                ptr: vertexPtr, at: idx,
                                x: x + rect.x, y: y + rect.y,
                                w: rect.w, h: rect.h,
                                u0: 0, v0: 0, u1: 0, v1: 0,
                                color: SIMD4(fgColor.x, fgColor.y, fgColor.z, fgColor.w * rect.alpha)
                            )
                            bgCount += 6
                        }
                        if blockOverflow { break }
                        continue
                    }

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

            // Cursor (only if visible; hide when scrolled back since position is yBase-relative)
            if backend.isCursorVisible && !backend.isScrolledBack {
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

                // Cursor opacity: focused sessions get smooth blink, unfocused get static dim
                let alpha: Float
                if entry.isFocused {
                    alpha = cursorOpacity  // Animated smooth blink (0.3..1.0)
                } else {
                    alpha = 0.30           // Static dim cursor for unfocused sessions
                }

                let idx = cursorBase + cursorCount
                if idx + 6 <= maxVertices {
                    addQuad(
                        ptr: vertexPtr, at: idx,
                        x: cursorX, y: cursorY + cursorYOffset, w: cursorW, h: cursorH,
                        u0: 0, v0: 0, u1: 0, v1: 0,
                        color: SIMD4<Float>(theme.cursor.x, theme.cursor.y, theme.cursor.z, alpha)
                    )
                    cursorCount += 6
                }
            }

            backend.clearDirty()
            backend.unlock()

            // Record per-session draw range for scissor-isolated rendering
            drawRanges.append(DrawRange(
                scissor: entry.scissor,
                bgStart: bgBase + sessionBgStart,
                bgCount: bgCount - sessionBgStart,
                glyphStart: glyphBase + sessionGlyphStart,
                glyphCount: glyphCount - sessionGlyphStart,
                cursorStart: cursorBase + sessionCursorStart,
                cursorCount: cursorCount - sessionCursorStart
            ))
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

        let drawableW = Int(view.drawableSize.width)
        let drawableH = Int(view.drawableSize.height)

        // Draw backgrounds (per-session with scissor rects)
        encoder.setRenderPipelineState(bgPipeline)
        for range in drawRanges where range.bgCount > 0 {
            encoder.setScissorRect(clampedScissor(range.scissor, drawableW: drawableW, drawableH: drawableH))
            encoder.drawPrimitives(type: .triangle, vertexStart: range.bgStart, vertexCount: range.bgCount)
        }

        // Draw glyphs (per-session with scissor rects)
        encoder.setRenderPipelineState(glyphPipeline)
        if let tex = atlas.currentTexture {
            encoder.setFragmentTexture(tex, index: 0)
        }
        for range in drawRanges where range.glyphCount > 0 {
            encoder.setScissorRect(clampedScissor(range.scissor, drawableW: drawableW, drawableH: drawableH))
            encoder.drawPrimitives(type: .triangle, vertexStart: range.glyphStart, vertexCount: range.glyphCount)
        }

        // Draw cursors (per-session with scissor rects)
        encoder.setRenderPipelineState(cursorPipeline)
        for range in drawRanges where range.cursorCount > 0 {
            encoder.setScissorRect(clampedScissor(range.scissor, drawableW: drawableW, drawableH: drawableH))
            encoder.drawPrimitives(type: .triangle, vertexStart: range.cursorStart, vertexCount: range.cursorCount)
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

    /// Clamp a scissor rect to the drawable bounds to prevent Metal validation errors.
    private func clampedScissor(_ scissor: MTLScissorRect, drawableW: Int, drawableH: Int) -> MTLScissorRect {
        let x = min(scissor.x, max(drawableW, 1) - 1)
        let y = min(scissor.y, max(drawableH, 1) - 1)
        let w = min(scissor.width, drawableW - x)
        let h = min(scissor.height, drawableH - y)
        return MTLScissorRect(x: x, y: y, width: max(w, 1), height: max(h, 1))
    }

    // MARK: - Block Element Rendering

    private struct BlockRect {
        let x: Float, y: Float, w: Float, h: Float
        let alpha: Float
    }

    /// Return rectangles to draw for Unicode block element characters (U+2580-U+259F).
    /// Coordinates are relative to the cell origin (0,0 = top-left in Metal coords).
    private func blockElementRects(_ cp: UInt32, cellW: Float, cellH: Float) -> [BlockRect] {
        let halfW = cellW * 0.5
        let halfH = cellH * 0.5

        switch cp {
        case 0x2580: // ▀ Upper half
            return [BlockRect(x: 0, y: 0, w: cellW, h: halfH, alpha: 1)]
        case 0x2581: // ▁ Lower 1/8
            return [BlockRect(x: 0, y: cellH * 7/8, w: cellW, h: cellH / 8, alpha: 1)]
        case 0x2582: // ▂ Lower 1/4
            return [BlockRect(x: 0, y: cellH * 3/4, w: cellW, h: cellH / 4, alpha: 1)]
        case 0x2583: // ▃ Lower 3/8
            return [BlockRect(x: 0, y: cellH * 5/8, w: cellW, h: cellH * 3/8, alpha: 1)]
        case 0x2584: // ▄ Lower half
            return [BlockRect(x: 0, y: halfH, w: cellW, h: halfH, alpha: 1)]
        case 0x2585: // ▅ Lower 5/8
            return [BlockRect(x: 0, y: cellH * 3/8, w: cellW, h: cellH * 5/8, alpha: 1)]
        case 0x2586: // ▆ Lower 3/4
            return [BlockRect(x: 0, y: cellH / 4, w: cellW, h: cellH * 3/4, alpha: 1)]
        case 0x2587: // ▇ Lower 7/8
            return [BlockRect(x: 0, y: cellH / 8, w: cellW, h: cellH * 7/8, alpha: 1)]
        case 0x2588: // █ Full block
            return [BlockRect(x: 0, y: 0, w: cellW, h: cellH, alpha: 1)]
        case 0x2589: // ▉ Left 7/8
            return [BlockRect(x: 0, y: 0, w: cellW * 7/8, h: cellH, alpha: 1)]
        case 0x258A: // ▊ Left 3/4
            return [BlockRect(x: 0, y: 0, w: cellW * 3/4, h: cellH, alpha: 1)]
        case 0x258B: // ▋ Left 5/8
            return [BlockRect(x: 0, y: 0, w: cellW * 5/8, h: cellH, alpha: 1)]
        case 0x258C: // ▌ Left half
            return [BlockRect(x: 0, y: 0, w: halfW, h: cellH, alpha: 1)]
        case 0x258D: // ▍ Left 3/8
            return [BlockRect(x: 0, y: 0, w: cellW * 3/8, h: cellH, alpha: 1)]
        case 0x258E: // ▎ Left 1/4
            return [BlockRect(x: 0, y: 0, w: cellW / 4, h: cellH, alpha: 1)]
        case 0x258F: // ▏ Left 1/8
            return [BlockRect(x: 0, y: 0, w: cellW / 8, h: cellH, alpha: 1)]
        case 0x2590: // ▐ Right half
            return [BlockRect(x: halfW, y: 0, w: halfW, h: cellH, alpha: 1)]
        case 0x2591: // ░ Light shade
            return [BlockRect(x: 0, y: 0, w: cellW, h: cellH, alpha: 0.25)]
        case 0x2592: // ▒ Medium shade
            return [BlockRect(x: 0, y: 0, w: cellW, h: cellH, alpha: 0.50)]
        case 0x2593: // ▓ Dark shade
            return [BlockRect(x: 0, y: 0, w: cellW, h: cellH, alpha: 0.75)]
        case 0x2594: // ▔ Upper 1/8
            return [BlockRect(x: 0, y: 0, w: cellW, h: cellH / 8, alpha: 1)]
        case 0x2595: // ▕ Right 1/8
            return [BlockRect(x: cellW * 7/8, y: 0, w: cellW / 8, h: cellH, alpha: 1)]
        case 0x2596: // ▖ Quadrant lower left
            return [BlockRect(x: 0, y: halfH, w: halfW, h: halfH, alpha: 1)]
        case 0x2597: // ▗ Quadrant lower right
            return [BlockRect(x: halfW, y: halfH, w: halfW, h: halfH, alpha: 1)]
        case 0x2598: // ▘ Quadrant upper left
            return [BlockRect(x: 0, y: 0, w: halfW, h: halfH, alpha: 1)]
        case 0x2599: // ▙ Quadrant UL + LL + LR
            return [
                BlockRect(x: 0, y: 0, w: halfW, h: cellH, alpha: 1),
                BlockRect(x: halfW, y: halfH, w: halfW, h: halfH, alpha: 1),
            ]
        case 0x259A: // ▚ Quadrant UL + LR
            return [
                BlockRect(x: 0, y: 0, w: halfW, h: halfH, alpha: 1),
                BlockRect(x: halfW, y: halfH, w: halfW, h: halfH, alpha: 1),
            ]
        case 0x259B: // ▛ Quadrant UL + UR + LL
            return [
                BlockRect(x: 0, y: 0, w: cellW, h: halfH, alpha: 1),
                BlockRect(x: 0, y: halfH, w: halfW, h: halfH, alpha: 1),
            ]
        case 0x259C: // ▜ Quadrant UL + UR + LR
            return [
                BlockRect(x: 0, y: 0, w: cellW, h: halfH, alpha: 1),
                BlockRect(x: halfW, y: halfH, w: halfW, h: halfH, alpha: 1),
            ]
        case 0x259D: // ▝ Quadrant upper right
            return [BlockRect(x: halfW, y: 0, w: halfW, h: halfH, alpha: 1)]
        case 0x259E: // ▞ Quadrant UR + LL
            return [
                BlockRect(x: halfW, y: 0, w: halfW, h: halfH, alpha: 1),
                BlockRect(x: 0, y: halfH, w: halfW, h: halfH, alpha: 1),
            ]
        case 0x259F: // ▟ Quadrant UR + LL + LR
            return [
                BlockRect(x: halfW, y: 0, w: halfW, h: halfH, alpha: 1),
                BlockRect(x: 0, y: halfH, w: cellW, h: halfH, alpha: 1),
            ]
        default:
            return [BlockRect(x: 0, y: 0, w: cellW, h: cellH, alpha: 1)]
        }
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
                // xterm 256-color grayscale ramp: indices 232-255 map to
                // RGB values 8, 18, 28, ..., 238 (i.e., 8 + 10 * (idx - 232))
                let gray = Float(8 + 10 * (Int(idx) - 232)) / 255.0
                return SIMD4<Float>(gray, gray, gray, 1.0)
            }
        case .rgb(let r, let g, let b):
            return SIMD4<Float>(Float(r) / 255.0, Float(g) / 255.0, Float(b) / 255.0, 1.0)
        }
    }
}
