import Core
import simd

/// Resolved theme colors as SIMD4 floats for Metal rendering.
struct ResolvedTheme {
    let foreground: SIMD4<Float>
    let background: SIMD4<Float>
    let cursor: SIMD4<Float>
    let selection: SIMD4<Float>
    /// Selection color with semi-transparent alpha for overlay highlighting.
    let selectionHighlight: SIMD4<Float>
    let ansiColors: [SIMD4<Float>] // 16 entries

    init(theme: Theme) {
        self.foreground = Self.resolve(theme.colors.foreground) ?? SIMD4(0.85, 0.85, 0.85, 1)
        self.background = Self.resolve(theme.colors.background) ?? SIMD4(0.1, 0.1, 0.12, 1)
        self.cursor = Self.resolve(theme.colors.cursor) ?? SIMD4(0.85, 0.85, 0.85, 1)
        self.selection = Self.resolve(theme.colors.selection) ?? SIMD4(0.23, 0.23, 0.29, 1)
        self.ansiColors = theme.colors.ansiArray.map { hex in
            Self.resolve(hex) ?? SIMD4(0.5, 0.5, 0.5, 1)
        }

        // Selection highlight: theme selection color with semi-transparent alpha.
        // Use background luminance to pick dark vs light alpha.
        let isDark: Bool
        if let bg = parseHexColor(theme.colors.background) {
            isDark = !isLightBackground(r: bg.r, g: bg.g, b: bg.b)
        } else {
            isDark = true
        }
        let alpha: Float = isDark ? 0.45 : 0.35
        let sel = Self.resolve(theme.colors.selection) ?? SIMD4(0.3, 0.5, 0.8, 1)
        self.selectionHighlight = SIMD4(sel.x, sel.y, sel.z, alpha)
    }

    private static func resolve(_ hex: String) -> SIMD4<Float>? {
        guard let (r, g, b) = parseHexColor(hex) else { return nil }
        return SIMD4(r, g, b, 1.0)
    }
}
