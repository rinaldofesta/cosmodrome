import AppKit
import Core
import SwiftUI

final class MainWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate {
    let projectStore = ProjectStore()
    private(set) var sessionManager: SessionManager!
    private var terminalContentView: TerminalContentView!
    private var keybindingManager: KeybindingManager!
    private let paletteState = CommandPaletteState()
    private var paletteOverlay: NSHostingView<CommandPaletteView>?
    private var activityLogOverlay: NSHostingView<AnyView>?
    private var completionBarHost: NSHostingView<AnyView>?
    private var activityLogVisible = false
    private var isDarkTheme = true
    private var mcpServer: MCPServer?
    private var mcpBridge: MCPBridge?
    private var hookServer: HookServer?
    private var controlServer: ControlServer?
    private let modeIndicatorState = ModeIndicatorState()
    private var modeIndicatorHost: NSHostingView<ModeIndicatorView>?
    private let fontSizeState = FontSizeState()
    private var fontSizeHost: NSView?
    private var appearanceObserver: NSObjectProtocol?
    private var fleetOverlayHost: NSHostingView<FleetOverviewView>?
    private var fleetViewVisible = false
    private var splitView: NSSplitView!
    private var activityLogSidebarHost: NSHostingView<AnyView>?
    private var activityLogExpanded = false
    private let userConfig: UserConfig?

    /// User's preferred shell from $SHELL, falling back to /bin/zsh.
    private static let defaultShell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

    init() {
        self.userConfig = Self.loadUserConfig()
        // Clear any saved frame from previous broken runs
        NSWindow.removeFrame(usingName: "CosmodromeMain")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cosmodrome"
        window.center()
        window.minSize = NSSize(width: 800, height: 500)
        window.backgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)
        window.titlebarAppearsTransparent = true

        super.init(window: window)
        window.delegate = self

        sessionManager = SessionManager(projectStore: projectStore)
        keybindingManager = KeybindingManager()
        setupUI()
        setupMCP()
        setupHookServer()
        setupControlServer()
        setupCompletionActions()
        setupTerminalNotifications()
        restoreOrCreateDefaultProject()
        syncWithSystemAppearance()
        observeAppearanceChanges()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    // MARK: - Setup

    private func setupUI() {
        guard let window else { return }

        // All views use autoresizing masks — no Auto Layout anywhere.
        // Mixing the two causes layout conflicts that collapse the window.
        let contentRect = window.contentLayoutRect

        // Container fills the window
        let containerView = NSView(frame: contentRect)
        containerView.autoresizingMask = [.width, .height]
        containerView.wantsLayer = true

        // Status bar at bottom (fixed 28pt)
        let statusBarHeight: CGFloat = 28
        let statusBarHost = NSHostingView(rootView:
            AgentStatusBarView(
                projectStore: projectStore,
                onJumpToSession: { [weak self] projectId, sessionId in
                    self?.jumpToSession(projectId: projectId, sessionId: sessionId)
                },
                onToggleActivityLog: { [weak self] in
                    self?.toggleActivityLog()
                },
                onToggleFleetView: { [weak self] in
                    self?.toggleFleetView()
                }
            )
        )
        statusBarHost.frame = NSRect(x: 0, y: 0, width: contentRect.width, height: statusBarHeight)
        statusBarHost.autoresizingMask = [.width, .maxYMargin]
        containerView.addSubview(statusBarHost)

        // Split view fills above status bar
        let splitFrame = NSRect(
            x: 0, y: statusBarHeight,
            width: contentRect.width,
            height: contentRect.height - statusBarHeight
        )
        let splitView = NSSplitView(frame: splitFrame)
        self.splitView = splitView
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autoresizingMask = [.width, .height]
        splitView.delegate = self
        containerView.addSubview(splitView)

        // Sidebar (200pt initial width)
        let sidebarHost = NSHostingView(rootView:
            SidebarView(
                projectStore: projectStore,
                onSelectProject: { [weak self] id in
                    self?.selectProject(id: id)
                },
                onSelectSession: { [weak self] id in
                    self?.focusSession(id)
                },
                onNewProject: { [weak self] in
                    self?.addNewProject()
                },
                onNewSession: { [weak self] projectId in
                    guard let self,
                          let project = self.projectStore.projects.first(where: { $0.id == projectId }) else { return }
                    self.addSession(to: project)
                },
                onDeleteProject: { [weak self] id in
                    guard let self,
                          let project = self.projectStore.projects.first(where: { $0.id == id }) else { return }
                    for session in project.sessions { self.sessionManager.stopSession(session) }
                    self.projectStore.removeProject(id: id)
                    self.refreshTerminalView()
                },
                onCloseSession: { [weak self] id in
                    guard let self,
                          let project = self.projectStore.activeProject,
                          let session = project.sessions.first(where: { $0.id == id }) else { return }
                    self.sessionManager.stopSession(session)
                    project.sessions.removeAll { $0.id == id }
                    if self.terminalContentView.focusedSessionId == id {
                        self.setFocusedSession(project.sessions.first?.id)
                    }
                    self.refreshTerminalView()
                },
                onRestartSession: { [weak self] id in
                    guard let self,
                          let project = self.projectStore.activeProject,
                          let session = project.sessions.first(where: { $0.id == id }) else { return }
                    if session.isRunning { self.sessionManager.stopSession(session) }
                    do {
                        try self.sessionManager.startSession(session)
                        self.refreshTerminalView()
                    } catch {
                        FileHandle.standardError.write("[Cosmodrome] Failed to restart session: \(error)\n".data(using: .utf8)!)
                    }
                },
                onToggleActivityLog: { [weak self] in
                    self?.toggleActivityLog()
                },
                onToggleFleetView: { [weak self] in
                    self?.toggleFleetView()
                },
                onToggleCommandPalette: { [weak self] in
                    self?.showCommandPalette()
                }
            )
        )
        sidebarHost.frame = NSRect(x: 0, y: 0, width: 200, height: splitFrame.height)

        // Terminal content (fills remaining width)
        terminalContentView = TerminalContentView(
            frame: NSRect(x: 0, y: 0, width: splitFrame.width - 201, height: splitFrame.height),
            userConfig: userConfig
        )
        terminalContentView.wantsLayer = true

        splitView.addArrangedSubview(sidebarHost)
        splitView.addArrangedSubview(terminalContentView)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        splitView.setPosition(200, ofDividerAt: 0)

        // Command palette overlay — positioned over terminal content area only
        let overlay = NSHostingView(rootView: CommandPaletteView(state: paletteState))
        overlay.frame = terminalContentView.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.isHidden = true
        terminalContentView.addSubview(overlay)
        paletteOverlay = overlay

        // Mode indicator overlay (fills terminal area, renders in bottom-right via SwiftUI alignment)
        let modeView = ModeIndicatorView(state: modeIndicatorState)
        let modeHost = NSHostingView(rootView: modeView)
        modeHost.frame = terminalContentView.bounds
        modeHost.autoresizingMask = [.width, .height]
        terminalContentView.addSubview(modeHost)
        modeIndicatorHost = modeHost

        // Font size control overlay (bottom-right, above mode indicator)
        let fontCtrl = FontSizeControlView(
            state: fontSizeState,
            onIncrease: { [weak self] in self?.adjustFontSize(delta: 1) },
            onDecrease: { [weak self] in self?.adjustFontSize(delta: -1) },
            onReset: { [weak self] in self?.resetFontSize() }
        )
        let fontHost = NSHostingView(rootView: fontCtrl)
        let fittingSize = fontHost.fittingSize
        let termBounds = terminalContentView.bounds
        fontHost.frame = NSRect(
            x: termBounds.maxX - fittingSize.width - 12,
            y: 8,
            width: fittingSize.width,
            height: fittingSize.height
        )
        fontHost.autoresizingMask = [.minXMargin, .maxYMargin]
        terminalContentView.addSubview(fontHost)
        fontSizeHost = fontHost

        window.contentView = containerView

        // Hide overlay when palette dismisses itself
        paletteState.onDismiss = { [weak self] in
            self?.paletteOverlay?.isHidden = true
        }

        sessionManager.setDirtyHandler { [weak self] in
            // Only trigger Metal redraw — no layout recalculation needed for content updates
            self?.terminalContentView.metalView.needsDisplay = true
        }

        sessionManager.onSessionListChanged = { [weak self] in
            self?.refreshTerminalView()
        }

        keybindingManager.onModeChanged = { [weak self] mode in
            self?.modeIndicatorState.mode = mode
            self?.modeIndicatorState.isVisible = (mode == .command)
        }

        // Handle paste data from TerminalContentView
        NotificationCenter.default.addObserver(
            forName: .cosmodromePasteData, object: nil, queue: .main
        ) { [weak self] notification in
            guard let data = notification.userInfo?["data"] as? Data,
                  let fd = notification.userInfo?["fd"] as? Int32 else { return }
            self?.sessionManager.multiplexer.send(to: fd, data: data)
        }
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        160 // Sidebar minimum width
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        280 // Sidebar maximum width
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false // Never collapse either pane
    }

    private func restoreOrCreateDefaultProject() {
        if let state = StatePersistence.load(), !state.projects.isEmpty {
            let (projects, activeId) = StatePersistence.restoreProjects(from: state)
            for project in projects {
                projectStore.addProject(project)
                // Start all sessions and feed saved scrollback
                for session in project.sessions {
                    do {
                        try sessionManager.startSession(session)
                        // Feed saved scrollback into the backend
                        if let scrollback = StatePersistence.loadScrollback(for: session.id),
                           !scrollback.isEmpty,
                           let backend = session.backend {
                            // Feed scrollback as plain text so it appears in the terminal
                            let text = scrollback + "\n"
                            if let data = text.data(using: .utf8) {
                                data.withUnsafeBytes { buf in
                                    backend.process(buf)
                                }
                            }
                        }
                    } catch {
                        FileHandle.standardError.write("[Cosmodrome] Failed to restore session '\(session.name)': \(error)\n".data(using: .utf8)!)
                    }
                }
            }
            if let activeId {
                projectStore.setActiveProject(id: activeId)
            }

            // Restore font size (only if user config doesn't specify one)
            if userConfig?.font?.size == nil, let savedSize = state.fontSize {
                terminalContentView.setFontSize(CGFloat(savedSize))
            }
            syncFontSizeState()

            // Restore window frame and zoom state
            if state.windowZoomed {
                // Set a normal-sized frame first, then zoom so macOS enters proper zoom mode
                let defaultFrame = NSRect(x: 0, y: 0, width: 1200, height: 800)
                window?.setFrame(defaultFrame, display: true)
                window?.center()
                window?.zoom(nil)
            } else if state.windowFrame.count == 4 {
                let frame = NSRect(
                    x: state.windowFrame[0],
                    y: state.windowFrame[1],
                    width: state.windowFrame[2],
                    height: state.windowFrame[3]
                )
                window?.setFrame(frame, display: true)
            }
        } else {
            createDefaultProject()
        }

        refreshTerminalView()
        window?.makeFirstResponder(terminalContentView)
    }

    private func createDefaultProject() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let defaultSession = Session(
            name: "Shell",
            command: Self.defaultShell,
            cwd: homeDir
        )
        let project = Project(
            name: "Default",
            sessions: [defaultSession]
        )
        projectStore.addProject(project)

        do {
            try sessionManager.startSession(defaultSession)
        } catch {
            FileHandle.standardError.write("[Cosmodrome] Failed to start default session: \(error)\n".data(using: .utf8)!)
        }
    }

    // MARK: - Session/Project Management

    private func setFocusedSession(_ id: UUID?) {
        terminalContentView.focusedSessionId = id
        projectStore.focusedSessionId = id
    }

    private func focusSession(_ id: UUID) {
        // Clear unread notification when focusing
        if let project = projectStore.activeProject,
           let session = project.sessions.first(where: { $0.id == id }) {
            session.hasUnreadNotification = false
            AgentNotifications.clearNotification(for: session)
        }
        terminalContentView.focusSession(id)
        projectStore.focusedSessionId = id
    }

    private func selectProject(id: UUID) {
        guard id != projectStore.activeProjectId else { return }
        projectStore.setActiveProject(id: id)
        setFocusedSession(nil)
        refreshTerminalView()
        window?.makeFirstResponder(terminalContentView)
    }

    func addNewProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.message = "Select a project directory"
        panel.prompt = "Open Project"

        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let dirPath = url.path
            let projectName = url.lastPathComponent

            // Check if project already exists
            if let existing = self.projectStore.projects.first(where: { $0.rootPath == dirPath }) {
                self.selectProject(id: existing.id)
                return
            }

            let session = Session(
                name: "Shell",
                command: Self.defaultShell,
                cwd: dirPath
            )
            let project = Project(
                name: projectName,
                rootPath: dirPath,
                sessions: [session]
            )
            projectStore.addProject(project)
            projectStore.setActiveProject(id: project.id)

            do {
                try self.sessionManager.startSession(session)
            } catch {
                FileHandle.standardError.write("[Cosmodrome] Failed to start session: \(error)\n".data(using: .utf8)!)
            }

            self.refreshTerminalView()
        }
    }

    func openProject(at url: URL) {
        var configPath: String
        if url.hasDirectoryPath {
            configPath = url.appendingPathComponent("cosmodrome.yml").path
        } else {
            configPath = url.path
        }

        do {
            let project = try projectStore.loadProject(configPath: configPath)
            sessionManager.startAutoStartSessions(for: project)
            refreshTerminalView()
        } catch {
            let dirPath = url.hasDirectoryPath ? url.path : url.deletingLastPathComponent().path
            let session = Session(
                name: "Shell",
                command: Self.defaultShell,
                cwd: dirPath
            )
            let project = Project(
                name: url.lastPathComponent,
                rootPath: dirPath,
                sessions: [session]
            )
            projectStore.addProject(project)
            do { try sessionManager.startSession(session) } catch {}
            refreshTerminalView()
        }
    }

    func addSession(to project: Project) {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let session = Session(
            name: "Shell \(project.sessions.count + 1)",
            command: Self.defaultShell,
            cwd: project.rootPath ?? homeDir
        )
        project.sessions.append(session)

        do {
            try sessionManager.startSession(session)
        } catch {
            FileHandle.standardError.write("[Cosmodrome] Failed to start session: \(error)\n".data(using: .utf8)!)
        }

        // Rebuild sessions array so the new session is visible to the renderer
        refreshTerminalView()
        // Open new session in focus mode (like a new tab)
        focusSession(session.id)
    }

    func addClaudeSession(to project: Project) {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let cwd = project.rootPath ?? homeDir
        let claudeCount = project.sessions.filter { $0.isAgent && $0.agentType == "claude" }.count
        let session = Session(
            name: claudeCount == 0 ? "Claude Code" : "Claude Code \(claudeCount + 1)",
            command: "claude",
            arguments: [],
            cwd: cwd,
            isAgent: true,
            agentType: "claude"
        )
        project.sessions.append(session)

        do {
            try sessionManager.startSession(session)
        } catch {
            FileHandle.standardError.write("[Cosmodrome] Failed to start Claude Code: \(error)\n".data(using: .utf8)!)
        }

        refreshTerminalView()
        focusSession(session.id)
    }

    private func jumpToSession(projectId: UUID, sessionId: UUID) {
        projectStore.setActiveProject(id: projectId)
        setFocusedSession(sessionId)
        refreshTerminalView()
    }

    private func refreshTerminalView() {
        guard let project = projectStore.activeProject else { return }

        let activeSessions: [(session: Session, backend: TerminalBackend)] = project.sessions.compactMap { session in
            guard let backend = session.backend else { return nil }
            return (session: session, backend: backend)
        }

        terminalContentView.sessions = activeSessions

        if terminalContentView.focusedSessionId == nil {
            setFocusedSession(activeSessions.first?.session.id)
        }

        // Force Metal to redraw
        terminalContentView.needsLayout = true
        terminalContentView.metalView.needsDisplay = true
    }

    // MARK: - Command Palette

    private func showCommandPalette() {
        var actions: [PaletteAction] = []

        // --- Attention (top priority) ---
        let attentionSessions = projectStore.sessionsNeedingAttention
        for entry in attentionSessions {
            let state = entry.session.agentState == .needsInput ? "needs input" : "error"
            actions.append(PaletteAction(
                "\(entry.project.name)/\(entry.session.name) — \(state)",
                icon: "exclamationmark.triangle",
                shortcut: "\u{2318}\u{21E7}N",
                category: "Attention"
            ) { [weak self] in
                self?.jumpToSession(projectId: entry.project.id, sessionId: entry.session.id)
            })
        }

        // --- Views ---
        actions.append(PaletteAction(
            activityLogVisible ? "Hide Activity Log" : "Show Activity Log",
            icon: "list.bullet.rectangle",
            shortcut: "\u{2318}L",
            category: "Views"
        ) { [weak self] in
            self?.toggleActivityLog()
        })

        actions.append(PaletteAction(
            activityLogExpanded ? "Close Activity Log Overlay" : "Expand Activity Log",
            icon: "list.bullet.rectangle.portrait",
            shortcut: "\u{2318}\u{21E7}L",
            category: "Views"
        ) { [weak self] in
            self?.expandActivityLog()
        })

        actions.append(PaletteAction(
            fleetViewVisible ? "Hide Fleet Overview" : "Show Fleet Overview",
            icon: "square.grid.2x2",
            shortcut: "\u{2318}\u{21E7}F",
            category: "Views"
        ) { [weak self] in
            self?.toggleFleetView()
        })

        actions.append(PaletteAction(
            "Toggle Focus Mode",
            icon: "rectangle.expand.vertical",
            shortcut: "\u{2318}\u{21A9}",
            category: "Views"
        ) { [weak self] in
            self?.terminalContentView.toggleFocus()
        })

        actions.append(PaletteAction(
            "Dark Mode",
            subtitle: isDarkTheme ? "Switch to light" : "Switch to dark",
            icon: isDarkTheme ? "moon.fill" : "sun.max.fill",
            category: "Views",
            isToggle: true,
            toggleState: isDarkTheme
        ) { [weak self] in
            guard let self else { return }
            self.isDarkTheme.toggle()
            self.applyTheme(self.isDarkTheme ? .dark : .light)
        })

        // --- Sessions ---
        if let project = projectStore.activeProject {
            for (i, session) in project.sessions.enumerated() {
                let sessionStateColor: Color? = session.isAgent && session.agentState != .inactive
                    ? DS.stateColor(for: session.agentState)
                    : nil
                let shortcut = i < 9 ? "\u{2318}\u{21E7}\(i + 1)" : nil
                actions.append(PaletteAction(
                    "Focus \(session.name)",
                    subtitle: "\(project.name) / Session \(i + 1)",
                    icon: session.isAgent ? "cpu" : "terminal",
                    shortcut: shortcut,
                    category: "Sessions",
                    stateColor: sessionStateColor
                ) { [weak self] in
                    self?.focusSession(session.id)
                })
            }
        }

        actions.append(PaletteAction(
            "New Shell Session",
            icon: "plus.rectangle",
            shortcut: "\u{2318}T",
            category: "Sessions"
        ) { [weak self] in
            if let project = self?.projectStore.activeProject {
                self?.addSession(to: project)
            }
        })

        // Recording
        if let focusedId = terminalContentView.focusedSessionId,
           let session = projectStore.activeProject?.sessions.first(where: { $0.id == focusedId }) {
            if sessionManager.isRecording(session: session) {
                actions.append(PaletteAction(
                    "Stop Recording: \(session.name)",
                    icon: "stop.circle",
                    category: "Sessions"
                ) { [weak self] in
                    self?.sessionManager.stopRecording(session: session)
                })
            } else if session.isRunning {
                actions.append(PaletteAction(
                    "Start Recording: \(session.name)",
                    subtitle: "Save as asciicast v2 (.cast)",
                    icon: "record.circle",
                    category: "Sessions"
                ) { [weak self] in
                    self?.sessionManager.startRecording(session: session)
                })
            }
        }

        // --- Projects ---
        for (i, project) in projectStore.projects.enumerated() {
            let shortcut = i < 9 ? "\u{2318}\(i + 1)" : nil
            actions.append(PaletteAction(
                "Switch to \(project.name)",
                subtitle: "\(project.sessions.count) sessions",
                icon: "folder",
                shortcut: shortcut,
                category: "Projects"
            ) { [weak self] in
                self?.selectProject(id: project.id)
            })
        }

        actions.append(PaletteAction(
            "New Project...",
            icon: "folder.badge.plus",
            shortcut: "\u{2318}\u{21E7}T",
            category: "Projects"
        ) { [weak self] in
            self?.addNewProject()
        })

        // --- Dev Servers (framework-detected) ---
        if let project = projectStore.activeProject, let rootPath = project.rootPath {
            let detector = FrameworkDetector()
            let frameworks = detector.detect(in: rootPath)
            for fw in frameworks {
                actions.append(PaletteAction(
                    "Start \(fw.name)",
                    subtitle: ([fw.command] + fw.arguments).joined(separator: " "),
                    icon: "play.fill",
                    category: "Dev Servers"
                ) { [weak self] in
                    guard let self else { return }
                    let session = Session(
                        name: fw.name,
                        command: fw.command,
                        arguments: fw.arguments,
                        cwd: rootPath,
                        autoRestart: true
                    )
                    project.sessions.append(session)
                    do { try self.sessionManager.startSession(session) } catch {}
                    self.refreshTerminalView()
                    self.focusSession(session.id)
                })
            }
        }

        paletteOverlay?.isHidden = false
        paletteState.show(actions: actions)
    }

    private func showOpenProjectPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = []
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openProject(at: url)
        }
    }

    // MARK: - Theme

    private func applyTheme(_ theme: Theme) {
        terminalContentView.renderer?.applyTheme(theme, metalView: terminalContentView.metalView)
        let bg = parseHexColor(theme.colors.background) ?? (r: Float(0.1), g: Float(0.1), b: Float(0.12))
        window?.backgroundColor = NSColor(
            red: CGFloat(bg.r), green: CGFloat(bg.g), blue: CGFloat(bg.b), alpha: 1.0
        )
        // Sync window chrome with theme — this triggers DS adaptive colors to re-resolve
        window?.appearance = NSAppearance(named: theme.name == "Light" ? .aqua : .darkAqua)
        // Refresh CALayer overlays (they use resolved CGColors, not dynamic)
        terminalContentView.updateLayout()
    }

    private func syncWithSystemAppearance() {
        isDarkTheme = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        applyTheme(isDarkTheme ? .dark : .light)
    }

    private func observeAppearanceChanges() {
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.syncWithSystemAppearance()
        }
    }

    // MARK: - Project/Session Cycling

    private func cycleProject(forward: Bool) {
        let projects = projectStore.projects
        guard projects.count > 1 else { return }
        guard let currentIdx = projects.firstIndex(where: { $0.id == projectStore.activeProjectId }) else { return }
        let nextIdx = forward
            ? (currentIdx + 1) % projects.count
            : (currentIdx - 1 + projects.count) % projects.count
        selectProject(id: projects[nextIdx].id)
    }

    private func cycleSession(forward: Bool) {
        guard let project = projectStore.activeProject else { return }
        let sessions = project.sessions
        guard sessions.count > 1 else { return }
        let currentId = terminalContentView.focusedSessionId ?? sessions.first?.id
        guard let currentIdx = sessions.firstIndex(where: { $0.id == currentId }) else { return }
        let nextIdx = forward
            ? (currentIdx + 1) % sessions.count
            : (currentIdx - 1 + sessions.count) % sessions.count
        focusSession(sessions[nextIdx].id)
    }

    // MARK: - Keybindings

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        // If command palette is visible, handle its input
        if paletteState.isVisible {
            switch event.keyCode {
            case 53: // Escape
                paletteState.dismiss()
                paletteOverlay?.isHidden = true
                return true
            case 126: // Up
                paletteState.moveUp()
                return true
            case 125: // Down
                paletteState.moveDown()
                return true
            case 36: // Return
                paletteState.confirm()
                paletteOverlay?.isHidden = true
                return true
            default:
                return false // Let the text field handle it
            }
        }

        // If a non-terminal view has focus (e.g., sidebar rename TextField),
        // let normal event dispatch handle non-command keystrokes.
        // Cmd+key app shortcuts (Cmd+T, Cmd+W, etc.) still processed below.
        if let firstResponder = window?.firstResponder,
           !(firstResponder is TerminalContentView) {
            if !event.modifierFlags.contains(.command) {
                return false  // Regular keys → text field
            }
            // Let Edit menu handle Cmd+C/V/X/Z in text fields
            let editKeys: Set<UInt16> = [8, 9, 6, 7]  // c, v, z, x
            if editKeys.contains(event.keyCode) {
                return false
            }
            // Other Cmd+key combos fall through to keybinding processing below
        }

        // Cmd+C: copy selection (if any), otherwise send Ctrl+C
        if event.modifierFlags.contains(.command) && event.keyCode == 8 { // 'c'
            if terminalContentView.selection != nil {
                terminalContentView.copySelection()
                return true
            }
            // No selection → send Ctrl+C to PTY
            if let focusedId = terminalContentView.focusedSessionId ?? terminalContentView.sessions.first?.session.id,
               let pair = terminalContentView.sessions.first(where: { $0.session.id == focusedId }),
               pair.session.ptyFD >= 0 {
                sessionManager.multiplexer.send(to: pair.session.ptyFD, data: Data([0x03]))
                return true
            }
        }

        // Cmd+V: paste from clipboard
        if event.modifierFlags.contains(.command) && event.keyCode == 9 { // 'v'
            terminalContentView.pasteFromClipboard()
            return true
        }

        // Ctrl+Space toggles between normal and command mode
        if event.keyCode == 49 && event.modifierFlags.contains(.control) {
            keybindingManager.toggleMode()
            return true
        }

        // Let Cmd+Q pass through to the menu system for app termination
        if event.modifierFlags.contains(.command) && event.keyCode == 12 { // 'q'
            return false
        }

        guard let action = keybindingManager.match(event: event) else {
            // In command mode, suppress all keys that aren't bound
            if keybindingManager.suppressesPTYInput {
                return true
            }
            // No keybinding matched — forward keystroke to the terminal PTY
            if let focusedId = terminalContentView.focusedSessionId ?? terminalContentView.sessions.first?.session.id,
               let pair = terminalContentView.sessions.first(where: { $0.session.id == focusedId }),
               pair.session.ptyFD >= 0 {
                if let data = encodeKeyForPTY(event) {
                    pair.backend.scrollToBottom()
                    sessionManager.multiplexer.send(to: pair.session.ptyFD, data: data)
                    return true
                }
            }
            return false
        }

        switch action {
        case .projectByIndex(let idx):
            projectStore.setActiveProject(index: idx)
            refreshTerminalView()

        case .toggleFocus:
            terminalContentView.toggleFocus()

        case .toggleActivityLog:
            toggleActivityLog()

        case .newSession:
            if let project = projectStore.activeProject {
                addSession(to: project)
            }

        case .newProject:
            addNewProject()

        case .jumpNextNeedsInput:
            let current = terminalContentView.focusedSessionId
            if let next = projectStore.nextSessionNeedingInput(after: current) {
                jumpToSession(projectId: next.project.id, sessionId: next.session.id)
            }

        case .closeSession:
            guard let focusedId = terminalContentView.focusedSessionId,
                  let project = projectStore.activeProject,
                  let session = project.sessions.first(where: { $0.id == focusedId }) else { break }
            sessionManager.stopSession(session)
            project.sessions.removeAll { $0.id == focusedId }
            setFocusedSession(project.sessions.first?.id)
            refreshTerminalView()

        case .commandPalette:
            showCommandPalette()

        case .projectNext:
            cycleProject(forward: true)

        case .projectPrevious:
            cycleProject(forward: false)

        case .sessionNext:
            cycleSession(forward: true)

        case .sessionPrevious:
            cycleSession(forward: false)

        case .enterNormalMode:
            keybindingManager.setMode(.normal)

        case .increaseFontSize:
            adjustFontSize(delta: 1)

        case .decreaseFontSize:
            adjustFontSize(delta: -1)

        case .resetFontSize:
            resetFontSize()

        case .toggleFleetView:
            toggleFleetView()

        case .expandActivityLog:
            expandActivityLog()
        }

        return true
    }

    // MARK: - Font Size

    private func adjustFontSize(delta: CGFloat) {
        guard let fm = terminalContentView.renderer?.fontManager else { return }
        terminalContentView.setFontSize(fm.fontSize + delta)
        syncFontSizeState()
    }

    private func resetFontSize() {
        guard let fm = terminalContentView.renderer?.fontManager else { return }
        terminalContentView.setFontSize(fm.defaultFontSize)
        syncFontSizeState()
    }

    private func syncFontSizeState() {
        if let fm = terminalContentView.renderer?.fontManager {
            fontSizeState.currentSize = fm.fontSize
        }
    }

    // MARK: - Key Encoding

    private func encodeKeyForPTY(_ event: NSEvent) -> Data? {
        let modifiers = event.modifierFlags
        let hasShift = modifiers.contains(.shift)
        let hasAlt = modifiers.contains(.option)
        let hasCtrl = modifiers.contains(.control)

        // xterm modifier parameter: 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0)
        let modParam = 1 + (hasShift ? 1 : 0) + (hasAlt ? 2 : 0) + (hasCtrl ? 4 : 0)
        let hasModifiers = modParam > 1

        // Special keys
        switch event.keyCode {
        case 36: return Data([0x0D])   // Return
        case 48:                        // Tab
            if hasShift {
                return Data([0x1B, 0x5B, 0x5A])  // Shift+Tab → ESC [ Z (back tab)
            }
            return Data([0x09])
        case 51: return Data([0x7F])   // Backspace
        case 53: return Data([0x1B])   // Escape

        // Arrow keys: ESC[1;{mod}{letter} when modified, ESC[{letter} when plain
        case 123: // Left
            if hasModifiers { return "\u{1B}[1;\(modParam)D".data(using: .utf8) }
            return Data([0x1B, 0x5B, 0x44])
        case 124: // Right
            if hasModifiers { return "\u{1B}[1;\(modParam)C".data(using: .utf8) }
            return Data([0x1B, 0x5B, 0x43])
        case 125: // Down
            if hasModifiers { return "\u{1B}[1;\(modParam)B".data(using: .utf8) }
            return Data([0x1B, 0x5B, 0x42])
        case 126: // Up
            if hasModifiers { return "\u{1B}[1;\(modParam)A".data(using: .utf8) }
            return Data([0x1B, 0x5B, 0x41])

        // Navigation keys: ESC[{code};{mod}~ when modified
        case 116: // Page Up
            if hasModifiers { return "\u{1B}[5;\(modParam)~".data(using: .utf8) }
            return Data([0x1B, 0x5B, 0x35, 0x7E])
        case 121: // Page Down
            if hasModifiers { return "\u{1B}[6;\(modParam)~".data(using: .utf8) }
            return Data([0x1B, 0x5B, 0x36, 0x7E])
        case 115: // Home
            if hasModifiers { return "\u{1B}[1;\(modParam)H".data(using: .utf8) }
            return Data([0x1B, 0x5B, 0x48])
        case 119: // End
            if hasModifiers { return "\u{1B}[1;\(modParam)F".data(using: .utf8) }
            return Data([0x1B, 0x5B, 0x46])
        case 117: // Delete forward
            if hasModifiers { return "\u{1B}[3;\(modParam)~".data(using: .utf8) }
            return Data([0x1B, 0x5B, 0x33, 0x7E])

        // Function keys F1-F12
        case 122: return functionKeyEscape(code: "P", modParam: modParam)   // F1
        case 120: return functionKeyEscape(code: "Q", modParam: modParam)   // F2
        case 99:  return functionKeyEscape(code: "R", modParam: modParam)   // F3
        case 118: return functionKeyEscape(code: "S", modParam: modParam)   // F4
        case 96:  return "\u{1B}[\(hasModifiers ? "15;\(modParam)" : "15")~".data(using: .utf8)  // F5
        case 97:  return "\u{1B}[\(hasModifiers ? "17;\(modParam)" : "17")~".data(using: .utf8)  // F6
        case 98:  return "\u{1B}[\(hasModifiers ? "18;\(modParam)" : "18")~".data(using: .utf8)  // F7
        case 100: return "\u{1B}[\(hasModifiers ? "19;\(modParam)" : "19")~".data(using: .utf8)  // F8
        case 101: return "\u{1B}[\(hasModifiers ? "20;\(modParam)" : "20")~".data(using: .utf8)  // F9
        case 109: return "\u{1B}[\(hasModifiers ? "21;\(modParam)" : "21")~".data(using: .utf8)  // F10
        case 103: return "\u{1B}[\(hasModifiers ? "23;\(modParam)" : "23")~".data(using: .utf8)  // F11
        case 111: return "\u{1B}[\(hasModifiers ? "24;\(modParam)" : "24")~".data(using: .utf8)  // F12

        default: break
        }

        // Ctrl+key
        if hasCtrl, let chars = event.charactersIgnoringModifiers {
            if let scalar = chars.unicodeScalars.first {
                let value = scalar.value
                // a-z → Ctrl codes 1-26
                if value >= 0x61 && value <= 0x7A {
                    return Data([UInt8(value - 0x60)])
                }
                // Ctrl+special: @[\]^_
                switch value {
                case 0x40: return Data([0x00]) // Ctrl+@ → NUL
                case 0x5B: return Data([0x1B]) // Ctrl+[ → ESC
                case 0x5C: return Data([0x1C]) // Ctrl+\ → FS
                case 0x5D: return Data([0x1D]) // Ctrl+] → GS
                case 0x5E: return Data([0x1E]) // Ctrl+^ → RS
                case 0x5F: return Data([0x1F]) // Ctrl+_ → US
                default: break
                }
            }
        }

        // Alt/Option as ESC prefix (for Alt+key combos like Alt+b, Alt+f in readline)
        if hasAlt && !hasCtrl, let chars = event.charactersIgnoringModifiers,
           let data = chars.data(using: .utf8) {
            var result = Data([0x1B])
            result.append(data)
            return result
        }

        // Regular character input
        if let chars = event.characters, let data = chars.data(using: .utf8) {
            return data
        }

        return nil
    }

    /// Encode F1-F4 (SS3 format: ESC O {code}) or with modifiers (CSI format: ESC [1;{mod}{code}).
    private func functionKeyEscape(code: String, modParam: Int) -> Data? {
        if modParam > 1 {
            return "\u{1B}[1;\(modParam)\(code)".data(using: .utf8)
        }
        return "\u{1B}O\(code)".data(using: .utf8)
    }

    // MARK: - Activity Log

    private func toggleActivityLog() {
        activityLogVisible.toggle()

        if activityLogVisible {
            // Close expanded overlay if open
            if activityLogExpanded {
                hideActivityLogOverlay()
                activityLogExpanded = false
            }
            showActivityLogPanel()
        } else {
            hideActivityLogPanel()
        }
    }

    private func expandActivityLog() {
        activityLogExpanded.toggle()

        if activityLogExpanded {
            // Close panel if open
            if activityLogVisible {
                hideActivityLogPanel()
                activityLogVisible = false
            }
            showActivityLogOverlay()
        } else {
            hideActivityLogOverlay()
        }
    }

    private func showActivityLogPanel() {
        // Show compact activity log as a right-side panel overlaid on the terminal content view
        activityLogSidebarHost?.removeFromSuperview()

        let logView = ActivityLogView(
            projects: projectStore.projects,
            compact: true,
            onFocusSession: { [weak self] projectId, sessionId in
                self?.hideActivityLogPanel()
                self?.activityLogVisible = false
                self?.jumpToSession(projectId: projectId, sessionId: sessionId)
            },
            onExpand: { [weak self] in
                self?.hideActivityLogPanel()
                self?.activityLogVisible = false
                self?.activityLogExpanded = true
                self?.showActivityLogOverlay()
            },
            onDismiss: { [weak self] in
                self?.hideActivityLogPanel()
                self?.activityLogVisible = false
            }
        )

        let host = NSHostingView(rootView: AnyView(logView))
        let panelWidth: CGFloat = 280
        let contentBounds = terminalContentView.bounds
        host.frame = NSRect(
            x: contentBounds.width - panelWidth,
            y: 0,
            width: panelWidth,
            height: contentBounds.height
        )
        host.autoresizingMask = [.minXMargin, .height]
        terminalContentView.addSubview(host)
        activityLogSidebarHost = host
    }

    private func hideActivityLogPanel() {
        activityLogSidebarHost?.removeFromSuperview()
        activityLogSidebarHost = nil
        window?.makeFirstResponder(terminalContentView)
    }

    private func showActivityLogOverlay() {
        guard let window, let containerView = window.contentView else { return }

        activityLogOverlay?.removeFromSuperview()

        let logView = ActivityLogView(
            projects: projectStore.projects,
            compact: false,
            onFocusSession: { [weak self] projectId, sessionId in
                self?.hideActivityLogOverlay()
                self?.activityLogExpanded = false
                self?.jumpToSession(projectId: projectId, sessionId: sessionId)
            },
            onDismiss: { [weak self] in
                self?.hideActivityLogOverlay()
                self?.activityLogExpanded = false
            }
        )

        let host = NSHostingView(rootView: AnyView(logView))
        host.frame = containerView.bounds
        host.autoresizingMask = [.width, .height]
        containerView.addSubview(host)
        activityLogOverlay = host
    }

    private func hideActivityLogOverlay() {
        activityLogOverlay?.removeFromSuperview()
        activityLogOverlay = nil
        window?.makeFirstResponder(terminalContentView)
    }

    // MARK: - Fleet Overview

    private func toggleFleetView() {
        fleetViewVisible.toggle()

        if fleetViewVisible {
            showFleetView()
        } else {
            hideFleetView()
        }
    }

    private func showFleetView() {
        guard let window, let containerView = window.contentView else { return }

        fleetOverlayHost?.removeFromSuperview()

        let fleetView = FleetOverviewView(
            projectStore: projectStore,
            onFocusSession: { [weak self] projectId, sessionId in
                self?.hideFleetView()
                self?.fleetViewVisible = false
                self?.jumpToSession(projectId: projectId, sessionId: sessionId)
            },
            onDismiss: { [weak self] in
                self?.hideFleetView()
                self?.fleetViewVisible = false
            }
        )

        let host = NSHostingView(rootView: fleetView)
        host.frame = containerView.bounds
        host.autoresizingMask = [.width, .height]
        containerView.addSubview(host)
        fleetOverlayHost = host
    }

    private func hideFleetView() {
        fleetOverlayHost?.removeFromSuperview()
        fleetOverlayHost = nil
        window?.makeFirstResponder(terminalContentView)
    }

    // MARK: - Completion Actions

    private func setupCompletionActions() {
        sessionManager.onTaskCompleted = { [weak self] session, context in
            self?.showCompletionBar(session: session, context: context)
        }
    }

    private func showCompletionBar(session: Session, context: CompletionActions.CompletionContext) {
        guard let containerView = window?.contentView else { return }

        // Remove existing bar
        completionBarHost?.removeFromSuperview()

        let actions = CompletionActions.suggest(context: context)

        guard !actions.isEmpty else { return }

        let summaryText = CompletionActions.summaryLine(context: context)

        let barView = CompletionSuggestionBar(
            actions: actions,
            summaryText: summaryText,
            onAction: { [weak self] actionId in
                self?.handleCompletionAction(actionId, session: session, filesChanged: context.filesChanged)
                self?.dismissCompletionBar()
            },
            onDismiss: { [weak self] in
                self?.dismissCompletionBar()
            }
        )

        let host = NSHostingView(rootView: AnyView(barView))
        let barHeight: CGFloat = 44
        host.frame = NSRect(
            x: 200, // after sidebar
            y: 28, // above status bar
            width: containerView.bounds.width - 200,
            height: barHeight
        )
        host.autoresizingMask = [.width, .maxYMargin]
        containerView.addSubview(host)
        completionBarHost = host
    }

    private func dismissCompletionBar() {
        completionBarHost?.removeFromSuperview()
        completionBarHost = nil
    }

    private func handleCompletionAction(_ actionId: String, session: Session, filesChanged: [String]) {
        guard let project = sessionManager.findProject(for: session) else { return }

        switch actionId {
        case "open_diff":
            // Open a new session running git diff on the changed files
            let fileArgs = filesChanged.prefix(20).joined(separator: " ")
            let diffSession = Session(
                name: "diff",
                command: Self.defaultShell,
                arguments: ["-c", "git diff \(fileArgs); read"],
                cwd: project.rootPath ?? session.cwd
            )
            project.sessions.append(diffSession)
            do { try sessionManager.startSession(diffSession) } catch {}
            setFocusedSession(diffSession.id)
            refreshTerminalView()

        case "run_tests":
            // Open a new session running the test command
            let testSession = Session(
                name: "tests",
                command: Self.defaultShell,
                arguments: ["-c", "swift test; read"],
                cwd: project.rootPath ?? session.cwd
            )
            project.sessions.append(testSession)
            do { try sessionManager.startSession(testSession) } catch {}
            setFocusedSession(testSession.id)
            refreshTerminalView()

        case "start_review":
            // Open a new Claude Code session with a review prompt
            let prompt = CompletionActions.reviewPrompt(filesChanged: filesChanged)
            let reviewSession = Session(
                name: "review",
                command: "claude",
                arguments: ["-p", prompt],
                cwd: project.rootPath ?? session.cwd,
                isAgent: true,
                agentType: "claude"
            )
            project.sessions.append(reviewSession)
            do { try sessionManager.startSession(reviewSession) } catch {}
            setFocusedSession(reviewSession.id)
            refreshTerminalView()

        default:
            break
        }
    }

    // MARK: - MCP Server

    private func setupMCP() {
        // Only start MCP server if launched with --mcp flag
        guard CommandLine.arguments.contains("--mcp") else { return }

        let server = MCPServer()
        let bridge = MCPBridge()
        bridge.sessionManager = sessionManager
        bridge.projectStore = projectStore
        bridge.onFocusSession = { [weak self] sessionId in
            guard let self else { return }
            // Find which project contains this session and jump to it
            for project in self.projectStore.projects {
                if project.sessions.contains(where: { $0.id == sessionId }) {
                    self.jumpToSession(projectId: project.id, sessionId: sessionId)
                    return
                }
            }
        }
        server.delegate = bridge
        server.start()
        self.mcpServer = server
        self.mcpBridge = bridge
    }

    private func setupHookServer() {
        let server = HookServer()
        let socketPath = server.start()
        sessionManager.hookSocketPath = socketPath

        server.onEvent = { [weak self] event in
            guard let self else { return }
            let sessionId = event.sessionId

            DispatchQueue.main.async {
                if let sid = sessionId {
                    for project in self.projectStore.projects {
                        if let session = project.sessions.first(where: { $0.id == sid }) {
                            // Upgrade to agent session if not already (hook = agent is running)
                            if !session.isAgent {
                                self.sessionManager.upgradeToAgentSession(session: session, agentType: "claude")
                            }

                            // Forward hook event to detector
                            // Events flow through detector → consumeEvents() → activity log in onOutput
                            self.sessionManager.detectors[sid]?.ingestHookEvent(event)
                            return
                        }
                    }
                }
                // Fallback: append to active project
                if let kind = event.toEventKind(), let project = self.projectStore.activeProject {
                    project.activityLog.append(ActivityEvent(
                        timestamp: event.timestamp,
                        sessionId: sessionId ?? UUID(),
                        sessionName: "hook",
                        kind: kind
                    ))
                }
            }
        }

        self.hookServer = server
    }

    // MARK: - Control Server

    private func setupControlServer() {
        let server = ControlServer()
        server.onCommand = { [weak self] request in
            guard let self else { return .failure("App not available") }
            return self.handleControlCommand(request)
        }
        server.start()
        self.controlServer = server
    }

    private func handleControlCommand(_ request: ControlRequest) -> ControlResponse {
        // Commands execute on the control queue; dispatch to main for UI operations
        switch request.command {
        case "list-projects":
            var result: [[String: Any]] = []
            for project in projectStore.projects {
                var p: [String: Any] = [
                    "id": project.id.uuidString,
                    "name": project.name,
                    "sessions": project.sessions.count,
                    "state": "\(project.aggregateState)",
                ]
                if let rootPath = project.rootPath { p["path"] = rootPath }
                result.append(p)
            }
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                return .success(json)
            }
            return .success("[]")

        case "list-sessions":
            let projectId = request.args?["project_id"]
            let project: Project?
            if let pid = projectId, let uuid = UUID(uuidString: pid) {
                project = projectStore.projects.first { $0.id == uuid }
            } else {
                project = projectStore.activeProject
            }
            guard let project else { return .failure("Project not found") }

            var result: [[String: Any]] = []
            for session in project.sessions {
                var s: [String: Any] = [
                    "id": session.id.uuidString,
                    "name": session.name,
                    "command": session.command,
                    "running": session.isRunning,
                    "agent_state": "\(session.agentState)",
                ]
                if !session.detectedPorts.isEmpty {
                    s["ports"] = session.detectedPorts.map { Int($0) }
                }
                result.append(s)
            }
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                return .success(json)
            }
            return .success("[]")

        case "focus":
            guard let sessionIdStr = request.args?["session_id"],
                  let sessionId = UUID(uuidString: sessionIdStr) else {
                return .failure("Missing session_id")
            }
            DispatchQueue.main.sync {
                for project in self.projectStore.projects {
                    if project.sessions.contains(where: { $0.id == sessionId }) {
                        self.jumpToSession(projectId: project.id, sessionId: sessionId)
                        return
                    }
                }
            }
            return .success("focused")

        case "status":
            var info: [String: Any] = [
                "projects": projectStore.projects.count,
                "total_sessions": projectStore.projects.reduce(0) { $0 + $1.sessions.count },
                "active_project": projectStore.activeProject?.name ?? "none",
            ]
            // Collect attention items
            let attention = projectStore.sessionsNeedingAttention
            if !attention.isEmpty {
                info["attention"] = attention.map { "\($0.project.name)/\($0.session.name): \($0.session.agentState)" }
            }
            if let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                return .success(json)
            }
            return .success("{}")

        case "content":
            guard let sessionIdStr = request.args?["session_id"],
                  let sessionId = UUID(uuidString: sessionIdStr) else {
                return .failure("Missing session_id")
            }
            for project in projectStore.projects {
                if let session = project.sessions.first(where: { $0.id == sessionId }),
                   let backend = session.backend {
                    let lines = request.args?["lines"].flatMap { Int($0) }
                    let content = extractContent(from: backend, lastN: lines)
                    return .success(content)
                }
            }
            return .failure("Session not found")

        case "fleet-stats":
            let counts = projectStore.fleetAgentCounts
            var info: [String: Any] = [
                "agents_total": counts.total,
                "agents_working": counts.working,
                "agents_idle": counts.idle,
                "agents_needs_input": counts.needsInput,
                "agents_error": counts.error,
                "total_cost": projectStore.fleetTotalCost,
                "total_tasks": projectStore.fleetTotalTasks,
                "total_files_changed": projectStore.fleetTotalFilesChanged,
            ]
            // Per-project stats
            var projectStats: [[String: Any]] = []
            for project in projectStore.projects {
                let pc = project.agentCounts
                projectStats.append([
                    "name": project.name,
                    "agents": pc.working + pc.idle + pc.needsInput + pc.error,
                    "cost": project.totalCost,
                    "tasks": project.totalTasks,
                ])
            }
            info["projects"] = projectStats
            if let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                return .success(json)
            }
            return .success("{}")

        case "activity":
            var allEvents: [ActivityEvent] = []
            for project in projectStore.projects {
                allEvents.append(contentsOf: project.activityLog.events)
            }

            // Filter by time window
            if let minutesStr = request.args?["since_minutes"], let minutes = Int(minutesStr) {
                let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
                allEvents = allEvents.filter { $0.timestamp > cutoff }
            }

            // Filter by session
            if let sessionIdStr = request.args?["session_id"],
               let sessionId = UUID(uuidString: sessionIdStr) {
                allEvents = allEvents.filter { $0.sessionId == sessionId }
            }

            // Filter by category
            if let categoryStr = request.args?["category"],
               let category = EventCategory(rawValue: categoryStr) {
                allEvents = allEvents.filter { $0.kind.category == category }
            }

            allEvents.sort { $0.timestamp < $1.timestamp }

            let formatter = ISO8601DateFormatter()
            var jsonEvents: [[String: Any]] = []
            for event in allEvents.suffix(500) {
                var dict: [String: Any] = [
                    "timestamp": formatter.string(from: event.timestamp),
                    "session": event.sessionName,
                    "kind": event.kind.label,
                ]
                switch event.kind {
                case .fileRead(let path):
                    dict["path"] = path
                case .fileWrite(let path, let added, let removed):
                    dict["path"] = path
                    if let a = added { dict["added"] = a }
                    if let r = removed { dict["removed"] = r }
                case .commandRun(let cmd):
                    dict["command"] = cmd
                case .commandCompleted(let cmd, let exit, _):
                    if let c = cmd { dict["command"] = c }
                    if let e = exit { dict["exitCode"] = e }
                case .error(let msg):
                    dict["message"] = msg
                case .taskCompleted(let dur):
                    dict["duration"] = dur
                case .subagentStarted(let name, let desc):
                    dict["name"] = name
                    dict["description"] = desc
                case .subagentCompleted(let name, let dur):
                    dict["name"] = name
                    dict["duration"] = dur
                default:
                    break
                }
                jsonEvents.append(dict)
            }

            if let data = try? JSONSerialization.data(withJSONObject: jsonEvents, options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                return .success(json)
            }
            return .success("[]")

        default:
            return .failure("Unknown command: \(request.command). Available: list-projects, list-sessions, focus, status, content, fleet-stats, activity")
        }
    }

    private func extractContent(from backend: TerminalBackend, lastN: Int? = nil) -> String {
        backend.lock()
        defer { backend.unlock() }

        let totalRows = backend.rows
        let startRow = lastN.map { max(0, totalRows - $0) } ?? 0
        var lines: [String] = []

        for row in startRow..<totalRows {
            var line = ""
            for col in 0..<backend.cols {
                let cell = backend.cell(row: row, col: col)
                let cp = cell.codepoint
                if cp >= 32, let scalar = Unicode.Scalar(cp) {
                    line.append(Character(scalar))
                } else {
                    line.append(" ")
                }
            }
            while line.hasSuffix(" ") { line.removeLast() }
            lines.append(line)
        }

        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: - Terminal Notifications (OSC 777)

    private func setupTerminalNotifications() {
        sessionManager.onTerminalNotification = { [weak self] session, notification in
            guard let self else { return }
            // Don't notify for the currently focused session
            if session.id == self.terminalContentView.focusedSessionId { return }

            // Send macOS notification
            if let project = self.sessionManager.findProject(for: session) {
                AgentNotifications.notifyTerminal(
                    project: project,
                    session: session,
                    notification: notification
                )
            }

            // Trigger UI refresh for attention ring
            self.terminalContentView.updateLayout()
        }
    }

    // MARK: - State Persistence

    func saveState() {
        StatePersistence.save(
            window: window,
            projectStore: projectStore,
            fontSize: terminalContentView.renderer?.fontManager.fontSize
        )
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        // Reset the phantom scroll guard timer so the content view suppresses
        // stale scroll events delivered by macOS right after window activation.
        terminalContentView?.resetFocusGuard()
    }

    func windowWillClose(_ notification: Notification) {
        saveState()
        for project in projectStore.projects {
            for session in project.sessions {
                sessionManager.stopSession(session)
            }
        }
    }

    private static func loadUserConfig() -> UserConfig? {
        let path = NSString(string: "~/.config/cosmodrome/config.yml").expandingTildeInPath
        return try? ConfigParser().parseUserConfig(at: path)
    }
}
