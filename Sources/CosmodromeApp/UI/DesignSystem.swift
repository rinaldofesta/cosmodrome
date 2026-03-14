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
//
// UI Chrome uses SF Pro (system font). Terminal uses CoreText (user-configurable).
// Weights: Regular (400) for body, Medium (500) for emphasis. Never Bold in chrome.
// The terminal content is visually dense — chrome should be lighter to recede.

enum Typo {
    // Size scale: 9 / 10 / 11 / 12 / 13 / 14 / 15
    static let caption = Font.system(size: 9)
    static let captionMono = Font.system(size: 9, design: .monospaced)
    static let footnote = Font.system(size: 10)
    static let footnoteMedium = Font.system(size: 10, weight: .medium)
    static let footnoteMono = Font.system(size: 10, design: .monospaced)
    static let body = Font.system(size: 11)
    static let bodyMedium = Font.system(size: 11, weight: .medium)
    static let callout = Font.system(size: 12)
    static let calloutMedium = Font.system(size: 12, weight: .medium)
    static let subheading = Font.system(size: 13)
    static let subheadingMedium = Font.system(size: 13, weight: .medium)
    static let title = Font.system(size: 14, weight: .medium)
    static let largeTitle = Font.system(size: 15, weight: .medium)
}

// MARK: - Colors (Semantic, appearance-adaptive)

/// Helper to create an NSColor that automatically switches between dark and light variants
/// based on the current NSAppearance (set by window.appearance).
private func adaptive(dark: NSColor, light: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? dark : light
    }))
}

// MARK: - Design System Tokens

enum DS {

    // MARK: Backgrounds (darkest → lightest)
    //
    // --bg-base:       #1A1A1C   Base window + terminal background
    // --bg-surface-1:  #222224   Sidebar, panels
    // --bg-surface-2:  #2A2A2D   Cards, elevated elements
    // --bg-surface-3:  #333336   Hover states, active elements

    static let bgPrimary = adaptive(
        dark: NSColor(red: 0.102, green: 0.102, blue: 0.110, alpha: 1),   // #1A1A1C
        light: NSColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)
    )
    static let bgTerminal = bgPrimary  // Terminal bg matches base

    static let bgSidebar = adaptive(
        dark: NSColor(red: 0.133, green: 0.133, blue: 0.141, alpha: 1),   // #222224
        light: NSColor(red: 0.93, green: 0.93, blue: 0.94, alpha: 1)
    )

    static let bgSurface = adaptive(
        dark: NSColor(red: 0.165, green: 0.165, blue: 0.176, alpha: 1),   // #2A2A2D
        light: NSColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1)
    )

    static let bgElevated = adaptive(
        dark: NSColor(red: 0.200, green: 0.200, blue: 0.212, alpha: 1),   // #333336
        light: NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1)
    )

    // Interactive backgrounds
    static let bgHover = adaptive(
        dark: NSColor.white.withAlphaComponent(0.06),
        light: NSColor.black.withAlphaComponent(0.04)
    )
    static let bgSelected = adaptive(
        dark: NSColor.white.withAlphaComponent(0.10),
        light: NSColor.black.withAlphaComponent(0.08)
    )
    static let bgPressed = adaptive(
        dark: NSColor.white.withAlphaComponent(0.14),
        light: NSColor.black.withAlphaComponent(0.12)
    )

    // MARK: Text
    //
    // --text-primary:    #E8E8E8   Not pure white — too harsh
    // --text-secondary:  #999999   Labels, secondary info
    // --text-tertiary:   #737373   Hints, timestamps (bumped from #666 for WCAG AA)

    static let textPrimary = adaptive(
        dark: NSColor(red: 0.910, green: 0.910, blue: 0.910, alpha: 1),   // #E8E8E8
        light: NSColor.black.withAlphaComponent(0.88)
    )
    static let textSecondary = adaptive(
        dark: NSColor(red: 0.600, green: 0.600, blue: 0.600, alpha: 1),   // #999999
        light: NSColor.black.withAlphaComponent(0.55)
    )
    static let textTertiary = adaptive(
        dark: NSColor(red: 0.451, green: 0.451, blue: 0.451, alpha: 1),   // #737373 (WCAG AA: 4.5:1)
        light: NSColor.black.withAlphaComponent(0.35)
    )
    static let textInverse = adaptive(
        dark: NSColor(red: 0.102, green: 0.102, blue: 0.110, alpha: 1),   // #1A1A1C
        light: NSColor.white
    )

    // MARK: Borders
    //
    // --border-subtle:   white 6%    Barely visible boundaries
    // --border-default:  white 10%   Standard borders
    // --border-active:   white 20%   Focused/active elements

    static let borderSubtle = adaptive(
        dark: NSColor.white.withAlphaComponent(0.06),
        light: NSColor.black.withAlphaComponent(0.06)
    )
    static let borderMedium = adaptive(
        dark: NSColor.white.withAlphaComponent(0.10),
        light: NSColor.black.withAlphaComponent(0.10)
    )
    static let borderStrong = adaptive(
        dark: NSColor.white.withAlphaComponent(0.20),
        light: NSColor.black.withAlphaComponent(0.18)
    )
    static let borderFocus = Color.accentColor.opacity(0.6)

    // MARK: Agent State Colors (Apple system colors adapted for dark mode)
    //
    // These are the most important colors in the app.
    // Same in both modes — high-contrast, color-blind accessible with shape pairing.
    //
    // --state-working:  #34C759   Green — alive, not neon
    // --state-input:    #FFD60A   Amber — warm, urgent
    // --state-error:    #FF453A   Red — clear, not aggressive
    // --state-idle:     #737373   Gray — neutral, recedes

    static let stateWorking = Color(red: 0.204, green: 0.780, blue: 0.349)       // #34C759
    static let stateNeedsInput = Color(red: 1.000, green: 0.839, blue: 0.039)    // #FFD60A
    static let stateError = Color(red: 1.000, green: 0.271, blue: 0.227)         // #FF453A
    static let stateInactive = adaptive(
        dark: NSColor(red: 0.451, green: 0.451, blue: 0.451, alpha: 1),          // #737373
        light: NSColor.black.withAlphaComponent(0.25)
    )

    // Dimmed state colors (20% opacity) for background tints on cards/borders
    static let stateWorkingDim = Color(red: 0.204, green: 0.780, blue: 0.349).opacity(0.20)
    static let stateNeedsInputDim = Color(red: 1.000, green: 0.839, blue: 0.039).opacity(0.20)
    static let stateErrorDim = Color(red: 1.000, green: 0.271, blue: 0.227).opacity(0.20)

    // MARK: Brand Accent
    //
    // --brand: #5DCAA5  Teal — links, highlights, brand elements

    static let brand = Color(red: 0.365, green: 0.792, blue: 0.647)              // #5DCAA5
    static let brandDim = Color(red: 0.365, green: 0.792, blue: 0.647).opacity(0.20)

    // Accent (system)
    static let accent = Color.accentColor
    static let accentSubtle = Color.accentColor.opacity(0.15)

    // MARK: Shadows

    static let shadowLight = Color.black.opacity(0.20)
    static let shadowMedium = Color.black.opacity(0.35)
    static let shadowHeavy = Color.black.opacity(0.50)

    // Dismiss overlay
    static let overlay = Color.black.opacity(0.25)

    // MARK: State Helpers

    static func stateColor(for state: Core.AgentState) -> Color {
        switch state {
        case .working: return stateWorking
        case .needsInput: return stateNeedsInput
        case .error: return stateError
        case .inactive: return stateInactive
        }
    }

    static func stateColorDim(for state: Core.AgentState) -> Color {
        switch state {
        case .working: return stateWorkingDim
        case .needsInput: return stateNeedsInputDim
        case .error: return stateErrorDim
        case .inactive: return Color.clear
        }
    }
}

// MARK: - Animations

enum Anim {
    static let quick = Animation.easeOut(duration: 0.15)
    static let normal = Animation.easeOut(duration: 0.25)
    static let slow = Animation.easeOut(duration: 0.35)
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
