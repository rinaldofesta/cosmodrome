import Foundation
import SwiftTerm

/// TerminalBackend implementation using SwiftTerm (pure Swift VT parser).
public final class SwiftTermBackend: TerminalBackend {
    private let terminal: Terminal
    private let delegate: SwiftTermDelegate
    private var _dirtyRows = IndexSet()
    private var allDirty = true
    private let _lock = NSLock()

    private var hasData = false
    private let _commandTracker = CommandTracker()

    public var commandTracker: CommandTracker? { _commandTracker }

    public init(cols: Int, rows: Int, scrollback: Int = 10_000) {
        self.delegate = SwiftTermDelegate()
        self.terminal = Terminal(delegate: delegate, options: TerminalOptions(
            cols: cols,
            rows: rows,
            scrollback: scrollback
        ))

        // Register OSC 133 handler for semantic prompt tracking
        let tracker = _commandTracker
        terminal.registerOscHandler(code: 133) { (data: ArraySlice<UInt8>) in
            if let str = String(bytes: data, encoding: .utf8) {
                tracker.handleOsc133(str)
            }
        }
    }

    public func process(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress else { return }
        let array = Array(UnsafeBufferPointer(
            start: base.assumingMemoryBound(to: UInt8.self),
            count: bytes.count
        ))
        _lock.lock()
        terminal.feed(byteArray: array)
        hasData = true
        // Mark all rows dirty for now; optimize with delegate tracking later
        allDirty = true
        _dirtyRows = IndexSet(integersIn: 0..<terminal.rows)
        _lock.unlock()
    }

    public func cell(row: Int, col: Int) -> TerminalCell {
        // Don't access SwiftTerm buffer until data has been fed — avoids
        // "BufferLine: index out of range" warnings from uninitialized lines.
        guard hasData,
              row >= 0 && row < terminal.rows && col >= 0 && col < terminal.cols,
              let ch = terminal.getCharData(col: col, row: row) else {
            return TerminalCell(codepoint: 32, wide: false, fg: .default, bg: .default, attrs: [])
        }

        let character = ch.getCharacter()
        let codepoint = character.unicodeScalars.first?.value ?? 32

        return TerminalCell(
            codepoint: codepoint == 0 ? 32 : codepoint,
            wide: ch.width > 1,
            fg: mapColor(ch.attribute.fg),
            bg: mapColor(ch.attribute.bg),
            attrs: mapAttributes(ch.attribute.style)
        )
    }

    public func cursorPosition() -> (row: Int, col: Int) {
        let loc = terminal.getCursorLocation()
        return (row: loc.y, col: loc.x)
    }

    public var isCursorVisible: Bool {
        delegate.cursorVisible
    }

    public var cursorStyle: TerminalCursorStyle {
        switch delegate.currentCursorStyle {
        case .blinkBlock, .steadyBlock:
            return .block
        case .blinkBar, .steadyBar:
            return .bar
        case .blinkUnderline, .steadyUnderline:
            return .underline
        }
    }

    public func resize(cols: UInt16, rows: UInt16) {
        _lock.lock()
        terminal.resize(cols: Int(cols), rows: Int(rows))
        allDirty = true
        _dirtyRows = IndexSet(integersIn: 0..<Int(rows))
        _lock.unlock()
    }

    public func lock() { _lock.lock() }
    public func unlock() { _lock.unlock() }

    public var isMouseReportingActive: Bool {
        terminal.mouseMode != .off
    }

    public func sendMouseEvent(button: Int, x: Int, y: Int) {
        let flags = terminal.encodeButton(button: button, release: false, shift: false, meta: false, control: false)
        _lock.lock()
        terminal.sendEvent(buttonFlags: flags, x: x, y: y)
        _lock.unlock()
    }

    public var rows: Int { terminal.rows }
    public var cols: Int { terminal.cols }

    public var dirtyRows: IndexSet { _dirtyRows }

    public func clearDirty() {
        _dirtyRows.removeAll()
        allDirty = false
    }

    public var scrollbackCount: Int {
        terminal.buffer.yDisp
    }

    public func pendingSendData() -> Data? {
        delegate.takePendingData()
    }

    // MARK: - Color mapping

    private func mapColor(_ color: Attribute.Color) -> TerminalColor {
        switch color {
        case .defaultColor:
            return .default
        case .defaultInvertedColor:
            return .default
        case .ansi256(let code):
            return .indexed(code)
        case .trueColor(let r, let g, let b):
            return .rgb(r: r, g: g, b: b)
        }
    }

    // MARK: - Attribute mapping

    private func mapAttributes(_ style: CharacterStyle) -> CellAttributes {
        var result = CellAttributes()
        if style.contains(.bold) { result.insert(.bold) }
        if style.contains(.italic) { result.insert(.italic) }
        if style.contains(.underline) { result.insert(.underline) }
        if style.contains(.crossedOut) { result.insert(.strikethrough) }
        if style.contains(.inverse) { result.insert(.inverse) }
        return result
    }
}

// MARK: - SwiftTerm Delegate

private final class SwiftTermDelegate: TerminalDelegate {
    private var pendingData: Data?
    var cursorVisible: Bool = true
    var currentCursorStyle: CursorStyle = .steadyBlock

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        let bytes = Data(data)
        if pendingData != nil {
            pendingData?.append(bytes)
        } else {
            pendingData = bytes
        }
    }

    func showCursor(source: Terminal) {
        cursorVisible = true
    }

    func hideCursor(source: Terminal) {
        cursorVisible = false
    }

    func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        currentCursorStyle = newStyle
    }

    func takePendingData() -> Data? {
        let data = pendingData
        pendingData = nil
        return data
    }
}
