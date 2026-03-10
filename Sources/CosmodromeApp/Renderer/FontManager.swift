import Core
import CoreText
import Foundation

/// Manages terminal fonts and calculates cell metrics.
final class FontManager {
    struct CellMetrics {
        let width: CGFloat
        let height: CGFloat
        let baseline: CGFloat
    }

    private var fonts: [CTFont] // [regular, bold, italic, boldItalic]
    let cellMetrics: CellMetrics
    let fontSize: CGFloat

    init(family: String = "Menlo", size: CGFloat = 14, scale: CGFloat = 2.0, lineHeight: CGFloat = 1.2) {
        self.fontSize = size
        let scaledSize = size * scale
        let regular = CTFontCreateWithName(family as CFString, scaledSize, nil)

        let bold = CTFontCreateCopyWithSymbolicTraits(
            regular, scaledSize, nil, .boldTrait, .boldTrait
        ) ?? regular

        let italic = CTFontCreateCopyWithSymbolicTraits(
            regular, scaledSize, nil, .italicTrait, .italicTrait
        ) ?? regular

        let boldItalic = CTFontCreateCopyWithSymbolicTraits(
            regular, scaledSize, nil, [.boldTrait, .italicTrait], [.boldTrait, .italicTrait]
        ) ?? bold

        self.fonts = [regular, bold, italic, boldItalic]

        let ascent = CTFontGetAscent(regular)
        let descent = CTFontGetDescent(regular)
        let leading = CTFontGetLeading(regular)

        var advance = CGSize.zero
        var glyph = CTFontGetGlyphWithName(regular, "M" as CFString)
        CTFontGetAdvancesForGlyphs(regular, .default, &glyph, &advance, 1)

        self.cellMetrics = CellMetrics(
            width: ceil(advance.width),
            height: ceil((ascent + descent + leading) * lineHeight),
            baseline: round(ascent)
        )
    }

    /// Get the CTFont for a given variant.
    /// Variant encoding: bit 0 = bold, bit 1 = italic.
    func ctFont(variant: UInt8) -> CTFont {
        fonts[Int(variant & 0x03)]
    }

    /// Compute the font variant index from cell attributes.
    static func variant(from attrs: Core.CellAttributes) -> UInt8 {
        var v: UInt8 = 0
        if attrs.contains(.bold) { v |= 1 }
        if attrs.contains(.italic) { v |= 2 }
        return v
    }
}
