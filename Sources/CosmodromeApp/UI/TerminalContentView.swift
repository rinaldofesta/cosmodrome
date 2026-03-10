import AppKit
import Core
import MetalKit

/// NSView that contains the MTKView for terminal rendering.
/// Handles keyboard/mouse input and forwards to the active session's PTY.
final class TerminalContentView: NSView {
    let metalView: MTKView
    private(set) var renderer: TerminalRenderer?
    private let layoutEngine = LayoutEngine()
    private var cachedEntries: [LayoutEngine.LayoutEntry] = []

    // Current session state
    var sessions: [(session: Session, backend: TerminalBackend)] = [] {
        didSet {
            let oldIds = oldValue.map(\.session.id)
            let newIds = sessions.map(\.session.id)
            if oldIds != newIds { needsLayout = true }
        }
    }
    var focusedSessionId: UUID?

    // Text selection state
    private(set) var selection: TerminalSelection?
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        self.metalView = MTKView(frame: frameRect)
        super.init(frame: frameRect)

        wantsLayer = true
        metalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metalView)

        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        renderer = TerminalRenderer(metalView: metalView)
        if renderer == nil {
            FileHandle.standardError.write("[Cosmodrome] Metal renderer failed to initialize\n".data(using: .utf8)!)
        }

        DispatchQueue.main.async { [weak self] in
            self?.metalView.needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool { true }

    // MARK: - Layout

    override func layout() {
        super.layout()
        metalView.drawableSize = CGSize(
            width: bounds.width * (window?.backingScaleFactor ?? 2.0),
            height: bounds.height * (window?.backingScaleFactor ?? 2.0)
        )
        updateLayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        metalView.needsDisplay = true
    }

    func updateLayout() {
        guard let renderer else { return }

        let sessionIds = sessions.map(\.session.id)
        let scale = window?.backingScaleFactor ?? 2.0
        let bounds = self.bounds

        layoutEngine.focusedSessionId = focusedSessionId
        cachedEntries = layoutEngine.layout(sessionIds: sessionIds, in: bounds)

        var renderEntries: [TerminalRenderer.SessionRenderEntry] = []

        for entry in cachedEntries {
            guard let pair = sessions.first(where: { $0.session.id == entry.sessionId }) else { continue }
            let backend = pair.backend

            // cellW/cellH are in pixels (font scaled by backingScaleFactor)
            let cellW = renderer.fontManager.cellMetrics.width
            let cellH = renderer.fontManager.cellMetrics.height
            let frameCols = max(1, Int(entry.frame.width * scale / cellW))
            let frameRows = max(1, Int(entry.frame.height * scale / cellH))

            if backend.cols != frameCols || backend.rows != frameRows {
                backend.resize(cols: UInt16(frameCols), rows: UInt16(frameRows))
                if pair.session.ptyFD >= 0 {
                    resizePTY(fd: pair.session.ptyFD, cols: UInt16(frameCols), rows: UInt16(frameRows))
                }
            }

            // Pixel coordinates for Metal (Y-flipped)
            let pixelX = entry.frame.origin.x * scale
            let pixelY = (bounds.height - entry.frame.origin.y - entry.frame.height) * scale
            let pixelW = entry.frame.width * scale
            let pixelH = entry.frame.height * scale

            let viewport = MTLViewport(
                originX: Double(pixelX),
                originY: Double(pixelY),
                width: Double(pixelW),
                height: Double(pixelH),
                znear: 0, zfar: 1
            )

            let scissor = MTLScissorRect(
                x: max(0, Int(pixelX)),
                y: max(0, Int(pixelY)),
                width: max(1, Int(pixelW)),
                height: max(1, Int(pixelH))
            )

            renderEntries.append(TerminalRenderer.SessionRenderEntry(
                backend: backend,
                viewport: viewport,
                scissor: scissor
            ))
        }

        renderer.visibleSessions = renderEntries
        renderer.selection = selection
        metalView.needsDisplay = true
    }

    func toggleFocus() {
        guard let focusedId = focusedSessionId ?? sessions.first?.session.id else { return }
        layoutEngine.toggleFocus(sessionId: focusedId)
        updateLayout()
    }

    /// Switch to a session in focus mode (like opening a tab).
    func focusSession(_ sessionId: UUID) {
        focusedSessionId = sessionId
        layoutEngine.mode = .focus
        layoutEngine.focusedSessionId = sessionId
        updateLayout()
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        // Key encoding handled by AppDelegate local event monitor
        super.keyDown(with: event)
    }

    // MARK: - Scroll

    override func scrollWheel(with event: NSEvent) {
        guard let focusedId = focusedSessionId,
              let pair = sessions.first(where: { $0.session.id == focusedId }),
              pair.session.ptyFD >= 0 else {
            super.scrollWheel(with: event)
            return
        }

        let deltaY = event.scrollingDeltaY
        guard deltaY != 0 else { return }

        let lines: Int
        if event.hasPreciseScrollingDeltas {
            // Trackpad: convert pixel delta to line count
            lines = max(1, Int(abs(deltaY) / 10.0))
        } else {
            // Mouse wheel: delta is already line-granularity
            lines = max(1, Int(abs(deltaY)))
        }
        let scrollUp = deltaY > 0

        let backend = pair.backend

        if backend.isMouseReportingActive {
            // App has mouse reporting on — send proper mouse wheel events.
            // Button 4 = scroll up, 5 = scroll down (encoded as 64/65 in xterm).
            let button = scrollUp ? 4 : 5
            let point = convert(event.locationInWindow, from: nil)
            let cell = cellAt(point: point) ?? (row: 0, col: 0)

            for _ in 0..<lines {
                backend.sendMouseEvent(button: button, x: cell.col, y: cell.row)
            }

            // Flush the response data that sendEvent generated
            if let sendData = backend.pendingSendData() {
                NotificationCenter.default.post(
                    name: .cosmodromePasteData,
                    object: nil,
                    userInfo: ["data": sendData, "fd": pair.session.ptyFD]
                )
            }
        } else {
            // No mouse reporting — send arrow keys as fallback
            let arrow: Data = scrollUp
                ? Data([0x1B, 0x5B, 0x41])  // Up
                : Data([0x1B, 0x5B, 0x42])  // Down
            var data = Data()
            for _ in 0..<lines { data.append(arrow) }
            NotificationCenter.default.post(
                name: .cosmodromePasteData,
                object: nil,
                userInfo: ["data": data, "fd": pair.session.ptyFD]
            )
        }
    }

    // MARK: - Mouse / Selection

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Focus session under click
        if let sessionId = layoutEngine.sessionAt(point: point, entries: cachedEntries) {
            focusedSessionId = sessionId
            window?.makeFirstResponder(self)
        }

        // Start selection
        if let cell = cellAt(point: point) {
            selection = TerminalSelection(startRow: cell.row, startCol: cell.col,
                                          endRow: cell.row, endCol: cell.col)
            isDragging = true
            renderer?.selection = selection
        } else {
            selection = nil
            renderer?.selection = nil
            isDragging = false
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, var sel = selection else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let cell = cellAt(point: point) {
            sel.endRow = cell.row
            sel.endCol = cell.col
            selection = sel
            renderer?.selection = selection
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging, let sel = selection {
            // Clear selection if it's empty (single click, no drag)
            if sel.startRow == sel.endRow && sel.startCol == sel.endCol {
                selection = nil
                renderer?.selection = nil
            }
        }
        isDragging = false
    }

    // MARK: - Copy / Paste

    func copySelection() {
        guard let sel = selection,
              let focusedId = focusedSessionId,
              let pair = sessions.first(where: { $0.session.id == focusedId }) else { return }

        let text = extractText(from: sel, backend: pair.backend)
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func pasteFromClipboard() {
        guard let focusedId = focusedSessionId,
              let pair = sessions.first(where: { $0.session.id == focusedId }),
              pair.session.ptyFD >= 0,
              let text = NSPasteboard.general.string(forType: .string),
              let data = text.data(using: .utf8) else { return }

        // Bracket paste mode: wrap pasted text in escape sequences
        // so the terminal/shell knows it's pasted content
        var pasteData = Data()
        pasteData.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]) // ESC[200~
        pasteData.append(data)
        pasteData.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]) // ESC[201~

        // Send via the same path as keystrokes (through MainWindowController)
        NotificationCenter.default.post(
            name: .cosmodromePasteData,
            object: nil,
            userInfo: ["data": pasteData, "fd": pair.session.ptyFD]
        )
    }

    // MARK: - Private Helpers

    /// Map a point (in NSView coordinates) to a cell (row, col) in the focused session.
    private func cellAt(point: NSPoint) -> (row: Int, col: Int)? {
        guard let renderer,
              let focusedId = focusedSessionId,
              let entry = cachedEntries.first(where: { $0.sessionId == focusedId }) else { return nil }

        let scale = window?.backingScaleFactor ?? 2.0
        let cellW = renderer.fontManager.cellMetrics.width
        let cellH = renderer.fontManager.cellMetrics.height

        // Convert point to pixel coordinates relative to session origin
        let pixelX = (point.x - entry.frame.origin.x) * scale
        // NSView Y is bottom-up, cell grid Y is top-down
        let pixelY = (entry.frame.maxY - point.y) * scale

        let col = Int(pixelX / cellW)
        let row = Int(pixelY / cellH)

        guard let pair = sessions.first(where: { $0.session.id == focusedId }) else { return nil }
        let backend = pair.backend

        guard row >= 0 && row < backend.rows && col >= 0 && col < backend.cols else { return nil }
        return (row: row, col: col)
    }

    /// Extract text from the backend for the given selection range.
    private func extractText(from sel: TerminalSelection, backend: TerminalBackend) -> String {
        let (startRow, startCol, endRow, endCol) = sel.normalized()
        var result = ""

        backend.lock()
        for row in startRow...endRow {
            guard row >= 0 && row < backend.rows else { continue }

            let colStart = (row == startRow) ? startCol : 0
            let colEnd = (row == endRow) ? endCol : backend.cols - 1

            for col in colStart...colEnd {
                guard col >= 0 && col < backend.cols else { continue }
                let cell = backend.cell(row: row, col: col)
                if cell.codepoint > 0 {
                    result.append(Character(UnicodeScalar(cell.codepoint)!))
                }
            }

            // Add newline between rows (but not after last row)
            if row < endRow {
                result.append("\n")
            }
        }
        backend.unlock()

        return result
    }
}

// MARK: - Selection Model

struct TerminalSelection {
    var startRow: Int
    var startCol: Int
    var endRow: Int
    var endCol: Int

    /// Returns (startRow, startCol, endRow, endCol) with start <= end.
    func normalized() -> (startRow: Int, startCol: Int, endRow: Int, endCol: Int) {
        if startRow < endRow || (startRow == endRow && startCol <= endCol) {
            return (startRow, startCol, endRow, endCol)
        }
        return (endRow, endCol, startRow, startCol)
    }

    /// Check if a cell is within the selection.
    func contains(row: Int, col: Int) -> Bool {
        let (sr, sc, er, ec) = normalized()
        if row < sr || row > er { return false }
        if row == sr && row == er { return col >= sc && col <= ec }
        if row == sr { return col >= sc }
        if row == er { return col <= ec }
        return true
    }
}

extension Notification.Name {
    static let cosmodromePasteData = Notification.Name("cosmodromePasteData")
}
