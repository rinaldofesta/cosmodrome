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

    // Session border/label/header overlays
    private var sessionBorderLayers: [UUID: CALayer] = [:]
    private var sessionLabelLayers: [UUID: CATextLayer] = [:]
    private var sessionAttentionLayers: [UUID: CALayer] = [:]
    private var sessionDimLayers: [UUID: CALayer] = [:]
    private var sessionHeaderLayers: [UUID: CALayer] = [:]
    private var sessionHeaderDotLayers: [UUID: CALayer] = [:]
    private var sessionHeaderTextLayers: [UUID: CATextLayer] = [:]
    private var hoveredSessionId: UUID?
    private var sessionTrackingArea: NSTrackingArea?

    // Cursor blink state
    private var cursorBlinkTimer: Timer?
    private var cursorBlinkPhase: Double = 0
    private(set) var cursorOpacity: Float = 1.0

    // Phantom scroll guard: suppress scroll events shortly after focus changes.
    // macOS can deliver stale scroll events with outdated state after window/view
    // focus transitions, causing phantom scrolling. (Same root cause as Ghostty #11276.)
    private var lastFocusChangeTime: CFAbsoluteTime = 0
    private let focusGuardInterval: CFAbsoluteTime = 0.15 // 150ms

    // Smooth scroll accumulator: trackpad pixel deltas are accumulated here and
    // converted to whole lines only when the threshold (one line height in points)
    // is reached.  The remainder carries over for sub-line precision.  Reset when
    // the scroll gesture ends (phase .ended / momentum .ended).
    private var scrollAccumulator: CGFloat = 0

    // Current session state
    var sessions: [(session: Session, backend: TerminalBackend)] = [] {
        didSet {
            let oldIds = oldValue.map(\.session.id)
            let newIds = sessions.map(\.session.id)
            if oldIds != newIds { needsLayout = true }
        }
    }
    var focusedSessionId: UUID?

    // Text selection state — rows are stored as ABSOLUTE buffer positions
    // (viewportRow + scrollbackCount - scrollOffset) so they survive scrolling.
    private(set) var selection: TerminalSelection?
    private var isDragging = false
    private var autoScrollTimer: Timer?
    private var lastBackingScale: CGFloat = 0

    // Grid layout constants
    private let gridGap: CGFloat = Spacing.xs       // 4px gap between cells
    private let cellCornerRadius: CGFloat = Radius.md // 6px corner radius
    private let sessionHeaderHeight: CGFloat = Spacing.xl // 24px header bar

    init(frame frameRect: NSRect, userConfig: UserConfig? = nil) {
        self.metalView = MTKView(frame: frameRect)
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.masksToBounds = true
        metalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metalView)

        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        renderer = TerminalRenderer(metalView: metalView, userConfig: userConfig)
        if renderer == nil {
            FileHandle.standardError.write("[Cosmodrome] Metal renderer failed to initialize\n".data(using: .utf8)!)
        }

        DispatchQueue.main.async { [weak self] in
            self?.metalView.needsDisplay = true
        }

        updateTrackingArea()
        startCursorBlinkTimer()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        if let existing = sessionTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        sessionTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newHoveredId = layoutEngine.sessionAt(point: point, entries: cachedEntries)
        if newHoveredId != hoveredSessionId {
            hoveredSessionId = newHoveredId
            updateLabelVisibility()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredSessionId != nil {
            hoveredSessionId = nil
            updateLabelVisibility()
        }
    }

    private func updateLabelVisibility() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        for (id, labelLayer) in sessionLabelLayers {
            let show = (id == hoveredSessionId || id == focusedSessionId)
            labelLayer.opacity = show ? 1.0 : 0.0
        }
        CATransaction.commit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    deinit {
        stopCursorBlinkTimer()
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        lastFocusChangeTime = CFAbsoluteTimeGetCurrent()
        return true
    }

    /// Called by MainWindowController when the window becomes key, so the focus
    /// guard also covers app-level focus changes (not just first-responder changes).
    func resetFocusGuard() {
        lastFocusChangeTime = CFAbsoluteTimeGetCurrent()
    }

    // MARK: - Cursor Blink

    private func startCursorBlinkTimer() {
        // Fires at 30fps, updates cursor opacity with smooth sine curve.
        // No allocation in the render loop — only updates a float property.
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.cursorBlinkPhase += 1.0 / 30.0
            // Smooth sine oscillation: period = 1.0s, range = 0.3..1.0
            let sine = sin(self.cursorBlinkPhase * .pi * 2.0) // -1..1
            let opacity = Float(0.65 + 0.35 * sine)           // 0.3..1.0
            self.cursorOpacity = opacity
        }
        cursorBlinkTimer = timer
    }

    private func stopCursorBlinkTimer() {
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
    }

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
        if let scale = window?.backingScaleFactor, lastBackingScale == 0 {
            lastBackingScale = scale
            renderer?.fontManager.updateScale(scale)
            renderer?.atlas.clearCache()
        }
        needsLayout = true
        metalView.needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let scale = window?.backingScaleFactor, scale != lastBackingScale else { return }
        lastBackingScale = scale
        renderer?.fontManager.updateScale(scale)
        renderer?.atlas.clearCache()
        needsLayout = true
        metalView.needsDisplay = true
    }

    func updateLayout() {
        guard let renderer else { return }

        let sessionIds = sessions.map(\.session.id)
        let scale = window?.backingScaleFactor ?? 2.0
        let bounds = self.bounds
        let isGrid = sessions.count > 1

        layoutEngine.focusedSessionId = focusedSessionId
        cachedEntries = layoutEngine.layout(sessionIds: sessionIds, in: bounds)

        var renderEntries: [TerminalRenderer.SessionRenderEntry] = []

        // Content padding: breathing room between view edges and terminal text (points).
        // Left padding is 8px for modern look; right/top/bottom get smaller padding.
        let leftPad: CGFloat = Spacing.sm          // 8px
        let rightPad: CGFloat = Spacing.xs          // 4px
        let topPad: CGFloat = Spacing.xs            // 4px
        let bottomPad: CGFloat = Spacing.xs         // 4px

        for entry in cachedEntries {
            guard let pair = sessions.first(where: { $0.session.id == entry.sessionId }) else { continue }
            let backend = pair.backend

            // Apply grid gap: inset the layout entry frame by half the gap on each side
            var cellFrame = entry.frame
            if isGrid {
                cellFrame = cellFrame.insetBy(dx: gridGap / 2, dy: gridGap / 2)
            }

            // Reserve space for session header bar (in grid mode with 2+ sessions)
            let headerOffset: CGFloat = isGrid ? sessionHeaderHeight : 0
            let terminalFrame = CGRect(
                x: cellFrame.origin.x,
                y: cellFrame.origin.y,
                width: cellFrame.width,
                height: cellFrame.height - headerOffset
            )

            // Asymmetric content padding within the terminal frame
            let insetFrame = CGRect(
                x: terminalFrame.origin.x + leftPad,
                y: terminalFrame.origin.y + bottomPad,
                width: terminalFrame.width - leftPad - rightPad,
                height: terminalFrame.height - topPad - bottomPad
            )

            // cellW/cellH are in scaled font units (font created at size * backingScaleFactor)
            let cellW = renderer.fontManager.cellMetrics.width
            let cellH = renderer.fontManager.cellMetrics.height
            guard cellW > 0 && cellH > 0 && insetFrame.width > 0 && insetFrame.height > 0 else { continue }
            let frameCols = max(1, Int(insetFrame.width * scale / cellW))
            let frameRows = max(1, Int(insetFrame.height * scale / cellH))

            if backend.cols != frameCols || backend.rows != frameRows {
                // Clear selection on resize — cell coordinates are no longer valid
                selection = nil
                renderer.selection = nil
                backend.resize(cols: UInt16(frameCols), rows: UInt16(frameRows))
                if pair.session.ptyFD >= 0 {
                    let gridW = CGFloat(frameCols) * cellW
                    let gridH = CGFloat(frameRows) * cellH
                    resizePTY(fd: pair.session.ptyFD, cols: UInt16(frameCols), rows: UInt16(frameRows),
                              pixelWidth: UInt16(gridW), pixelHeight: UInt16(gridH))
                }
            }

            // Center the terminal grid within the inset frame.
            // The grid may not perfectly fill the available space (cols*cellW < available width),
            // so we distribute the remainder evenly to center the content.
            let gridPixelW = CGFloat(frameCols) * cellW
            let gridPixelH = CGFloat(frameRows) * cellH
            let availW = insetFrame.width * scale
            let availH = insetFrame.height * scale
            let padX = floor((availW - gridPixelW) / 2)
            let padY = floor((availH - gridPixelH) / 2)

            // Pixel coordinates for Metal (Y-flipped), centered within inset frame
            let pixelX = insetFrame.origin.x * scale + padX
            let pixelY = (bounds.height - insetFrame.origin.y - insetFrame.height) * scale + padY
            let pixelW = gridPixelW
            let pixelH = gridPixelH

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

            let isFocused = entry.sessionId == focusedSessionId

            renderEntries.append(TerminalRenderer.SessionRenderEntry(
                backend: backend,
                viewport: viewport,
                scissor: scissor,
                isFocused: isFocused
            ))
        }

        renderer.visibleSessions = renderEntries
        renderer.cursorOpacity = cursorOpacity

        // Convert absolute selection to viewport-relative for the renderer
        if let sel = selection,
           let focusedId = focusedSessionId,
           let pair = sessions.first(where: { $0.session.id == focusedId }) {
            let backend = pair.backend
            let vpStartRow = sel.startRow - backend.scrollbackCount + backend.scrollOffset
            let vpEndRow = sel.endRow - backend.scrollbackCount + backend.scrollOffset

            // Only show selection highlight if it intersects with the viewport
            if vpEndRow >= 0 && vpStartRow < backend.rows {
                renderer.selection = TerminalSelection(
                    startRow: vpStartRow,
                    startCol: sel.startCol,
                    endRow: vpEndRow,
                    endCol: sel.endCol
                )
            } else {
                renderer.selection = nil
            }
        } else {
            renderer.selection = nil
        }

        metalView.needsDisplay = true
        updateSessionOverlays()
    }

    /// Draw borders, headers, dim overlays, and attention rings over each session viewport.
    private func updateSessionOverlays() {
        guard let layer else { return }

        let activeIds = Set(cachedEntries.map(\.sessionId))
        let isGrid = sessions.count > 1

        // Remove stale overlays
        for (id, borderLayer) in sessionBorderLayers where !activeIds.contains(id) {
            borderLayer.removeFromSuperlayer()
            sessionBorderLayers.removeValue(forKey: id)
        }
        for (id, labelLayer) in sessionLabelLayers where !activeIds.contains(id) {
            labelLayer.removeFromSuperlayer()
            sessionLabelLayers.removeValue(forKey: id)
        }
        for (id, attLayer) in sessionAttentionLayers where !activeIds.contains(id) {
            attLayer.removeFromSuperlayer()
            sessionAttentionLayers.removeValue(forKey: id)
        }
        for (id, dimLayer) in sessionDimLayers where !activeIds.contains(id) {
            dimLayer.removeFromSuperlayer()
            sessionDimLayers.removeValue(forKey: id)
        }
        for (id, headerLayer) in sessionHeaderLayers where !activeIds.contains(id) {
            headerLayer.removeFromSuperlayer()
            sessionHeaderLayers.removeValue(forKey: id)
            sessionHeaderDotLayers[id]?.removeFromSuperlayer()
            sessionHeaderDotLayers.removeValue(forKey: id)
            sessionHeaderTextLayers[id]?.removeFromSuperlayer()
            sessionHeaderTextLayers.removeValue(forKey: id)
        }

        for entry in cachedEntries {
            let isFocused = entry.sessionId == focusedSessionId
            let session = sessions.first { $0.session.id == entry.sessionId }?.session

            // Calculate the cell frame with grid gap applied
            var cellFrame = entry.frame
            if isGrid {
                cellFrame = cellFrame.insetBy(dx: gridGap / 2, dy: gridGap / 2)
            }

            // --- Border layer ---
            let borderLayer: CALayer
            if let existing = sessionBorderLayers[entry.sessionId] {
                borderLayer = existing
            } else {
                borderLayer = CALayer()
                borderLayer.zPosition = 10
                layer.addSublayer(borderLayer)
                sessionBorderLayers[entry.sessionId] = borderLayer
            }

            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            borderLayer.frame = cellFrame
            borderLayer.cornerRadius = cellCornerRadius
            borderLayer.masksToBounds = true

            if isGrid {
                let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                if isFocused {
                    // Focused: state-colored border at 40% or DS.borderStrong with shadow
                    let agentState = session?.agentState ?? .inactive
                    let stateNSColor = Self.nsColorForState(agentState)
                    borderLayer.borderColor = stateNSColor.withAlphaComponent(0.40).cgColor
                    borderLayer.borderWidth = 1.5
                    borderLayer.shadowColor = NSColor.black.cgColor
                    borderLayer.shadowOpacity = 0.3
                    borderLayer.shadowRadius = 4
                    borderLayer.shadowOffset = CGSize(width: 0, height: -1)
                    borderLayer.masksToBounds = false
                } else {
                    // Unfocused: subtle border
                    let subtleBorder = isDark
                        ? NSColor.white.withAlphaComponent(0.06)
                        : NSColor.black.withAlphaComponent(0.06)
                    borderLayer.borderColor = subtleBorder.cgColor
                    borderLayer.borderWidth = 0.5
                    borderLayer.shadowOpacity = 0
                    borderLayer.masksToBounds = true
                }
            } else {
                borderLayer.borderWidth = 0
                borderLayer.shadowOpacity = 0
            }
            CATransaction.commit()

            // --- Dim overlay for unfocused sessions ---
            if isGrid && !isFocused {
                let dimLayer: CALayer
                if let existing = sessionDimLayers[entry.sessionId] {
                    dimLayer = existing
                } else {
                    dimLayer = CALayer()
                    dimLayer.zPosition = 8  // Below border (10) but above terminal content
                    layer.addSublayer(dimLayer)
                    sessionDimLayers[entry.sessionId] = dimLayer
                }
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.15)
                dimLayer.frame = cellFrame
                dimLayer.cornerRadius = cellCornerRadius
                dimLayer.masksToBounds = true
                // 15% black overlay dims content to ~85% brightness
                dimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
                dimLayer.isHidden = false
                CATransaction.commit()
            } else {
                if let dimLayer = sessionDimLayers[entry.sessionId] {
                    dimLayer.isHidden = true
                }
            }

            // --- Session Header Bar (grid mode, 2+ sessions) ---
            if isGrid, let session {
                let headerFrame = CGRect(
                    x: cellFrame.origin.x,
                    y: cellFrame.maxY - sessionHeaderHeight,
                    width: cellFrame.width,
                    height: sessionHeaderHeight
                )

                // Header background layer
                let headerLayer: CALayer
                if let existing = sessionHeaderLayers[entry.sessionId] {
                    headerLayer = existing
                } else {
                    headerLayer = CALayer()
                    headerLayer.zPosition = 12
                    // Rounded top corners only via masking
                    headerLayer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                    layer.addSublayer(headerLayer)
                    sessionHeaderLayers[entry.sessionId] = headerLayer
                }

                CATransaction.begin()
                CATransaction.setAnimationDuration(0.15)
                let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                headerLayer.frame = headerFrame
                headerLayer.cornerRadius = cellCornerRadius
                headerLayer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                headerLayer.masksToBounds = true
                // DS.bgSurface: #2A2A2D
                headerLayer.backgroundColor = isDark
                    ? NSColor(red: 0.165, green: 0.165, blue: 0.176, alpha: 1).cgColor
                    : NSColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1).cgColor
                headerLayer.isHidden = false

                // State dot (8px circle)
                let dotLayer: CALayer
                if let existing = sessionHeaderDotLayers[entry.sessionId] {
                    dotLayer = existing
                } else {
                    dotLayer = CALayer()
                    dotLayer.zPosition = 13
                    layer.addSublayer(dotLayer)
                    sessionHeaderDotLayers[entry.sessionId] = dotLayer
                }
                let dotSize: CGFloat = 8
                let dotY = headerFrame.origin.y + (sessionHeaderHeight - dotSize) / 2
                dotLayer.frame = CGRect(x: headerFrame.origin.x + Spacing.sm, y: dotY, width: dotSize, height: dotSize)
                dotLayer.cornerRadius = dotSize / 2
                dotLayer.backgroundColor = Self.nsColorForState(session.agentState).cgColor

                // Header text
                let textLayer: CATextLayer
                if let existing = sessionHeaderTextLayers[entry.sessionId] {
                    textLayer = existing
                } else {
                    textLayer = CATextLayer()
                    textLayer.zPosition = 13
                    textLayer.contentsScale = window?.backingScaleFactor ?? 2.0
                    textLayer.fontSize = 10  // Typo.footnote size
                    textLayer.font = NSFont.systemFont(ofSize: 10, weight: .regular) as CTFont
                    textLayer.truncationMode = .end
                    textLayer.alignmentMode = .left
                    layer.addSublayer(textLayer)
                    sessionHeaderTextLayers[entry.sessionId] = textLayer
                }

                // Build header string: "session-name  Agent Model  ctx: XX%  Xm"
                var parts: [String] = [session.name]
                if let agentType = session.agentType {
                    var agentInfo = agentType.capitalized
                    if let model = session.agentModel {
                        agentInfo += " \u{00B7} \(model)"
                    }
                    parts.append(agentInfo)
                }
                if let ctx = session.agentContext {
                    parts.append("ctx: \(ctx)")
                }
                if let since = session.agentSince {
                    let elapsed = Int(Date().timeIntervalSince(since))
                    if elapsed >= 60 {
                        parts.append("\(elapsed / 60)m")
                    }
                }
                let headerText = parts.joined(separator: "  ")

                textLayer.string = headerText
                textLayer.foregroundColor = isDark
                    ? NSColor.white.withAlphaComponent(0.60).cgColor
                    : NSColor.black.withAlphaComponent(0.60).cgColor

                let textX = headerFrame.origin.x + Spacing.sm + dotSize + Spacing.sm
                let textY = headerFrame.origin.y + (sessionHeaderHeight - 14) / 2
                textLayer.frame = CGRect(
                    x: textX,
                    y: textY,
                    width: headerFrame.width - (textX - headerFrame.origin.x) - Spacing.sm,
                    height: 14
                )

                CATransaction.commit()
            } else {
                sessionHeaderLayers[entry.sessionId]?.isHidden = true
                sessionHeaderDotLayers[entry.sessionId]?.isHidden = true
                sessionHeaderTextLayers[entry.sessionId]?.isHidden = true
            }

            // --- Attention ring for sessions with unread notifications ---
            let hasNotification = session?.hasUnreadNotification ?? false
            if hasNotification {
                let attLayer: CALayer
                if let existing = sessionAttentionLayers[entry.sessionId] {
                    attLayer = existing
                } else {
                    attLayer = CALayer()
                    attLayer.zPosition = 9
                    layer.addSublayer(attLayer)
                    sessionAttentionLayers[entry.sessionId] = attLayer

                    // Pulsing border animation
                    let pulse = CABasicAnimation(keyPath: "borderColor")
                    pulse.fromValue = NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.28, alpha: 0.8).cgColor
                    pulse.toValue = NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.28, alpha: 0.2).cgColor
                    pulse.duration = 1.0
                    pulse.autoreverses = true
                    pulse.repeatCount = .infinity
                    attLayer.add(pulse, forKey: "attentionPulse")
                }
                attLayer.frame = cellFrame
                attLayer.cornerRadius = cellCornerRadius
                attLayer.borderWidth = 2
                attLayer.borderColor = NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.28, alpha: 0.6).cgColor
                attLayer.isHidden = false
            } else {
                sessionAttentionLayers[entry.sessionId]?.isHidden = true
            }

            // --- Label layer (session name in top-right corner, hover only) ---
            // In grid mode with headers, the label is redundant — skip it
            guard !isGrid, let session else {
                sessionLabelLayers[entry.sessionId]?.isHidden = true
                continue
            }

            let labelLayer: CATextLayer
            if let existing = sessionLabelLayers[entry.sessionId] {
                labelLayer = existing
                labelLayer.isHidden = false
            } else {
                labelLayer = CATextLayer()
                labelLayer.zPosition = 11
                labelLayer.contentsScale = window?.backingScaleFactor ?? 2.0
                labelLayer.fontSize = 9
                labelLayer.font = NSFont.systemFont(ofSize: 9, weight: .medium) as CTFont
                labelLayer.cornerRadius = 3
                labelLayer.alignmentMode = .left
                layer.addSublayer(labelLayer)
                sessionLabelLayers[entry.sessionId] = labelLayer
            }

            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)

            let labelText = session.name
            labelLayer.string = " \(labelText) "

            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            labelLayer.foregroundColor = isDark
                ? NSColor.white.withAlphaComponent(0.75).cgColor
                : NSColor.black.withAlphaComponent(0.75).cgColor
            labelLayer.backgroundColor = isDark
                ? NSColor.black.withAlphaComponent(0.55).cgColor
                : NSColor.white.withAlphaComponent(0.75).cgColor

            // Position at top-right of the session frame (NSView coords: top = maxY)
            let labelW: CGFloat = CGFloat(labelText.count) * 6.0 + 12
            let labelH: CGFloat = 16
            labelLayer.frame = CGRect(
                x: cellFrame.maxX - min(labelW, cellFrame.width - 8) - 4,
                y: cellFrame.maxY - labelH - 4,
                width: min(labelW, cellFrame.width - 8),
                height: labelH
            )

            // Only visible on hover or when focused
            let showLabel = (entry.sessionId == hoveredSessionId || isFocused)
            labelLayer.opacity = showLabel ? 1.0 : 0.0

            CATransaction.commit()
        }
    }

    // MARK: - State Color Helper

    /// Returns NSColor for agent state (used for CALayer which needs CGColor).
    private static func nsColorForState(_ state: AgentState) -> NSColor {
        switch state {
        case .working:
            return NSColor(red: 0.204, green: 0.780, blue: 0.349, alpha: 1) // #34C759
        case .needsInput:
            return NSColor(red: 1.000, green: 0.839, blue: 0.039, alpha: 1) // #FFD60A
        case .error:
            return NSColor(red: 1.000, green: 0.271, blue: 0.227, alpha: 1) // #FF453A
        case .inactive:
            return NSColor(red: 0.451, green: 0.451, blue: 0.451, alpha: 1) // #737373
        }
    }

    /// Change the terminal font size, invalidating glyph cache and recalculating layout.
    func setFontSize(_ size: CGFloat) {
        guard let renderer else { return }
        renderer.fontManager.setFontSize(size)
        renderer.atlas.clearCache()
        updateLayout()
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
        // Suppress cancelled/mayBegin phases — these are not actionable scroll input.
        if event.phase == .cancelled || event.phase == .mayBegin { return }

        // Reset the accumulator when the gesture or momentum phase ends, so the
        // next gesture starts fresh without leftover fractional delta.
        if event.phase == .ended || event.momentumPhase == .ended {
            scrollAccumulator = 0
        }

        // Suppress scroll events shortly after focus changes to prevent phantom scrolling
        // from stale NSEvent state delivered by macOS during window/view transitions.
        let timeSinceFocus = CFAbsoluteTimeGetCurrent() - lastFocusChangeTime
        if timeSinceFocus < focusGuardInterval { return }

        guard let focusedId = focusedSessionId,
              let pair = sessions.first(where: { $0.session.id == focusedId }),
              pair.session.ptyFD >= 0 else {
            super.scrollWheel(with: event)
            return
        }

        let backend = pair.backend

        // Suppress momentum scroll events when mouse reporting is active.
        // TUI apps handle their own scroll semantics; momentum would send extra events.
        if event.momentumPhase != [] && backend.isMouseReportingActive { return }

        let deltaY = event.scrollingDeltaY
        guard deltaY != 0 else { return }

        if event.hasPreciseScrollingDeltas {
            // Trackpad (including momentum): accumulate pixel deltas and convert to
            // whole lines when the threshold is reached.  This avoids the old behaviour
            // of always scrolling at least 1 line per event (which felt jerky and broke
            // momentum deceleration).
            //
            // lineHeight is in points — the same coordinate space as scrollingDeltaY
            // when hasPreciseScrollingDeltas is true.
            let scale = window?.backingScaleFactor ?? 2.0
            let lineHeight: CGFloat
            if let cellH = renderer?.fontManager.cellMetrics.height, cellH > 0 {
                lineHeight = cellH / scale  // convert from scaled pixels to points
            } else {
                lineHeight = 14.0           // sensible fallback
            }

            scrollAccumulator += deltaY

            let wholeLines = Int(scrollAccumulator / lineHeight)
            guard wholeLines != 0 else { return }
            // Keep the fractional remainder for the next event.
            scrollAccumulator -= CGFloat(wholeLines) * lineHeight

            let scrollUp = wholeLines > 0
            let absLines = abs(wholeLines)

            if backend.isMouseReportingActive {
                let button = scrollUp ? 4 : 5
                let point = convert(event.locationInWindow, from: nil)
                let cell = cellAt(point: point) ?? (row: 0, col: 0)
                for _ in 0..<absLines {
                    backend.sendMouseEvent(button: button, x: cell.col, y: cell.row)
                }
                if let sendData = backend.pendingSendData() {
                    NotificationCenter.default.post(
                        name: .cosmodromePasteData,
                        object: nil,
                        userInfo: ["data": sendData, "fd": pair.session.ptyFD]
                    )
                }
            } else {
                backend.scroll(lines: scrollUp ? absLines : -absLines)
            }
        } else {
            // Discrete mouse wheel: delta is already in line granularity.
            // No accumulator needed — each click is intentional.
            let lines = max(1, Int(abs(deltaY)))
            let scrollUp = deltaY > 0

            if backend.isMouseReportingActive {
                let button = scrollUp ? 4 : 5
                let point = convert(event.locationInWindow, from: nil)
                let cell = cellAt(point: point) ?? (row: 0, col: 0)
                for _ in 0..<lines {
                    backend.sendMouseEvent(button: button, x: cell.col, y: cell.row)
                }
                if let sendData = backend.pendingSendData() {
                    NotificationCenter.default.post(
                        name: .cosmodromePasteData,
                        object: nil,
                        userInfo: ["data": sendData, "fd": pair.session.ptyFD]
                    )
                }
            } else {
                backend.scroll(lines: scrollUp ? lines : -lines)
            }
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

        // Start selection — store as absolute row coordinates
        if let cell = cellAt(point: point),
           let focusedId = focusedSessionId,
           let pair = sessions.first(where: { $0.session.id == focusedId }) {
            let absRow = cell.row + pair.backend.scrollbackCount - pair.backend.scrollOffset
            selection = TerminalSelection(startRow: absRow, startCol: cell.col,
                                          endRow: absRow, endCol: cell.col)
            isDragging = true
            updateLayout() // Updates renderer.selection with viewport conversion
        } else {
            selection = nil
            renderer?.selection = nil
            isDragging = false
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, var sel = selection,
              let focusedId = focusedSessionId,
              let pair = sessions.first(where: { $0.session.id == focusedId }) else { return }
        let point = convert(event.locationInWindow, from: nil)

        // Auto-scroll when dragging outside the terminal grid
        var scrollDir = 0
        if let entry = cachedEntries.first(where: { $0.sessionId == focusedId }) {
            if point.y < entry.frame.minY {
                // Below bottom edge (NSView coords) -> scroll down (newer content)
                scrollDir = -1
                pair.backend.scroll(lines: -2)
            } else if point.y > entry.frame.maxY {
                // Above top edge (NSView coords) -> scroll up (older content)
                scrollDir = 1
                pair.backend.scroll(lines: 2)
            }
        }

        // Start/stop autoscroll timer for continuous scrolling while mouse is held outside
        if scrollDir != 0 {
            startAutoScroll(direction: scrollDir, pair: pair, selection: &sel)
        } else {
            stopAutoScroll()
        }

        // Use clamped cell coordinates so selection extends to edge when mouse is outside
        let cell = cellAtClamped(point: point)
        let absRow = cell.row + pair.backend.scrollbackCount - pair.backend.scrollOffset
        sel.endRow = absRow
        sel.endCol = cell.col
        selection = sel
        updateLayout()
    }

    override func mouseUp(with event: NSEvent) {
        stopAutoScroll()
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

        pair.backend.scrollToBottom()

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

    /// Like `cellAt` but clamps to the grid edges instead of returning nil.
    /// Used during drag selection so the endpoint stays at the edge when the mouse
    /// moves outside the terminal grid.
    private func cellAtClamped(point: NSPoint) -> (row: Int, col: Int) {
        if let cell = cellAt(point: point) { return cell }
        // Mouse is outside grid — clamp to nearest edge
        guard let _ = renderer,
              let focusedId = focusedSessionId,
              let entry = cachedEntries.first(where: { $0.sessionId == focusedId }),
              let pair = sessions.first(where: { $0.session.id == focusedId }) else { return (row: 0, col: 0) }
        let backend = pair.backend
        let isGrid = sessions.count > 1
        var cellFrame = entry.frame
        if isGrid { cellFrame = cellFrame.insetBy(dx: gridGap / 2, dy: gridGap / 2) }
        let headerOffset: CGFloat = isGrid ? sessionHeaderHeight : 0
        let midY = cellFrame.origin.y + (cellFrame.height - headerOffset) / 2
        // Above midpoint (NSView coords) → top of grid (row 0), below → bottom (last row)
        let row = point.y > midY ? 0 : backend.rows - 1
        let col = point.x < cellFrame.midX ? 0 : backend.cols - 1
        return (row: row, col: col)
    }

    private func startAutoScroll(direction: Int, pair: (session: Session, backend: TerminalBackend), selection: inout TerminalSelection) {
        guard autoScrollTimer == nil else { return }
        let sessionId = pair.session.id
        let scrollAmount = direction > 0 ? 2 : -2
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.isDragging,
                  var sel = self.selection,
                  let p = self.sessions.first(where: { $0.session.id == sessionId }) else {
                self?.stopAutoScroll()
                return
            }
            p.backend.scroll(lines: scrollAmount)
            // Extend selection to the edge row after scrolling
            let edgeRow = scrollAmount > 0 ? 0 : p.backend.rows - 1
            let edgeCol = scrollAmount > 0 ? 0 : p.backend.cols - 1
            let absRow = edgeRow + p.backend.scrollbackCount - p.backend.scrollOffset
            sel.endRow = absRow
            sel.endCol = edgeCol
            self.selection = sel
            self.updateLayout()
        }
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    /// Map a point (in NSView coordinates) to a cell (row, col) in the focused session.
    private func cellAt(point: NSPoint) -> (row: Int, col: Int)? {
        guard let renderer,
              let focusedId = focusedSessionId,
              let entry = cachedEntries.first(where: { $0.sessionId == focusedId }),
              let pair = sessions.first(where: { $0.session.id == focusedId }) else { return nil }

        let scale = window?.backingScaleFactor ?? 2.0
        let cellW = renderer.fontManager.cellMetrics.width
        let cellH = renderer.fontManager.cellMetrics.height
        let backend = pair.backend
        let isGrid = sessions.count > 1

        // Must match the padding/centering logic in updateLayout()
        var cellFrame = entry.frame
        if isGrid {
            cellFrame = cellFrame.insetBy(dx: gridGap / 2, dy: gridGap / 2)
        }
        let headerOffset: CGFloat = isGrid ? sessionHeaderHeight : 0
        let terminalFrame = CGRect(
            x: cellFrame.origin.x,
            y: cellFrame.origin.y,
            width: cellFrame.width,
            height: cellFrame.height - headerOffset
        )
        let leftPad: CGFloat = Spacing.sm
        let rightPad: CGFloat = Spacing.xs
        let topPad: CGFloat = Spacing.xs
        let bottomPad: CGFloat = Spacing.xs
        let insetFrame = CGRect(
            x: terminalFrame.origin.x + leftPad,
            y: terminalFrame.origin.y + bottomPad,
            width: terminalFrame.width - leftPad - rightPad,
            height: terminalFrame.height - topPad - bottomPad
        )

        let gridPixelW = CGFloat(backend.cols) * cellW
        let gridPixelH = CGFloat(backend.rows) * cellH
        let padX = floor((insetFrame.width * scale - gridPixelW) / 2)
        let padY = floor((insetFrame.height * scale - gridPixelH) / 2)

        // Grid origin in NSView points
        let gridOriginX = insetFrame.origin.x + padX / scale
        let gridTopY = insetFrame.maxY - padY / scale

        // Convert point to pixel coordinates relative to grid origin
        let pixelX = (point.x - gridOriginX) * scale
        // NSView Y is bottom-up, cell grid Y is top-down
        let pixelY = (gridTopY - point.y) * scale

        let col = Int(pixelX / cellW)
        let row = Int(pixelY / cellH)

        guard row >= 0 && row < backend.rows && col >= 0 && col < backend.cols else { return nil }
        return (row: row, col: col)
    }

    /// Extract text from the backend for the given selection range.
    /// Selection uses absolute row coordinates; we convert to viewport-relative to read cells.
    private func extractText(from sel: TerminalSelection, backend: TerminalBackend) -> String {
        let (startRow, startCol, endRow, endCol) = sel.normalized()
        var result = ""

        backend.lock()

        // Convert absolute rows to viewport rows
        let vpOffset = backend.scrollbackCount - backend.scrollOffset
        let vpStartRow = startRow - vpOffset
        let vpEndRow = endRow - vpOffset

        // Clamp to visible viewport
        let visibleStart = max(0, vpStartRow)
        let visibleEnd = min(backend.rows - 1, vpEndRow)

        for vpRow in visibleStart...visibleEnd {
            // Map back to absolute row for start/end col determination
            let absRow = vpRow + vpOffset

            let colStart = (absRow == startRow) ? startCol : 0
            let colEnd = (absRow == endRow) ? endCol : backend.cols - 1

            for col in colStart...colEnd {
                guard col >= 0 && col < backend.cols else { continue }
                let cell = backend.cell(row: vpRow, col: col)
                if cell.codepoint > 0 {
                    result.append(Character(UnicodeScalar(cell.codepoint)!))
                }
            }

            // Add newline between rows (but not after last row)
            if absRow < endRow {
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
