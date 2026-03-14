import Foundation

/// Parsed terminal color theme.
public struct Theme: Codable {
    public var name: String
    public var colors: ThemeColors

    public init(name: String, colors: ThemeColors) {
        self.name = name
        self.colors = colors
    }

    /// Default dark theme.
    public static let dark = Theme(
        name: "Dark",
        colors: ThemeColors(
            foreground: "#D9D9D9",
            background: "#1A1A1F",
            cursor: "#D9D9D9",
            selection: "#3A3A4A",
            black: "#000000", red: "#CC3333", green: "#33CC33", yellow: "#CCCC33",
            blue: "#4D66CC", magenta: "#CC33CC", cyan: "#33CCCC", white: "#BFBFBF",
            brightBlack: "#666666", brightRed: "#FF4D4D", brightGreen: "#4DFF4D", brightYellow: "#FFFF4D",
            brightBlue: "#6680FF", brightMagenta: "#FF4DFF", brightCyan: "#4DFFFF", brightWhite: "#FFFFFF"
        )
    )

    /// Default light theme.
    public static let light = Theme(
        name: "Light",
        colors: ThemeColors(
            foreground: "#1A1A1F",
            background: "#F5F5F5",
            cursor: "#1A1A1F",
            selection: "#C0C0D0",
            black: "#000000", red: "#CC3333", green: "#228B22", yellow: "#B8860B",
            blue: "#3333CC", magenta: "#8B008B", cyan: "#008B8B", white: "#BFBFBF",
            brightBlack: "#666666", brightRed: "#FF4D4D", brightGreen: "#32CD32", brightYellow: "#DAA520",
            brightBlue: "#4169E1", brightMagenta: "#DA70D6", brightCyan: "#00CED1", brightWhite: "#FFFFFF"
        )
    )
}

public struct ThemeColors: Codable {
    public var foreground: String
    public var background: String
    public var cursor: String
    public var selection: String

    // Standard ANSI
    public var black: String
    public var red: String
    public var green: String
    public var yellow: String
    public var blue: String
    public var magenta: String
    public var cyan: String
    public var white: String

    // Bright ANSI
    public var brightBlack: String
    public var brightRed: String
    public var brightGreen: String
    public var brightYellow: String
    public var brightBlue: String
    public var brightMagenta: String
    public var brightCyan: String
    public var brightWhite: String

    enum CodingKeys: String, CodingKey {
        case foreground, background, cursor, selection
        case black, red, green, yellow, blue, magenta, cyan, white
        case brightBlack = "bright_black"
        case brightRed = "bright_red"
        case brightGreen = "bright_green"
        case brightYellow = "bright_yellow"
        case brightBlue = "bright_blue"
        case brightMagenta = "bright_magenta"
        case brightCyan = "bright_cyan"
        case brightWhite = "bright_white"
    }

    public init(
        foreground: String, background: String, cursor: String, selection: String,
        black: String, red: String, green: String, yellow: String,
        blue: String, magenta: String, cyan: String, white: String,
        brightBlack: String, brightRed: String, brightGreen: String, brightYellow: String,
        brightBlue: String, brightMagenta: String, brightCyan: String, brightWhite: String
    ) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.selection = selection
        self.black = black; self.red = red; self.green = green; self.yellow = yellow
        self.blue = blue; self.magenta = magenta; self.cyan = cyan; self.white = white
        self.brightBlack = brightBlack; self.brightRed = brightRed
        self.brightGreen = brightGreen; self.brightYellow = brightYellow
        self.brightBlue = brightBlue; self.brightMagenta = brightMagenta
        self.brightCyan = brightCyan; self.brightWhite = brightWhite
    }

    /// All 16 ANSI colors as an array.
    public var ansiArray: [String] {
        [black, red, green, yellow, blue, magenta, cyan, white,
         brightBlack, brightRed, brightGreen, brightYellow,
         brightBlue, brightMagenta, brightCyan, brightWhite]
    }
}

/// Determine if a color is perceptually light using ITU-R BT.601 luminance.
public func isLightBackground(r: Float, g: Float, b: Float) -> Bool {
    r * 0.299 + g * 0.587 + b * 0.114 > 0.5
}

/// Parse a hex color string to (r, g, b) floats in 0...1.
public func parseHexColor(_ hex: String) -> (r: Float, g: Float, b: Float)? {
    var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if h.hasPrefix("#") { h.removeFirst() }
    guard h.count == 6, let val = UInt32(h, radix: 16) else { return nil }
    return (
        r: Float((val >> 16) & 0xFF) / 255.0,
        g: Float((val >> 8) & 0xFF) / 255.0,
        b: Float(val & 0xFF) / 255.0
    )
}
