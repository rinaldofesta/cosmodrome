import Foundation

public struct TerminalCell: Sendable {
    public let codepoint: UInt32
    public let wide: Bool
    public let fg: TerminalColor
    public let bg: TerminalColor
    public let attrs: CellAttributes

    public init(codepoint: UInt32, wide: Bool, fg: TerminalColor, bg: TerminalColor, attrs: CellAttributes) {
        self.codepoint = codepoint
        self.wide = wide
        self.fg = fg
        self.bg = bg
        self.attrs = attrs
    }
}

public struct CellAttributes: OptionSet, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let bold          = CellAttributes(rawValue: 1 << 0)
    public static let italic        = CellAttributes(rawValue: 1 << 1)
    public static let underline     = CellAttributes(rawValue: 1 << 2)
    public static let strikethrough = CellAttributes(rawValue: 1 << 3)
    public static let inverse       = CellAttributes(rawValue: 1 << 4)
}

public enum TerminalColor: Sendable, Equatable {
    case indexed(UInt8)
    case rgb(r: UInt8, g: UInt8, b: UInt8)
    case `default`
}
