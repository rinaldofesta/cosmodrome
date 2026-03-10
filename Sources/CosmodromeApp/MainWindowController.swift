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
    private let modeIndicatorState = ModeIndicatorState()
    private var modeIndicatorHost: NSHostingView<ModeIndicatorView>?
    private var appearanceObserver: NSObjectProtocol?

    init() {
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
        window.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
        window.titlebarAppearsTransparent = true

        super.init(window: window)
        window.delegate = self

        sessionManager = SessionManager(projectStore: projectStore)
        keybindingManager = KeybindingManager()
        setupUI()
        setupMCP()
        setupHookServer()
        setupCompletionActions()
        createDefaultProject()
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
                }
            )
        )
        sidebarHost.frame = NSRect(x: 0, y: 0, width: 200, height: splitFrame.height)

        // Terminal content (fills remaining width)
        terminalContentView = TerminalContentView(frame: NSRect(
            x: 0, y: 0,
            width: splitFrame.width - 201,
            height: splitFrame.height
        ))
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

    private func createDefaultProject() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let defaultSession = Session(
            name: "Shell",
            command: "/bin/zsh",
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

        refreshTerminalView()
        window?.makeFirstResponder(terminalContentView)
    }

    // MARK: - Session/Project Management

    private func setFocusedSession(_ id: UUID?) {
        terminalContentView.focusedSessionId = id
        projectStore.focusedSessionId = id
    }

    private func focusSession(_ id: UUID) {
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
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let session = Session(
            name: "Shell",
            command: "/bin/zsh",
            cwd: homeDir
        )
        let project = Project(
            name: "Project \(projectStore.projects.count + 1)",
            sessions: [session]
        )
        projectStore.addProject(project)
        projectStore.setActiveProject(id: project.id)

        do {
            try sessionManager.startSession(session)
        } catch {
            FileHandle.standardError.write("[Cosmodrome] Failed to start session: \(error)\n".data(using: .utf8)!)
        }

        refreshTerminalView()
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
                command: "/bin/zsh",
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
            command: "/bin/zsh",
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

        // Project switching
        for (i, project) in projectStore.projects.enumerated() {
            actions.append(PaletteAction(
                "Switch to \(project.name)",
                subtitle: "Project \(i + 1)",
                icon: "folder"
            ) { [weak self] in
                self?.selectProject(id: project.id)
            })
        }

        // Session switching (current project)
        if let project = projectStore.activeProject {
            for (i, session) in project.sessions.enumerated() {
                let stateStr: String
                switch session.agentState {
                case .working: stateStr = " [working]"
                case .needsInput: stateStr = " [needs input]"
                case .error: stateStr = " [error]"
                case .inactive: stateStr = ""
                }
                actions.append(PaletteAction(
                    "Focus \(session.name)\(stateStr)",
                    subtitle: "\(project.name) / Session \(i + 1)",
                    icon: session.isAgent ? "cpu" : "terminal"
                ) { [weak self] in
                    self?.focusSession(session.id)
                })
            }
        }

        // Theme toggle
        actions.append(PaletteAction(
            "Dark Mode",
            subtitle: isDarkTheme ? "Switch to light" : "Switch to dark",
            icon: isDarkTheme ? "moon.fill" : "sun.max.fill",
            isToggle: true,
            toggleState: isDarkTheme
        ) { [weak self] in
            guard let self else { return }
            self.isDarkTheme.toggle()
            self.applyTheme(self.isDarkTheme ? .dark : .light)
        })

        // New session / project
        actions.append(PaletteAction("New Session", icon: "plus.rectangle") { [weak self] in
            if let project = self?.projectStore.activeProject {
                self?.addSession(to: project)
            }
        })
        actions.append(PaletteAction("New Project", icon: "folder.badge.plus") { [weak self] in
            self?.addNewProject()
        })
        actions.append(PaletteAction("Open Project...", icon: "folder") { [weak self] in
            self?.showOpenProjectPanel()
        })

        // Framework-detected dev server actions
        if let project = projectStore.activeProject, let rootPath = project.rootPath {
            let detector = FrameworkDetector()
            let frameworks = detector.detect(in: rootPath)
            for fw in frameworks {
                actions.append(PaletteAction(
                    "Start \(fw.name)",
                    subtitle: ([fw.command] + fw.arguments).joined(separator: " "),
                    icon: "play.fill"
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

        // Git worktree actions (if current project is in a git repo)
        if let project = projectStore.activeProject, let rootPath = project.rootPath {
            if GitWorktree.isGitRepo(at: rootPath) {
                if let branch = GitWorktree.currentBranch(in: rootPath) {
                    actions.append(PaletteAction(
                        "Git: Current branch",
                        subtitle: branch,
                        icon: "arrow.triangle.branch"
                    ) {})
                }

                let worktrees = GitWorktree.list(in: rootPath)
                if worktrees.count > 1 {
                    for wt in worktrees where !wt.isMain {
                        actions.append(PaletteAction(
                            "Switch to worktree: \(wt.branch)",
                            subtitle: wt.path,
                            icon: "arrow.triangle.branch"
                        ) { [weak self] in
                            self?.switchToWorktree(wt, project: project)
                        })
                    }
                }

                actions.append(PaletteAction(
                    "Git: New worktree...",
                    subtitle: "Create branch + worktree for agent isolation",
                    icon: "plus"
                ) { [weak self] in
                    self?.createWorktree(for: project)
                })
            }
        }

        // Jump to attention
        let attentionSessions = projectStore.sessionsNeedingAttention
        for entry in attentionSessions {
            let state = entry.session.agentState == .needsInput ? "needs input" : "error"
            actions.append(PaletteAction(
                "\(entry.project.name)/\(entry.session.name) — \(state)",
                icon: "exclamationmark.triangle"
            ) { [weak self] in
                self?.jumpToSession(projectId: entry.project.id, sessionId: entry.session.id)
            })
        }

        // Recording
        if let focusedId = terminalContentView.focusedSessionId,
           let session = projectStore.activeProject?.sessions.first(where: { $0.id == focusedId }) {
            if sessionManager.isRecording(session: session) {
                actions.append(PaletteAction(
                    "Stop Recording: \(session.name)",
                    icon: "stop.circle"
                ) { [weak self] in
                    self?.sessionManager.stopRecording(session: session)
                })
            } else if session.isRunning {
                actions.append(PaletteAction(
                    "Start Recording: \(session.name)",
                    subtitle: "Save as asciicast v2 (.cast)",
                    icon: "record.circle"
                ) { [weak self] in
                    self?.sessionManager.startRecording(session: session)
                })
            }
        }

        // Layout toggle
        actions.append(PaletteAction("Toggle Focus Mode", icon: "rectangle.expand.vertical") { [weak self] in
            self?.terminalContentView.toggleFocus()
        })

        // Activity log
        actions.append(PaletteAction(
            activityLogVisible ? "Hide Activity Log" : "Show Activity Log",
            subtitle: "Cmd+L",
            icon: "list.bullet.rectangle"
        ) { [weak self] in
            self?.toggleActivityLog()
        })

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
        // Sync window chrome with theme
        window?.appearance = NSAppearance(named: theme.name == "Light" ? .aqua : .darkAqua)
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

    // MARK: - Git Worktree

    private func switchToWorktree(_ wt: GitWorktree.WorktreeInfo, project: Project) {
        // Create a new session in the worktree directory
        let session = Session(
            name: "wt/\(wt.branch)",
            command: "/bin/zsh",
            cwd: wt.path
        )
        project.sessions.append(session)
        do { try sessionManager.startSession(session) } catch {}
        setFocusedSession(session.id)
        refreshTerminalView()
    }

    private func createWorktree(for project: Project) {
        guard let rootPath = project.rootPath else { return }

        let branchName = "agent/\(UUID().uuidString.prefix(8))"
        let worktreePath = (rootPath as NSString)
            .deletingLastPathComponent
            .appending("/\((rootPath as NSString).lastPathComponent)-\(branchName.replacingOccurrences(of: "/", with: "-"))")

        if GitWorktree.create(in: rootPath, branch: branchName, path: worktreePath) {
            let session = Session(
                name: "wt/\(branchName)",
                command: "/bin/zsh",
                cwd: worktreePath
            )
            project.sessions.append(session)
            do { try sessionManager.startSession(session) } catch {}
            setFocusedSession(session.id)
            refreshTerminalView()
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
        }

        return true
    }

    // MARK: - Key Encoding

    private func encodeKeyForPTY(_ event: NSEvent) -> Data? {
        let modifiers = event.modifierFlags

        // Special keys
        switch event.keyCode {
        case 36: return Data([0x0D])   // Return
        case 48:                        // Tab
            if modifiers.contains(.shift) {
                return Data([0x1B, 0x5B, 0x5A])  // Shift+Tab → ESC [ Z (back tab)
            }
            return Data([0x09])
        case 51: return Data([0x7F])   // Backspace
        case 53: return Data([0x1B])   // Escape
        case 123: return Data([0x1B, 0x5B, 0x44]) // Left
        case 124: return Data([0x1B, 0x5B, 0x43]) // Right
        case 125: return Data([0x1B, 0x5B, 0x42]) // Down
        case 126: return Data([0x1B, 0x5B, 0x41]) // Up
        case 116: return Data([0x1B, 0x5B, 0x35, 0x7E]) // Page Up
        case 121: return Data([0x1B, 0x5B, 0x36, 0x7E]) // Page Down
        case 115: return Data([0x1B, 0x5B, 0x48]) // Home
        case 119: return Data([0x1B, 0x5B, 0x46]) // End
        case 117: return Data([0x1B, 0x5B, 0x33, 0x7E]) // Delete forward
        default: break
        }

        // Ctrl+key
        if modifiers.contains(.control), let chars = event.charactersIgnoringModifiers {
            if let scalar = chars.unicodeScalars.first {
                let value = scalar.value
                if value >= 0x61 && value <= 0x7A {
                    return Data([UInt8(value - 0x60)])
                }
            }
        }

        // Regular character input
        if let chars = event.characters, let data = chars.data(using: .utf8) {
            return data
        }

        return nil
    }

    // MARK: - Activity Log

    private func toggleActivityLog() {
        activityLogVisible.toggle()

        if activityLogVisible {
            showActivityLogPanel()
        } else {
            hideActivityLogPanel()
        }
    }

    private func showActivityLogPanel() {
        guard let window, let containerView = window.contentView else { return }

        // Remove existing overlay if any
        activityLogOverlay?.removeFromSuperview()

        guard let project = projectStore.activeProject else { return }

        let logView = ActivityLogView(
            activityLog: project.activityLog,
            projectName: project.name,
            onDismiss: { [weak self] in
                self?.hideActivityLogPanel()
                self?.activityLogVisible = false
            }
        )

        let host = NSHostingView(rootView: AnyView(logView))
        let panelWidth: CGFloat = 320
        host.frame = NSRect(
            x: containerView.bounds.width - panelWidth,
            y: 28, // above status bar
            width: panelWidth,
            height: containerView.bounds.height - 28
        )
        host.autoresizingMask = [.height, .minXMargin]
        containerView.addSubview(host)
        activityLogOverlay = host
    }

    private func hideActivityLogPanel() {
        activityLogOverlay?.removeFromSuperview()
        activityLogOverlay = nil
    }

    // MARK: - Completion Actions

    private func setupCompletionActions() {
        sessionManager.onTaskCompleted = { [weak self] session, filesChanged, duration in
            self?.showCompletionBar(session: session, filesChanged: filesChanged, duration: duration)
        }
    }

    private func showCompletionBar(session: Session, filesChanged: [String], duration: TimeInterval) {
        guard let containerView = window?.contentView else { return }

        // Remove existing bar
        completionBarHost?.removeFromSuperview()

        let actions = CompletionActions.suggest(
            filesChanged: filesChanged,
            taskDuration: duration,
            hasTestCommand: false // TODO: read from project config when available
        )

        guard !actions.isEmpty else { return }

        let barView = CompletionSuggestionBar(
            actions: actions,
            duration: duration,
            filesCount: filesChanged.count,
            onAction: { [weak self] actionId in
                self?.handleCompletionAction(actionId, session: session, filesChanged: filesChanged)
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
                command: "/bin/zsh",
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
                command: "/bin/zsh",
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
            guard let kind = event.toEventKind() else { return }
            let sessionId = event.sessionId

            DispatchQueue.main.async {
                if let sid = sessionId {
                    for project in self.projectStore.projects {
                        if let session = project.sessions.first(where: { $0.id == sid }) {
                            project.activityLog.append(ActivityEvent(
                                timestamp: event.timestamp,
                                sessionId: session.id,
                                sessionName: session.name,
                                kind: kind
                            ))
                            return
                        }
                    }
                }
                // Fallback: append to active project
                if let project = self.projectStore.activeProject {
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

    // MARK: - State Persistence

    func saveState() {
        StatePersistence.save(
            window: window,
            projectStore: projectStore
        )
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        saveState()
        for project in projectStore.projects {
            for session in project.sessions {
                sessionManager.stopSession(session)
            }
        }
    }
}
