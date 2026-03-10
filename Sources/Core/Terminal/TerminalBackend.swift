import Foundation

/// Swappable VT parsing backend. Current: SwiftTerm. Future: libghostty-vt.
public protocol TerminalBackend: AnyObject {
    /// Feed raw bytes from PTY.
    func process(_ bytes: UnsafeRawBufferPointer)

    /// Read cell at grid position.
    func cell(row: Int, col: Int) -> TerminalCell

    /// Current cursor position.
    func cursorPosition() -> (row: Int, col: Int)

    /// Resize the virtual terminal.
    func resize(cols: UInt16, rows: UInt16)

    /// Grid dimensions.
    var rows: Int { get }
    var cols: Int { get }

    /// Rows modified since last clearDirty(). Used for incremental rendering.
    var dirtyRows: IndexSet { get }
    func clearDirty()

    /// Scrollback line count.
    var scrollbackCount: Int { get }

    /// Data the terminal wants to send back (e.g., cursor position reports).
    /// Nil if nothing pending.
    func pendingSendData() -> Data?

    /// Thread safety: acquire before batch-reading cell data from the main thread.
    /// The I/O thread also acquires this during process(). This prevents concurrent
    /// read/write access to the terminal's internal buffers.
    func lock()
    func unlock()

    /// Whether the application has enabled mouse event reporting.
    var isMouseReportingActive: Bool { get }

    /// Send a mouse scroll event through the terminal's mouse protocol encoder.
    /// `button`: 64 = scroll up, 65 = scroll down.
    /// `x`, `y`: 0-based cell coordinates.
    func sendMouseEvent(button: Int, x: Int, y: Int)

    /// Tracks shell command lifecycle via OSC 133 semantic prompts.
    var commandTracker: CommandTracker? { get }

    /// Whether the cursor should be visible.
    var isCursorVisible: Bool { get }

    /// Cursor shape: block, bar, or underline.
    var cursorStyle: TerminalCursorStyle { get }
}

/// Cursor styles supported by the renderer.
public enum TerminalCursorStyle {
    case block
    case bar
    case underline
}

extension TerminalBackend {
    public var commandTracker: CommandTracker? { nil }
    public var isCursorVisible: Bool { true }
    public var cursorStyle: TerminalCursorStyle { .block }
}
