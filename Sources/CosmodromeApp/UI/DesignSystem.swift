import AppKit
import Core
import SwiftUI

// MARK: - Spacing

enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

// MARK: - Corner Radii

enum Radius {
    static let sm: CGFloat = 4
    static let md: CGFloat = 6
    static let lg: CGFloat = 8
    static let xl: CGFloat = 12
}

// MARK: - Typography

enum Typo {
    static let caption = Font.system(size: 9)
    static let captionMono = Font.system(size: 9, design: .monospaced)
    static let footnote = Font.system(size: 10)
    static let footnoteMedium = Font.system(size: 10, weight: .medium)
    static let footnoteMono = Font.system(size: 10, design: .monospaced)
    static let body = Font.system(size: 11)
    static let bodyMedium = Font.system(size: 11, weight: .medium)
    static let callout = Font.system(size: 12)
    static let subheading = Font.system(size: 13)
    static let subheadingMedium = Font.system(size: 13, weight: .medium)
    static let title = Font.system(size: 14, weight: .semibold)
    static let largeTitle = Font.system(size: 15, weight: .semibold)
}

// MARK: - Theme State (shared mutable theme colors)

/// Holds the current theme's resolved colors for use by the design system.
/// Updated by MainWindowController when a theme is applied.
@Observable
final class ThemeState {
    static let shared = ThemeState()

    var background: NSColor = NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)
    var foreground: NSColor = NSColor.white
    var isDark: Bool = true

    func apply(_ theme: Theme) {
        if let bg = parseHexColor(theme.colors.background) {
            background = NSColor(red: CGFloat(bg.r), green: CGFloat(bg.g), blue: CGFloat(bg.b), alpha: 1)
            isDark = !isLightBackground(r: bg.r, g: bg.g, b: bg.b)
        }
        if let fg = parseHexColor(theme.colors.foreground) {
            foreground = NSColor(red: CGFloat(fg.r), green: CGFloat(fg.g), blue: CGFloat(fg.b), alpha: 1)
        }
    }

    /// Sidebar background: slightly darker/lighter than the main background.
    var sidebarBg: NSColor {
        isDark ? background.blended(withFraction: 0.3, of: .black) ?? background
               : background.blended(withFraction: 0.06, of: .black) ?? background
    }

    /// Elevated surface: slightly lighter/darker than main background.
    var elevatedBg: NSColor {
        isDark ? background.blended(withFraction: 0.15, of: .white) ?? background
               : background.blended(withFraction: 0.08, of: .white) ?? background
    }

    /// Surface: between primary and elevated.
    var surfaceBg: NSColor {
        isDark ? background.blended(withFraction: 0.2, of: .white) ?? background
               : background.blended(withFraction: 0.04, of: .white) ?? background
    }
}

// MARK: - Colors (Semantic, theme-aware)

enum DS {
    // Theme-derived backgrounds
    static var bgPrimary: Color {
        Color(nsColor: ThemeState.shared.background)
    }
    static var bgSidebar: Color {
        Color(nsColor: ThemeState.shared.sidebarBg)
    }
    static var bgElevated: Color {
        Color(nsColor: ThemeState.shared.elevatedBg)
    }
    static var bgSurface: Color {
        Color(nsColor: ThemeState.shared.surfaceBg)
    }

    // Interactive backgrounds (overlay-based, work on any theme)
    static var bgHover: Color {
        ThemeState.shared.isDark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.04)
    }
    static var bgSelected: Color {
        ThemeState.shared.isDark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.08)
    }
    static var bgPressed: Color {
        ThemeState.shared.isDark
            ? Color.white.opacity(0.14)
            : Color.black.opacity(0.12)
    }

    // Text (derived from theme foreground)
    static var textPrimary: Color {
        Color(nsColor: ThemeState.shared.foreground.withAlphaComponent(0.92))
    }
    static var textSecondary: Color {
        Color(nsColor: ThemeState.shared.foreground.withAlphaComponent(0.60))
    }
    static var textTertiary: Color {
        Color(nsColor: ThemeState.shared.foreground.withAlphaComponent(0.40))
    }
    static var textInverse: Color {
        Color(nsColor: ThemeState.shared.isDark ? .black : .white)
    }

    // Borders
    static var borderSubtle: Color {
        Color(nsColor: ThemeState.shared.foreground.withAlphaComponent(0.06))
    }
    static var borderMedium: Color {
        Color(nsColor: ThemeState.shared.foreground.withAlphaComponent(0.12))
    }
    static var borderStrong: Color {
        Color(nsColor: ThemeState.shared.foreground.withAlphaComponent(0.20))
    }
    static let borderFocus = Color.accentColor.opacity(0.6)

    // Agent state colors — adapt for light/dark theme visibility
    static var stateWorking: Color {
        ThemeState.shared.isDark
            ? Color(red: 0.30, green: 0.85, blue: 0.45)
            : Color(red: 0.13, green: 0.60, blue: 0.25)
    }
    static var stateNeedsInput: Color {
        ThemeState.shared.isDark
            ? Color(red: 1.0, green: 0.82, blue: 0.28)
            : Color(red: 0.80, green: 0.52, blue: 0.0)
    }
    static var stateError: Color {
        ThemeState.shared.isDark
            ? Color(red: 1.0, green: 0.38, blue: 0.38)
            : Color(red: 0.85, green: 0.18, blue: 0.18)
    }
    static var stateInactive: Color {
        Color(nsColor: ThemeState.shared.foreground.withAlphaComponent(0.30))
    }

    // Accent
    static let accent = Color.accentColor
    static let accentSubtle = Color.accentColor.opacity(0.15)

    // Shadows
    static let shadowLight = Color.black.opacity(0.20)
    static let shadowMedium = Color.black.opacity(0.35)
    static let shadowHeavy = Color.black.opacity(0.50)

    // Dismiss overlay
    static let overlay = Color.black.opacity(0.25)

    static func stateColor(for state: Core.AgentState) -> Color {
        switch state {
        case .working: return stateWorking
        case .needsInput: return stateNeedsInput
        case .error: return stateError
        case .inactive: return stateInactive
        }
    }
}

// MARK: - Animations

enum Anim {
    static let quick = Animation.easeInOut(duration: 0.15)
    static let normal = Animation.easeInOut(duration: 0.25)
    static let slow = Animation.easeInOut(duration: 0.35)
    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.8)
}

// MARK: - Reusable View Modifiers

struct HoverEffect: ViewModifier {
    @State private var isHovered = false
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isHovered ? DS.bgHover : Color.clear)
                    .animation(Anim.quick, value: isHovered)
            )
            .onHover { isHovered = $0 }
    }
}

extension View {
    func hoverHighlight(radius: CGFloat = Radius.sm) -> some View {
        modifier(HoverEffect(cornerRadius: radius))
    }
}
