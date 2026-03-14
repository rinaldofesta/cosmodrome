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
    private var _scrollOffset: Int = 0
    private var _bottomPosition: Int = 0
    private let _commandTracker = CommandTracker()

    public var commandTracker: CommandTracker? { _commandTracker }

    /// Called when an OSC 777 notification is received.
    public var onNotification: ((TerminalNotification) -> Void)?

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

        // Register OSC 777 handler for terminal notifications
        // Format: 777;notify;title;body
        terminal.registerOscHandler(code: 777) { [weak self] (data: ArraySlice<UInt8>) in
            guard let str = String(bytes: data, encoding: .utf8) else { return }
            // The OSC code (777) is already stripped by SwiftTerm's handler dispatch.
            // Remaining payload: "notify;title;body"
            let parts = str.split(separator: ";", maxSplits: 2)
            guard parts.count >= 2, parts[0] == "notify" else { return }
            let title = String(parts[1])
            let body = parts.count >= 3 ? String(parts[2]) : ""
            let notification = TerminalNotification(title: title, body: body)
            self?.onNotification?(notification)
        }
    }

    public func process(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress else { return }
        let array = Array(UnsafeBufferPointer(
            start: base.assumingMemoryBound(to: UInt8.self),
            count: bytes.count
        ))
        _lock.lock()
        // If user is at or near the bottom, auto-snap to bottom after feed.
        // This prevents jitter from micro-scroll offsets during rapid output
        // (e.g. Claude Code redrawing status lines and spinners).
        let wasNearBottom = _scrollOffset <= 3

        // Reset yDisp to bottom before feeding so SwiftTerm operates on consistent state
        if _scrollOffset > 0 {
            terminal.buffer.yDisp = _bottomPosition
        }
        terminal.feed(byteArray: array)
        // After feed(), yDisp == yBase (bottom). Capture it.
        _bottomPosition = terminal.buffer.yDisp

        if wasNearBottom {
            // Snap to bottom — user was following output
            _scrollOffset = 0
        } else if _scrollOffset > 0 {
            // Re-apply scroll offset so the renderer sees scrolled-back content
            _scrollOffset = min(_scrollOffset, _bottomPosition)
            terminal.buffer.yDisp = max(0, _bottomPosition - _scrollOffset)
        }
        hasData = true
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
        _scrollOffset = 0
        _bottomPosition = terminal.buffer.yDisp
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
        _bottomPosition
    }

    public var scrollOffset: Int {
        _scrollOffset
    }

    public func scroll(lines: Int) {
        _lock.lock()
        _scrollOffset = max(0, min(_scrollOffset + lines, _bottomPosition))
        terminal.buffer.yDisp = max(0, _bottomPosition - _scrollOffset)
        allDirty = true
        _dirtyRows = IndexSet(integersIn: 0..<terminal.rows)
        _lock.unlock()
    }

    public func scrollToBottom() {
        _lock.lock()
        guard _scrollOffset > 0 else {
            _lock.unlock()
            return
        }
        _scrollOffset = 0
        terminal.buffer.yDisp = _bottomPosition
        allDirty = true
        _dirtyRows = IndexSet(integersIn: 0..<terminal.rows)
        _lock.unlock()
    }

    public var isScrolledBack: Bool {
        _scrollOffset > 0
    }

    /// Read a cell at the true bottom of the buffer, ignoring any scroll offset.
    /// Must be called while lock is held.
    public func cellAtBottom(row: Int, col: Int) -> TerminalCell {
        guard hasData,
              row >= 0 && row < terminal.rows && col >= 0 && col < terminal.cols else {
            return TerminalCell(codepoint: 32, wide: false, fg: .default, bg: .default, attrs: [])
        }

        // Temporarily snap to the real bottom if scrolled back
        let savedYDisp = terminal.buffer.yDisp
        if _scrollOffset > 0 {
            terminal.buffer.yDisp = _bottomPosition
        }

        let result = cell(row: row, col: col)

        if _scrollOffset > 0 {
            terminal.buffer.yDisp = savedYDisp
        }

        return result
    }

    /// Read bottom N rows as trimmed strings in a single locked + yDisp-snapped pass.
    /// Eliminates per-cell yDisp mutations that cause scroll jitter during rapid output.
    /// Caller must NOT hold the lock.
    public func readRowsAtBottom(count: Int) -> [String] {
        _lock.lock()
        defer { _lock.unlock() }
        guard hasData else { return [] }

        let rowCount = terminal.rows
        let colCount = terminal.cols
        let scanRows = min(rowCount, count)

        // Snap to bottom ONCE (instead of per-cell in cellAtBottom)
        let savedYDisp = terminal.buffer.yDisp
        if _scrollOffset > 0 {
            terminal.buffer.yDisp = _bottomPosition
        }

        var result: [String] = []
        result.reserveCapacity(scanRows)
        for row in max(0, rowCount - scanRows)..<rowCount {
            var line = ""
            line.reserveCapacity(colCount)
            for col in 0..<colCount {
                guard let ch = terminal.getCharData(col: col, row: row) else {
                    line.append(" ")
                    continue
                }
                let cp = ch.getCharacter().unicodeScalars.first?.value ?? 32
                if cp >= 32 && cp < 0x110000 && cp != 0 {
                    line.append(Character(Unicode.Scalar(cp)!))
                } else {
                    line.append(" ")
                }
            }
            while line.hasSuffix(" ") { line.removeLast() }
            result.append(line)
        }

        // Restore ONCE
        if _scrollOffset > 0 {
            terminal.buffer.yDisp = savedYDisp
        }
        return result
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
