import CoreGraphics
import CoreText
import Foundation
import Metal

/// Rasterizes glyphs on demand and packs them into Metal textures.
final class GlyphAtlas {
    struct GlyphKey: Hashable {
        let codepoint: UInt32
        let fontVariant: UInt8 // 0=regular, 1=bold, 2=italic, 3=boldItalic
    }

    struct GlyphEntry {
        let textureIndex: Int
        let uv: SIMD4<Float> // (u0, v0, u1, v1)
        let size: SIMD2<Float> // pixel width, height
        let bearing: SIMD2<Float> // x bearing, y bearing (from baseline)
    }

    private var cache: [GlyphKey: GlyphEntry] = [:]
    private(set) var textures: [MTLTexture] = []
    private let device: MTLDevice
    private let fontManager: FontManager
    private let atlasSize: Int = 2048

    // Row packer state
    private var packX: Int = 1 // start at 1 to avoid bleeding
    private var packY: Int = 1
    private var rowHeight: Int = 0

    init(device: MTLDevice, fontManager: FontManager) {
        self.device = device
        self.fontManager = fontManager
        // Create first atlas page
        textures.append(createAtlasTexture())
    }

    /// Look up a glyph, rasterizing on first access.
    func lookup(_ key: GlyphKey) -> GlyphEntry {
        if let hit = cache[key] { return hit }
        return rasterize(key)
    }

    /// Current (most recent) atlas texture for binding.
    var currentTexture: MTLTexture? {
        textures.last
    }

    /// Clear all cached glyphs (call after font size change).
    func clearCache() {
        cache.removeAll()
        textures.removeAll()
        packX = 1
        packY = 1
        rowHeight = 0
        textures.append(createAtlasTexture())
    }

    // MARK: - Private

    private func createAtlasTexture() -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: atlasSize,
            height: atlasSize,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else {
            fatalError("[GlyphAtlas] Failed to create \(atlasSize)x\(atlasSize) atlas texture")
        }
        return texture
    }

    private func rasterize(_ key: GlyphKey) -> GlyphEntry {
        var font = fontManager.ctFont(variant: key.fontVariant)

        var glyph = CGGlyph(0)
        var chars: [UniChar] = []

        // Handle multi-unit codepoints
        if key.codepoint > 0xFFFF {
            let scalar = Unicode.Scalar(key.codepoint)!
            for unit in Character(scalar).utf16 {
                chars.append(unit)
            }
        } else {
            chars = [UniChar(key.codepoint)]
        }

        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        CTFontGetGlyphsForCharacters(font, chars, &glyphs, chars.count)
        glyph = glyphs[0]

        // Font fallback: if the primary font doesn't have this glyph,
        // ask CoreText to find one that does (emoji, symbols, CJK, etc.)
        if glyph == 0 {
            let str = String(Character(Unicode.Scalar(key.codepoint)!))
            let fallback = CTFontCreateForString(font, str as CFString, CFRange(location: 0, length: str.utf16.count))
            CTFontGetGlyphsForCharacters(fallback, chars, &glyphs, chars.count)
            if glyphs[0] != 0 {
                font = fallback
                glyph = glyphs[0]
            }
        }

        // Get glyph metrics
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, &bounds, 1)

        // Glyph is empty (space, etc.)
        if bounds.width < 1 || bounds.height < 1 {
            let entry = GlyphEntry(
                textureIndex: 0,
                uv: .zero,
                size: .zero,
                bearing: .zero
            )
            cache[key] = entry
            return entry
        }

        // Separate integer and fractional parts of glyph bounds origin.
        // Integer part → bearing offset (pixel-exact GPU placement).
        // Fractional part → baked into bitmap via CTM (correct sub-pixel AA).
        let floorX = floor(bounds.origin.x)
        let floorY = floor(bounds.origin.y)
        let fracX = bounds.origin.x - floorX
        let fracY = bounds.origin.y - floorY

        // Bitmap size accounts for fractional positioning + 1px padding each side
        let bitmapW = Int(ceil(bounds.width + fracX)) + 2
        let bitmapH = Int(ceil(bounds.height + fracY)) + 2

        // Rasterize glyph to bitmap
        let bytesPerRow = bitmapW
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * bitmapH)

        let ctx = CGContext(
            data: &pixels,
            width: bitmapW,
            height: bitmapH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!

        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(false) // Subpixel AA requires RGBA; OFF for grayscale
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setAllowsFontSubpixelQuantization(true)
        ctx.setShouldSubpixelQuantizeFonts(true)
        ctx.setFillColor(gray: 1.0, alpha: 1.0)

        // Translate by fractional part + padding to bake sub-pixel position into bitmap.
        // Then draw glyph at negative origin — CTM handles the fractional offset.
        // Effective glyph content starts at (fracX+1, fracY+1) within bitmap.
        ctx.translateBy(x: fracX + 1, y: fracY + 1)
        var position = CGPoint(x: -bounds.origin.x, y: -bounds.origin.y)
        CTFontDrawGlyphs(font, &glyph, &position, 1, ctx)

        // Integer bearings — fractional part is already in the bitmap.
        // bearingX: floor(origin.x) - 1 padding = horizontal offset from cell left to quad left.
        // bearingY: distance from baseline to bitmap top in Metal coords (for gy = y + baseline - bearingY).
        let entry = packIntoAtlas(
            pixels: pixels,
            width: bitmapW,
            height: bitmapH,
            bearingX: Float(Int(floorX) - 1),
            bearingY: Float(bitmapH + Int(floorY) - 1)
        )
        cache[key] = entry
        return entry
    }

    private func packIntoAtlas(
        pixels: [UInt8],
        width: Int,
        height: Int,
        bearingX: Float,
        bearingY: Float
    ) -> GlyphEntry {
        // Check if we need to advance to next row
        if packX + width + 1 > atlasSize {
            packX = 1
            packY += rowHeight + 1
            rowHeight = 0
        }

        // Check if we need a new atlas page
        if packY + height + 1 > atlasSize {
            textures.append(createAtlasTexture())
            packX = 1
            packY = 1
            rowHeight = 0
        }

        let textureIndex = textures.count - 1
        let texture = textures[textureIndex]

        // Upload pixels to texture
        let region = MTLRegion(
            origin: MTLOrigin(x: packX, y: packY, z: 0),
            size: MTLSize(width: width, height: height, depth: 1)
        )
        pixels.withUnsafeBytes { buffer in
            texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: width
            )
        }

        let s = Float(atlasSize)
        let entry = GlyphEntry(
            textureIndex: textureIndex,
            uv: SIMD4<Float>(
                Float(packX) / s,
                Float(packY) / s,
                Float(packX + width) / s,
                Float(packY + height) / s
            ),
            size: SIMD2<Float>(Float(width), Float(height)),
            bearing: SIMD2<Float>(bearingX, bearingY)
        )

        packX += width + 1
        rowHeight = max(rowHeight, height)

        return entry
    }
}
