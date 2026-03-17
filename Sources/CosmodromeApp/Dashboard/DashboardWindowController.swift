import AppKit
import Core
import SwiftUI

/// Window controller for dashboard mode.
/// No terminal rendering — just manages Ghostty sessions via shell integration.
final class DashboardWindowController: NSWindowController, NSWindowDelegate {
    let registry = DashboardRegistry()
    private let server = DashboardServer()
    private let bridge = GhosttyBridge()
    private var pruneTimer: Timer?

    init(dashboard: Bool) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cosmodrome Dashboard"
        window.center()
        window.minSize = NSSize(width: 600, height: 400)
        window.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)

        super.init(window: window)
        window.delegate = self

        setupDashboardUI()
        startServer()
        startPruneTimer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    // MARK: - Setup

    private func setupDashboardUI() {
        guard let window else { return }

        let dashboardView = DashboardView(
            registry: registry,
            onFocusSession: { [weak self] session in
                self?.focusGhosttySession(session)
            },
            onRenameProject: { project, newName in
                project.name = newName
            }
        )

        let hostingView = NSHostingView(rootView: dashboardView)
        hostingView.frame = window.contentLayoutRect
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
    }

    private func startServer() {
        let socketPath = server.start()

        // Print socket path so users can export it
        FileHandle.standardError.write(
            Data("[Cosmodrome] Dashboard socket: \(socketPath)\n".utf8)
        )
        // Also print to stdout for easy capture
        print("COSMODROME_DASHBOARD_SOCKET=\(socketPath)")

        server.onEvent = { [weak self] event in
            guard let self else { return }
            DispatchQueue.main.async {
                self.handleDashboardEvent(event)
            }
        }

        server.onHookEvent = { [weak self] hookEvent in
            guard let self else { return }
            DispatchQueue.main.async {
                self.handleHookEvent(hookEvent)
            }
        }
    }

    private func startPruneTimer() {
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.registry.pruneDeadSessions()
        }
    }

    // MARK: - Event Handling

    private func handleDashboardEvent(_ event: DashboardEvent) {
        switch event {
        case .registerSession(let sessionId, let pid, let windowId, let cwd, let label):
            registry.registerSession(
                sessionId: sessionId,
                pid: pid,
                windowId: windowId,
                cwd: cwd,
                label: label
            )

        case .unregisterSession(let pid):
            registry.unregisterSession(pid: pid)

        case .heartbeat(let pid, let cwd):
            registry.heartbeat(pid: pid)
            // Update cwd if changed
            if let newCwd = cwd {
                for project in registry.projects {
                    if let session = project.sessions.first(where: { $0.pid == pid }) {
                        if session.cwd != newCwd {
                            session.cwd = newCwd
                            session.label = (newCwd as NSString).lastPathComponent
                        }
                        break
                    }
                }
            }

        case .agentStarted(let pid, let agentType):
            for project in registry.projects {
                if let session = project.sessions.first(where: { $0.pid == pid }) {
                    session.isAgent = true
                    session.agentType = agentType
                    session.agentState = .working
                    break
                }
            }

        case .agentStateChanged(let pid, let state, let model):
            let agentState: AgentState
            switch state {
            case "working": agentState = .working
            case "needsInput", "needs_input": agentState = .needsInput
            case "error": agentState = .error
            default: agentState = .inactive
            }
            for project in registry.projects {
                if let session = project.sessions.first(where: { $0.pid == pid }) {
                    session.agentState = agentState
                    session.agentModel = model
                    break
                }
            }

        case .agentStopped(let pid):
            for project in registry.projects {
                if let session = project.sessions.first(where: { $0.pid == pid }) {
                    session.agentState = .inactive
                    session.isAgent = false
                    break
                }
            }
        }
    }

    private func handleHookEvent(_ hookEvent: HookEvent) {
        // Claude Code hook events include a session ID — find the matching session
        guard let sessionId = hookEvent.sessionId else { return }

        for project in registry.projects {
            if let session = project.sessions.first(where: { $0.id == sessionId }) {
                session.isAgent = true
                session.agentType = session.agentType ?? "claude"

                switch hookEvent.hookName {
                case "PreToolUse":
                    session.agentState = .working
                case "PostToolUse":
                    // Still working unless stopped
                    break
                case "Notification":
                    session.agentState = .needsInput
                case "Stop":
                    session.agentState = .inactive
                default:
                    break
                }

                // Log to project activity
                if let kind = hookEvent.toEventKind() {
                    project.activityLog.append(ActivityEvent(
                        timestamp: hookEvent.timestamp,
                        sessionId: sessionId,
                        sessionName: session.label,
                        kind: kind
                    ))
                }
                break
            }
        }
    }

    // MARK: - Ghostty Focus

    private func focusGhosttySession(_ session: GhosttySession) {
        bridge.focusWindow(windowId: session.windowId)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        server.stop()
        pruneTimer?.invalidate()
    }
}
