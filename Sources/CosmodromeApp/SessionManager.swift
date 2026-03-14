import AppKit
import Core
import Foundation

/// Manages the lifecycle of terminal sessions: spawning PTY processes,
/// connecting them to backends and the multiplexer, handling exits.
final class SessionManager {
    let multiplexer: PTYMultiplexer
    let projectStore: ProjectStore
    let portDetector = PortDetector()
    private var onSessionDirty: (() -> Void)?
    private var lastStatusParse: [UUID: Date] = [:]
    private var lastPromptScan: [UUID: Date] = [:]
    /// Called on main thread when the session list changes structurally (exit, restart).
    var onSessionListChanged: (() -> Void)?
    private var recorders: [UUID: AsciicastRecorder] = [:]
    /// Detectors stored by session ID — accessible for hook event forwarding.
    private(set) var detectors: [UUID: AgentDetector] = [:]
    /// Throttle for runtime agent detection in shell sessions.
    private var lastAgentCheck: [UUID: Date] = [:]
    /// Tracks when a session was upgraded to agent (for adaptive throttle).
    private var agentUpgradeTime: [UUID: Date] = [:]
    /// Throttle for agent downgrade checks.
    private var lastDowngradeCheck: [UUID: Date] = [:]
    /// Throttle for git branch detection.
    private var lastBranchCheck: [UUID: Date] = [:]
    /// Throttle for buffer-based state scanning.
    private var lastStateScan: [UUID: Date] = [:]
    /// Throttle for narrative updates.
    private var lastNarrativeUpdate: [UUID: Date] = [:]
    /// Lock for dicts accessed from both I/O and main threads.
    private let stateLock = NSLock()

    /// Socket path for the hook server — injected into spawned sessions' environment.
    var hookSocketPath: String?

    /// Called on main thread when an agent completes a task (working → not working).
    /// Parameters: session, completionContext
    var onTaskCompleted: ((Session, CompletionActions.CompletionContext) -> Void)?

    /// Called on main thread when a terminal notification (OSC 777) is received.
    var onTerminalNotification: ((Session, TerminalNotification) -> Void)?

    init(projectStore: ProjectStore) {
        self.projectStore = projectStore
        self.multiplexer = PTYMultiplexer()
        setupPortDetector()
    }

    private func setupPortDetector() {
        portDetector.onPortsChanged = { [weak self] sessionId, ports in
            DispatchQueue.main.async {
                guard let self else { return }
                for project in self.projectStore.projects {
                    if let session = project.sessions.first(where: { $0.id == sessionId }) {
                        session.detectedPorts = ports
                        break
                    }
                }
            }
        }
        portDetector.start()
    }

    /// Set callback for when any session has new output (triggers redraw).
    func setDirtyHandler(_ handler: @escaping () -> Void) {
        self.onSessionDirty = handler
    }

    /// Start a session: spawn PTY, create backend, register with multiplexer.
    func startSession(_ session: Session) throws {
        guard !session.isRunning else { return }

        let cols: UInt16 = 80
        let rows: UInt16 = 24

        // Resolve relative CWD to absolute path at spawn time
        if session.cwd == "." {
            session.cwd = FileManager.default.currentDirectoryPath
        }
        let cwd = session.cwd

        // Inject hook server env vars so CosmodromeHook can reach us
        var env = session.environment
        if let socketPath = hookSocketPath {
            env["COSMODROME_HOOK_SOCKET"] = socketPath
        }
        env["COSMODROME_SESSION_ID"] = session.id.uuidString

        let result = try spawnPTY(
            command: session.command,
            arguments: session.arguments,
            environment: env,
            cwd: cwd,
            size: (cols: cols, rows: rows)
        )

        let backend = SwiftTermBackend(cols: Int(cols), rows: Int(rows))

        // Wire up command completion tracking (OSC 133)
        let sid = session.id
        let sname = session.name
        backend.commandTracker?.onCommandCompleted = { [weak self] command, exitCode, duration in
            guard let self else { return }
            DispatchQueue.main.async {
                if let project = self.findProject(for: session) {
                    project.activityLog.append(ActivityEvent(
                        timestamp: Date(),
                        sessionId: sid,
                        sessionName: sname,
                        kind: .commandCompleted(command: command, exitCode: exitCode, duration: duration)
                    ))
                }
            }
        }

        // Wire up OSC 777 notification handler
        backend.onNotification = { [weak self] notification in
            DispatchQueue.main.async {
                session.hasUnreadNotification = true
                session.lastNotification = notification
                self?.onTerminalNotification?(session, notification)
            }
        }

        // Create detector: explicit agent flag, or auto-detect from command name
        let detector: AgentDetector?
        if session.isAgent {
            session.agentSince = session.agentSince ?? Date()
            detector = AgentDetector(
                agentType: session.agentType ?? "claude",
                sessionId: session.id,
                sessionName: session.name
            )
        } else if let detectedType = AgentPatterns.detectType(from: session.command) {
            session.isAgent = true
            session.agentType = detectedType
            session.agentSince = Date()
            detector = AgentDetector(
                agentType: detectedType,
                sessionId: session.id,
                sessionName: session.name
            )
        } else {
            detector = nil
        }

        if let detector {
            detector.stats = session.stats
            stateLock.lock()
            detectors[session.id] = detector
            agentUpgradeTime[session.id] = Date()
            stateLock.unlock()
        }

        session.backend = backend
        session.ptyFD = result.fd
        session.pid = result.pid
        session.isRunning = true
        session.exitedUnexpectedly = false
        session.taskStartedAt = nil
        session.filesChangedInTask = []

        let onDirty = onSessionDirty ?? {}
        let sessionId = session.id

        let io = PTYMultiplexer.SessionIO(
            id: sessionId,
            backend: backend,
            agentDetector: detector,
            onOutput: { [weak self] in
                // Check detector from dict (may be added at runtime via upgrade)
                self?.stateLock.lock()
                let detector = self?.detectors[sessionId]
                self?.stateLock.unlock()
                if let detector {
                    let newState = detector.state
                    let oldState = session.agentState
                    let model = detector.modelDetector.currentModel
                    let events = detector.consumeEvents()

                    DispatchQueue.main.async {
                        session.agentState = newState
                        if model != session.agentModel { session.agentModel = model }

                        // Read buffer ONCE and run all scans against the snapshot.
                        // Single lock acquisition, single yDisp snap/restore — prevents scroll jitter.
                        self?.runBufferScans(session: session, backend: backend)
                        // Detect git branch (throttled, 5s)
                        self?.updateGitBranch(session: session)

                        // Capture final state after all overrides for transition tracking
                        let finalState = session.agentState

                        // Append events to project's activity log
                        if let project = self?.findProject(for: session) {
                            project.activityLog.append(contentsOf: events)
                        }

                        // Track files changed during task
                        for event in events {
                            if case .fileWrite(let path, _, _) = event.kind {
                                if session.agentState == .working {
                                    session.filesChangedInTask.append(path)
                                }
                            }
                        }

                        // Handle state transitions (use finalState which includes buffer overrides)
                        if finalState != oldState {
                            // Starting a new task
                            if finalState == .working && oldState != .working {
                                session.taskStartedAt = Date()
                                session.filesChangedInTask = []
                            }

                            // Task completed (was working, now not)
                            if oldState == .working && finalState != .working {
                                let duration = session.taskStartedAt
                                    .map { Date().timeIntervalSince($0) } ?? 0
                                let files = session.filesChangedInTask

                                // Log completion event
                                if let project = self?.findProject(for: session) {
                                    project.activityLog.append(ActivityEvent(
                                        timestamp: Date(),
                                        sessionId: session.id,
                                        sessionName: session.name,
                                        kind: .taskCompleted(duration: duration)
                                    ))
                                }

                                // Trigger completion actions
                                let events: [ActivityEvent]
                                if let project = self?.findProject(for: session) {
                                    events = project.activityLog.events(for: session.id)
                                } else {
                                    events = []
                                }
                                let ctx = CompletionActions.CompletionContext(
                                    filesChanged: files,
                                    taskDuration: duration,
                                    hasTestCommand: false,
                                    stats: session.stats,
                                    events: events,
                                    narrative: session.narrative,
                                    stuckInfo: session.stuckInfo
                                )
                                self?.onTaskCompleted?(session, ctx)
                            }

                            // Mark session as needing attention + send macOS notification
                            if finalState == .needsInput || finalState == .error
                                || (finalState == .inactive && oldState == .working) {
                                session.hasUnreadNotification = true
                            }
                            if let project = self?.findProject(for: session) {
                                AgentNotifications.notifyAgentState(project: project, session: session)
                            }
                        }

                        // Update narrative summary (throttled — every 2s)
                        self?.updateNarrative(session: session)
                    }
                } else {
                    // No detector yet — check if an agent started in this shell session
                    self?.checkForAgentStartup(session: session, backend: backend)
                    // Detect git branch for plain shell sessions too
                    DispatchQueue.main.async {
                        self?.updateGitBranch(session: session)
                    }
                }
                DispatchQueue.main.async {
                    onDirty()
                }
            },
            onExit: { [weak self] in
                self?.handleSessionExit(session)
            },
            onRawOutput: { [weak self] bytes in
                self?.stateLock.lock()
                let recorder = self?.recorders[sessionId]
                self?.stateLock.unlock()
                recorder?.recordOutput(bytes)
            }
        )

        multiplexer.register(fd: result.fd, session: io)
        portDetector.track(sessionId: session.id, pid: result.pid)

        // Log session start
        if let project = findProject(for: session) {
            project.activityLog.append(ActivityEvent(
                timestamp: Date(),
                sessionId: session.id,
                sessionName: session.name,
                kind: .taskStarted
            ))
        }

        // Inject minimal shell integration for OSC 133 (command tracking)
        injectShellIntegration(session: session, fd: result.fd)
    }

    /// Send a tiny shell snippet that enables OSC 133 semantic prompts.
    /// This lets CommandTracker log shell commands in the activity log.
    private func injectShellIntegration(session: Session, fd: Int32) {
        // Only inject for interactive shells
        let shell = (session.command as NSString).lastPathComponent
        guard ["zsh", "bash", "fish"].contains(shell) else { return }

        let snippet: String
        switch shell {
        case "zsh":
            // precmd: emit D;exitcode then A (prompt start)
            // preexec: emit B (command start)
            snippet = [
                "__cosmo_precmd() { local ec=$?; printf '\\e]133;D;%d\\a\\e]133;A\\a' \"$ec\"; }",
                "__cosmo_preexec() { printf '\\e]133;B\\a'; }",
                "precmd_functions+=(__cosmo_precmd)",
                "preexec_functions+=(__cosmo_preexec)",
                "clear",
                "",
            ].joined(separator: "\n")
        case "bash":
            snippet = [
                "__cosmo_prompt() { local ec=$?; printf '\\e]133;D;%d\\a\\e]133;A\\a' \"$ec\"; }",
                "trap 'printf \"\\e]133;B\\a\"' DEBUG",
                "PROMPT_COMMAND=\"__cosmo_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}\"",
                "clear",
                "",
            ].joined(separator: "\n")
        case "fish":
            snippet = [
                "function __cosmo_prompt --on-event fish_prompt; printf '\\e]133;A\\a'; end",
                "function __cosmo_preexec --on-event fish_preexec; printf '\\e]133;B\\a'; end",
                "function __cosmo_postexec --on-event fish_postexec; printf '\\e]133;D;%d\\a' $status; end",
                "clear",
                "",
            ].joined(separator: "\n")
        default:
            return
        }

        if let data = snippet.data(using: .utf8) {
            // Small delay so the shell has time to initialize
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.multiplexer.send(to: fd, data: data)
            }
        }
    }

    /// Stop a session: kill the process, clean up.
    func stopSession(_ session: Session) {
        guard session.isRunning else { return }

        portDetector.untrack(sessionId: session.id)

        let pid = session.pid
        let fd = session.ptyFD

        if pid > 0 {
            kill(pid, SIGTERM)
        }
        if fd >= 0 {
            multiplexer.unregister(fd: fd)
            close(fd)
        }
        // Reap child process to prevent zombie
        if pid > 0 {
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
        }

        session.isRunning = false
        session.ptyFD = -1
        session.pid = 0
        session.backend = nil
        session.agentState = .inactive
        session.agentModel = nil
        session.agentContext = nil
        session.agentMode = nil
        session.agentEffort = nil
        session.agentCost = nil
        session.taskStartedAt = nil
        session.filesChangedInTask = []
        session.detectedPorts = []
        session.gitBranch = nil
        stateLock.lock()
        defer { stateLock.unlock() }
        lastStatusParse.removeValue(forKey: session.id)
        lastPromptScan.removeValue(forKey: session.id)
        lastStateScan.removeValue(forKey: session.id)
        detectors.removeValue(forKey: session.id)
        lastAgentCheck.removeValue(forKey: session.id)
        lastBranchCheck.removeValue(forKey: session.id)
        agentUpgradeTime.removeValue(forKey: session.id)
    }

    /// Start all auto-start sessions in a project.
    func startAutoStartSessions(for project: Project) {
        for session in project.sessions where session.autoStart {
            do {
                try startSession(session)
            } catch {
                FileHandle.standardError.write("[Cosmodrome] Failed to start session '\(session.name)': \(error)\n".data(using: .utf8)!)
            }
        }
    }

    /// Write data to a session's PTY.
    func write(to session: Session, data: Data) {
        guard session.ptyFD >= 0 else { return }
        multiplexer.send(to: session.ptyFD, data: data)
    }

    // MARK: - Recording

    /// Start recording a session's output in asciicast v2 format.
    func startRecording(session: Session) {
        stateLock.lock()
        let alreadyRecording = recorders[session.id] != nil
        stateLock.unlock()
        guard !alreadyRecording else { return }

        let backend = session.backend
        let width = backend?.cols ?? 80
        let height = backend?.rows ?? 24

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path
            ?? NSTemporaryDirectory()
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let path = "\(dir)/cosmodrome-\(session.name)-\(timestamp).cast"

        do {
            let recorder = try AsciicastRecorder(
                path: path, width: width, height: height, title: session.name
            )
            stateLock.lock()
            recorders[session.id] = recorder
            stateLock.unlock()
        } catch {
            FileHandle.standardError.write("[Cosmodrome] Failed to start recording: \(error)\n".data(using: .utf8)!)
        }
    }

    /// Stop recording a session.
    func stopRecording(session: Session) {
        stateLock.lock()
        let recorder = recorders.removeValue(forKey: session.id)
        stateLock.unlock()
        recorder?.close()
    }

    /// Check if a session is being recorded.
    func isRecording(session: Session) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recorders[session.id] != nil
    }

    // MARK: - Runtime Agent Detection

    /// Check if an agent has started in a shell session (called from I/O thread via onOutput).
    /// Throttled to every 2 seconds to avoid overhead.
    private func checkForAgentStartup(session: Session, backend: TerminalBackend) {
        stateLock.lock()
        // Already upgraded — skip
        if detectors[session.id] != nil {
            stateLock.unlock()
            return
        }
        let now = Date()
        if let last = lastAgentCheck[session.id], now.timeIntervalSince(last) < 2.0 {
            stateLock.unlock()
            return
        }
        lastAgentCheck[session.id] = now
        stateLock.unlock()

        // Read bottom half of the terminal buffer (12 rows).
        // Claude Code's TUI fills the entire screen; 5 rows was too narrow.
        backend.lock()
        let rows = backend.rows
        let cols = backend.cols
        let scanRows = min(rows, 12)
        var text = ""
        for row in max(0, rows - scanRows)..<rows {
            for col in 0..<cols {
                let cell = backend.cell(row: row, col: col)
                let cp = cell.codepoint
                if cp >= 32 && cp < 0x110000 {
                    text.append(Character(Unicode.Scalar(cp)!))
                } else {
                    text.append(" ")
                }
            }
            text.append("\n")
        }
        backend.unlock()

        Self.debugLog("checkForAgentStartup: session=\(session.name) scanning \(scanRows) rows, text=\(text.prefix(300))")

        // Detect agent startup signatures.
        // Spinner chars alone are NOT sufficient — many CLI tools (npm, cargo, pip) use them.
        // Require spinner + a secondary Claude Code signal to avoid false upgrades.
        let agentType: String?
        if text.range(of: #"[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]"#, options: .regularExpression) != nil {
            let hasSecondarySignal =
                text.range(of: #"(?i)ctx:\s*\d+"#, options: .regularExpression) != nil
                || text.range(of: #"(?i)\b(opus|sonnet|haiku)\s+\d"#, options: .regularExpression) != nil
                || text.range(of: #"shift\+tab"#, options: [.regularExpression, .caseInsensitive]) != nil
                || text.range(of: #"(?i)\bclaude\s+code\b"#, options: .regularExpression) != nil
            agentType = hasSecondarySignal ? "claude" : nil
        } else if text.range(of: #"(?i)ctx:\s*\d+"#, options: .regularExpression) != nil
            || text.range(of: #"(?i)\b(opus|sonnet|haiku)\s+\d"#, options: .regularExpression) != nil
            || text.range(of: #"shift\+tab"#, options: [.regularExpression, .caseInsensitive]) != nil {
            // Claude Code status bar detected (visible when idle too)
            agentType = "claude"
        } else if text.range(of: #"(?i)\bclaude\s+code\b"#, options: .regularExpression) != nil
            || text.range(of: #"(?i)\bwelcome\s+to\s+claude\b"#, options: .regularExpression) != nil {
            // Claude Code welcome/startup screen
            agentType = "claude"
        } else if text.range(of: #"(?i)\baider\s*>"#, options: .regularExpression) != nil
            || text.range(of: #"(?i)\baider\s+v\d"#, options: .regularExpression) != nil {
            agentType = "aider"
        } else if text.range(of: #"(?i)\bcodex\s*>"#, options: .regularExpression) != nil {
            agentType = "codex"
        } else if text.range(of: #"(?i)\bgemini\s*>"#, options: .regularExpression) != nil {
            agentType = "gemini"
        } else {
            agentType = nil
        }

        if let agentType {
            Self.debugLog("checkForAgentStartup: detected \(agentType) for session=\(session.name)")
            DispatchQueue.main.async { [weak self] in
                self?.upgradeToAgentSession(session: session, agentType: agentType)
            }
        }
    }

    /// Upgrade a shell session to an agent session: create detector, re-register with multiplexer.
    func upgradeToAgentSession(session: Session, agentType: String) {
        guard !session.isAgent else { return }
        guard session.ptyFD >= 0, let backend = session.backend else { return }

        Self.debugLog("upgradeToAgentSession: session=\(session.name) type=\(agentType)")
        session.isAgent = true
        session.agentType = agentType
        session.agentSince = Date()

        let detector = AgentDetector(
            agentType: agentType,
            sessionId: session.id,
            sessionName: session.name
        )
        detector.stats = session.stats
        stateLock.lock()
        detectors[session.id] = detector
        agentUpgradeTime[session.id] = Date()
        stateLock.unlock()

        // Re-register with multiplexer to include the detector for inline analysis
        let sessionId = session.id
        let onDirty = onSessionDirty ?? {}

        let io = PTYMultiplexer.SessionIO(
            id: sessionId,
            backend: backend,
            agentDetector: detector,
            onOutput: { [weak self] in
                self?.stateLock.lock()
                let detector = self?.detectors[sessionId]
                self?.stateLock.unlock()
                if let detector {
                    let newState = detector.state
                    let oldState = session.agentState
                    let model = detector.modelDetector.currentModel
                    let events = detector.consumeEvents()

                    DispatchQueue.main.async {
                        session.agentState = newState
                        if model != session.agentModel { session.agentModel = model }
                        self?.updateStatusLine(session: session, backend: backend)
                        self?.scanForAgentStateIfNeeded(session: session, backend: backend)
                        self?.scanForPromptIfNeeded(session: session, backend: backend)
                        self?.updateGitBranch(session: session)

                        let finalState = session.agentState

                        if let project = self?.findProject(for: session) {
                            project.activityLog.append(contentsOf: events)
                        }

                        for event in events {
                            if case .fileWrite(let path, _, _) = event.kind {
                                if session.agentState == .working {
                                    session.filesChangedInTask.append(path)
                                }
                            }
                        }

                        if finalState != oldState {
                            if finalState == .working && oldState != .working {
                                session.taskStartedAt = Date()
                                session.filesChangedInTask = []
                            }
                            if oldState == .working && finalState != .working {
                                let duration = session.taskStartedAt
                                    .map { Date().timeIntervalSince($0) } ?? 0
                                let files = session.filesChangedInTask
                                if let project = self?.findProject(for: session) {
                                    project.activityLog.append(ActivityEvent(
                                        timestamp: Date(),
                                        sessionId: session.id,
                                        sessionName: session.name,
                                        kind: .taskCompleted(duration: duration)
                                    ))
                                }
                                let events2: [ActivityEvent]
                                if let project = self?.findProject(for: session) {
                                    events2 = project.activityLog.events(for: session.id)
                                } else {
                                    events2 = []
                                }
                                let ctx = CompletionActions.CompletionContext(
                                    filesChanged: files,
                                    taskDuration: duration,
                                    hasTestCommand: false,
                                    stats: session.stats,
                                    events: events2,
                                    narrative: session.narrative,
                                    stuckInfo: session.stuckInfo
                                )
                                self?.onTaskCompleted?(session, ctx)
                            }
                            if let project = self?.findProject(for: session) {
                                AgentNotifications.notifyAgentState(project: project, session: session)
                            }
                        }
                    }
                }
                DispatchQueue.main.async {
                    onDirty()
                }
            },
            onExit: { [weak self] in
                self?.handleSessionExit(session)
            },
            onRawOutput: { [weak self] bytes in
                self?.stateLock.lock()
                let recorder = self?.recorders[sessionId]
                self?.stateLock.unlock()
                recorder?.recordOutput(bytes)
            }
        )

        multiplexer.updateSession(fd: session.ptyFD, session: io)
    }

    /// Check if an agent has exited and the session returned to a plain shell (legacy path).
    /// The consolidated runBufferScans() path is preferred — it reads the buffer once.
    private func checkForAgentExit(session: Session, backend: TerminalBackend) {
        let rows = backend.readRowsAtBottom(count: backend.rows)
        checkForAgentExitFromSnapshot(session: session, rows: rows)
    }

    /// Downgrade a session from agent back to plain shell.
    private func downgradeFromAgent(session: Session) {
        guard session.isAgent else { return }
        session.isAgent = false
        session.agentType = nil
        session.agentState = .inactive
        session.agentModel = nil
        stateLock.lock()
        detectors.removeValue(forKey: session.id)
        stateLock.unlock()
        agentUpgradeTime.removeValue(forKey: session.id)
        lastDowngradeCheck.removeValue(forKey: session.id)
        lastStateScan.removeValue(forKey: session.id)
    }

    // MARK: - Status Line Parsing

    private static let debugStatus = ProcessInfo.processInfo.environment["COSMODROME_DEBUG_STATUS"] != nil
        || ProcessInfo.processInfo.environment["COSMODROME_DEBUG_STATE"] != nil

    private static func debugLog(_ message: @autoclosure () -> String) {
        if debugStatus {
            FileHandle.standardError.write("[SessionManager] \(message())\n".data(using: .utf8)!)
        }
    }

    /// Parse Claude Code's status bar from the terminal buffer (legacy path).
    /// The consolidated runBufferScans() path is preferred — it reads the buffer once.
    private func updateStatusLine(session: Session, backend: TerminalBackend) {
        let rows = backend.readRowsAtBottom(count: 6)
        updateStatusLineFromSnapshot(session: session, rows: rows)
    }

    struct StatusLineInfo {
        var context: String?
        var mode: String?
        var effort: String?
        var cost: String?
        var model: String?
    }

    /// Read the bottom rows of the terminal buffer and extract status bar info.
    /// Prefer parseStatusLine(from rowStrings:) with pre-read rows to avoid per-cell yDisp mutations.
    static func parseStatusLine(from backend: TerminalBackend) -> StatusLineInfo {
        let rowStrings = backend.readRowsAtBottom(count: 6)
        return parseStatusLine(from: rowStrings)
    }

    /// Parse status bar info from pre-read row strings.
    /// Claude Code's status line format (2 lines at bottom):
    ///   Line 1: user@host  /path  Opus 4.6 | ctx: 89%   ● high · /effort
    ///   Line 2: ⏸ plan mode on (shift+tab to cycle)
    static func parseStatusLine(from rowStrings: [String]) -> StatusLineInfo {
        debugLog("Bottom \(rowStrings.count) rows: \(rowStrings.enumerated().map { "[\($0)]: \($1)" }.joined(separator: " | "))")

        var info = StatusLineInfo()

        // Classify rows: find the "info row" (ctx: or model) and "mode row" (mode on/off)
        var infoRow: String?
        var modeRow: String?

        for row in rowStrings {
            if row.range(of: #"(?i)ctx:\s*\d+"#, options: .regularExpression) != nil
                || row.range(of: #"(?i)\b(opus|sonnet|haiku)\s+\d"#, options: .regularExpression) != nil {
                infoRow = row
            }
            if row.range(of: #"(?i)mode\s+(on|off)\b"#, options: .regularExpression) != nil
                || row.range(of: #"shift\+tab"#, options: [.regularExpression, .caseInsensitive]) != nil {
                modeRow = row
            }
        }

        debugLog("infoRow: \(infoRow ?? "nil") | modeRow: \(modeRow ?? "nil")")

        // Extract from info row (or fallback to all rows)
        let infoText = infoRow ?? rowStrings.joined(separator: " ")

        // Context: "ctx: 89%" or "ctx:45%"
        if let range = infoText.range(of: #"(?i)ctx:\s*(\d+%)"#, options: .regularExpression) {
            let match = String(infoText[range])
            // Extract just the percentage part
            if let pctRange = match.range(of: #"\d+%"#, options: .regularExpression) {
                info.context = String(match[pctRange])
            }
        }
        // Fallback: "45k/200k" format
        if info.context == nil,
           let range = infoText.range(of: #"\d+\.?\d*[kK]\s*/\s*\d+\.?\d*[kK]"#, options: .regularExpression) {
            info.context = String(infoText[range]).replacingOccurrences(of: " ", with: "")
        }

        // Model: "Opus 4.6", "Sonnet 4.6", "Haiku 4.5"
        if let range = infoText.range(of: #"(?i)\b(opus|sonnet|haiku)\s+\d+(?:\.\d+)?"#, options: .regularExpression) {
            info.model = String(infoText[range])
        }
        // Fallback: API name "claude-opus-4-6"
        if info.model == nil,
           let range = infoText.range(of: #"\bclaude-\S+"#, options: .regularExpression) {
            info.model = String(infoText[range])
        }

        // Effort: "high", "medium", "low", "max" — search info row only
        let effortPatterns: [(pattern: String, label: String)] = [
            (#"\bmax\b"#, "max"),
            (#"\bhigh\b"#, "high"),
            (#"\bmedium\b"#, "medium"),
            (#"\blow\b"#, "low"),
        ]
        for (pattern, label) in effortPatterns {
            if infoText.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                info.effort = label
                break
            }
        }

        // Cost: "$0.23" or "$12.45"
        if let range = infoText.range(of: #"\$\d+\.\d+"#, options: .regularExpression) {
            info.cost = String(infoText[range])
        }

        // Mode: extract from mode row (or fallback to all rows)
        let modeText = modeRow ?? rowStrings.joined(separator: " ")

        // Match confirmed Claude Code formats: "plan mode on", "accept edits on", "bypass permissions on", "auto mode on"
        let modePatterns: [(pattern: String, label: String)] = [
            (#"(?i)\bbypass\s+permissions?"#, "Bypass"),
            (#"(?i)\bauto\s+mode"#, "Auto"),
            (#"(?i)\bplan\s+mode"#, "Plan"),
            (#"(?i)\baccept\s+edits?"#, "Accept Edits"),
        ]
        for (pattern, label) in modePatterns {
            if modeText.range(of: pattern, options: .regularExpression) != nil {
                info.mode = label
                break
            }
        }

        debugLog("Result: ctx=\(info.context ?? "nil") model=\(info.model ?? "nil") mode=\(info.mode ?? "nil") effort=\(info.effort ?? "nil") cost=\(info.cost ?? "nil")")

        return info
    }

    /// Parse a cost string like "$0.34" or "$12.50" into a Double.
    static func parseCostValue(_ costStr: String) -> Double? {
        let cleaned = costStr.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        return Double(cleaned)
    }

    // MARK: - Git Branch Detection

    /// Detect the current git branch for a session's working directory.
    /// Throttled to every 5 seconds — branch changes are infrequent.
    private func updateGitBranch(session: Session) {
        let now = Date()
        stateLock.lock()
        if let last = lastBranchCheck[session.id], now.timeIntervalSince(last) < 5.0 {
            stateLock.unlock()
            return
        }
        lastBranchCheck[session.id] = now
        stateLock.unlock()

        // CWD should already be resolved to absolute in startSession(), but guard against "."
        let cwd = session.cwd == "." ? FileManager.default.currentDirectoryPath : session.cwd

        DispatchQueue.global(qos: .utility).async {
            let branch = Self.detectGitBranch(in: cwd)
            DispatchQueue.main.async {
                if branch != session.gitBranch {
                    session.gitBranch = branch
                }
            }
        }
    }

    /// Run `git rev-parse --abbrev-ref HEAD` in the given directory.
    static func detectGitBranch(in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--abbrev-ref", "HEAD"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = ["GIT_TERMINAL_PROMPT": "0"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let branch = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    // MARK: - Narrative Updates

    /// Update the session narrative summary. Throttled to every 2 seconds.
    private func updateNarrative(session: Session) {
        guard session.isAgent else { return }
        let now = Date()
        if let last = lastNarrativeUpdate[session.id], now.timeIntervalSince(last) < 2.0 {
            return
        }
        lastNarrativeUpdate[session.id] = now

        let events: [ActivityEvent]
        if let project = findProject(for: session) {
            events = project.activityLog.events(for: session.id)
        } else {
            events = []
        }

        // Run stuck detection
        let stuckInfo = StuckDetector.detect(events: events, currentState: session.agentState)
        session.stuckInfo = stuckInfo

        // Generate narrative
        let summary = SessionNarrative.summarize(
            state: session.agentState,
            events: events,
            stats: session.stats,
            taskStartedAt: session.taskStartedAt,
            stuckInfo: stuckInfo
        )
        session.narrative = summary
    }

    // MARK: - Terminal Buffer Prompt Scanning

    /// Patterns that indicate a permission/input prompt is visible on screen.
    /// These are matched against the rendered terminal buffer (clean text),
    /// which is much more reliable than scanning raw PTY output.
    private static let promptPatterns: [String] = [
        #"(?i)Do you want to allow"#,
        #"(?i)Allow for this session"#,
        #"(?i)Always allow"#,
        #"(?i)Allow\s+once"#,
        #"(?i)Allow\s+\w+.*\?"#,
        #"(?i)approve this"#,
        #"\[y/n\]|\[Y/n\]"#,
        #"\(Y\)es.*\(N\)o"#,
    ]

    /// Scan the rendered terminal buffer for permission prompt patterns.
    /// Prefer scanForInputPrompt(from rowStrings:) with pre-read rows to avoid per-cell yDisp mutations.
    static func scanForInputPrompt(from backend: TerminalBackend) -> Bool {
        let allRows = backend.readRowsAtBottom(count: backend.rows)
        return scanForInputPrompt(from: allRows)
    }

    /// Scan pre-read row strings for permission prompt patterns.
    /// Excludes bottom 3 rows (status bar area) to avoid false matches.
    static func scanForInputPrompt(from rowStrings: [String]) -> Bool {
        let scanEnd = max(0, rowStrings.count - 3)
        let text = Array(rowStrings.prefix(scanEnd)).joined(separator: "\n")

        for pattern in promptPatterns {
            if text.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    /// Check the terminal buffer for input prompts (throttled at 300ms).
    /// Called from the onOutput callback alongside updateStatusLine().
    /// Check the terminal buffer for input prompts (legacy path).
    /// The consolidated runBufferScans() path is preferred — it reads the buffer once.
    private func scanForPromptIfNeeded(session: Session, backend: TerminalBackend) {
        let rows = backend.readRowsAtBottom(count: backend.rows)
        scanForPromptFromSnapshot(session: session, rows: rows)
    }

    // MARK: - Buffer-Based State Scanning

    /// Read rows from the rendered terminal buffer as trimmed strings.
    /// Delegates to backend.readRowsAtBottom for atomic batch reading.
    static func readBufferRows(from backend: TerminalBackend, bottomRows count: Int) -> [String] {
        backend.readRowsAtBottom(count: count)
    }

    /// Scan the rendered terminal buffer for agent state (throttled at 300ms).
    /// Overrides the regex-based state from AgentDetector when the buffer provides
    /// stronger evidence (e.g., spinner visible on screen = definitely working).
    private func scanForAgentStateIfNeeded(session: Session, backend: TerminalBackend) {
        guard session.isAgent else { return }

        let now = Date()
        if let last = lastStateScan[session.id], now.timeIntervalSince(last) < 0.3 {
            return
        }
        lastStateScan[session.id] = now

        let rows = Self.readBufferRows(from: backend, bottomRows: 12)
        let result = BufferStateScanner.scan(rows: rows, agentType: session.agentType)
        applyBufferScanResult(result, to: session)
    }

    /// Apply a BufferStateScanner result to the session's agent state.
    private func applyBufferScanResult(_ result: BufferStateResult, to session: Session) {
        Self.debugLog("scanForAgentState: session=\(session.name) buffer=\(result.state.rawValue) confidence=\(result.confidence.rawValue) reason=\(result.reason) current=\(session.agentState.rawValue)")

        switch result.confidence {
        case .high:
            if session.agentState != result.state {
                session.agentState = result.state
            }
        case .medium:
            if session.agentState == .inactive && result.state != .inactive {
                session.agentState = result.state
            }
        case .none:
            break
        }
    }

    // MARK: - Consolidated Buffer Scanning

    /// Read the terminal buffer ONCE and run all scans against the shared snapshot.
    /// This replaces 4 separate lock-acquire + cellAtBottom scan passes with a single
    /// readRowsAtBottom call (1 yDisp snap/restore instead of ~3000 per-cell mutations).
    private func runBufferScans(session: Session, backend: TerminalBackend) {
        // Read ALL rows at bottom in one atomic pass
        let allRows = backend.readRowsAtBottom(count: backend.rows)
        guard !allRows.isEmpty else { return }

        // Status line parsing (bottom 6 rows, throttled)
        updateStatusLineFromSnapshot(session: session, rows: allRows)
        // Buffer-based agent state scanning (bottom 12 rows, throttled)
        scanForAgentStateFromSnapshot(session: session, rows: allRows)
        // Permission prompt scanning (all rows except bottom 3, throttled)
        scanForPromptFromSnapshot(session: session, rows: allRows)
        // Agent exit check (bottom 6 rows, throttled 5s)
        checkForAgentExitFromSnapshot(session: session, rows: allRows)
    }

    /// Parse status line from pre-read buffer snapshot (throttled).
    private func updateStatusLineFromSnapshot(session: Session, rows: [String]) {
        let now = Date()
        let upgradeAge = agentUpgradeTime[session.id].map { now.timeIntervalSince($0) } ?? 10.0
        let throttleInterval: TimeInterval = upgradeAge < 10.0 ? 0.5 : 2.0
        if let last = lastStatusParse[session.id], now.timeIntervalSince(last) < throttleInterval {
            return
        }
        lastStatusParse[session.id] = now

        let bottom6 = Array(rows.suffix(6))
        let info = Self.parseStatusLine(from: bottom6)
        Self.debugLog("updateStatusLine: session=\(session.name) ctx=\(info.context ?? "nil") model=\(info.model ?? "nil") mode=\(info.mode ?? "nil") effort=\(info.effort ?? "nil") cost=\(info.cost ?? "nil")")
        if let ctx = info.context, ctx != session.agentContext { session.agentContext = ctx }
        if let mode = info.mode, mode != session.agentMode { session.agentMode = mode }
        if let effort = info.effort, effort != session.agentEffort { session.agentEffort = effort }
        if let cost = info.cost, cost != session.agentCost {
            session.agentCost = cost
            if let costVal = Self.parseCostValue(cost) {
                session.stats.recordCost(costVal)
            }
        }
        if let model = info.model, model != session.agentModel {
            session.agentModel = model
        }
    }

    /// Scan pre-read buffer snapshot for agent state (throttled 300ms).
    private func scanForAgentStateFromSnapshot(session: Session, rows: [String]) {
        guard session.isAgent else { return }

        let now = Date()
        if let last = lastStateScan[session.id], now.timeIntervalSince(last) < 0.3 {
            return
        }
        lastStateScan[session.id] = now

        let bottom12 = Array(rows.suffix(12))
        let result = BufferStateScanner.scan(rows: bottom12, agentType: session.agentType)
        applyBufferScanResult(result, to: session)
    }

    /// Scan pre-read buffer snapshot for permission prompts (throttled 300ms).
    private func scanForPromptFromSnapshot(session: Session, rows: [String]) {
        guard session.isAgent else { return }

        let now = Date()
        if let last = lastPromptScan[session.id], now.timeIntervalSince(last) < 0.3 {
            return
        }
        lastPromptScan[session.id] = now

        let promptDetected = Self.scanForInputPrompt(from: rows)

        if promptDetected {
            if session.agentState != .needsInput {
                session.agentState = .needsInput
                session.hasUnreadNotification = true
                if let project = findProject(for: session) {
                    AgentNotifications.notifyAgentState(project: project, session: session)
                }
            }
        } else if session.agentState == .needsInput {
            stateLock.lock()
            let detector = detectors[session.id]
            stateLock.unlock()
            if let detector, detector.state != .needsInput {
                session.agentState = detector.state
            }
        }
    }

    /// Check for agent exit from pre-read buffer snapshot (throttled 5s).
    private func checkForAgentExitFromSnapshot(session: Session, rows: [String]) {
        guard session.isAgent else { return }

        stateLock.lock()
        let detector = detectors[session.id]
        let now = Date()
        if let last = lastDowngradeCheck[session.id], now.timeIntervalSince(last) < 5.0 {
            stateLock.unlock()
            return
        }
        lastDowngradeCheck[session.id] = now
        stateLock.unlock()

        guard let detector, detector.state == .inactive else { return }

        let lastLine = (rows.last ?? "").trimmingCharacters(in: .whitespaces)
        let looksLikeShellPrompt = lastLine.hasSuffix("$") || lastLine.hasSuffix("%")
            || lastLine.hasSuffix("#") || lastLine.hasSuffix(">")

        let bottom6 = Array(rows.suffix(6))
        let bufferText = bottom6.joined(separator: "\n")

        let hasAgentSignature =
            bufferText.range(of: #"(?i)ctx:\s*\d+"#, options: .regularExpression) != nil
            || bufferText.range(of: #"(?i)\b(opus|sonnet|haiku)\s+\d"#, options: .regularExpression) != nil
            || bufferText.range(of: #"shift\+tab"#, options: [.regularExpression, .caseInsensitive]) != nil
            || bufferText.range(of: #"(?i)\bclaude\s+code\b"#, options: .regularExpression) != nil
            || bufferText.range(of: #"(?i)\baider\s*>"#, options: .regularExpression) != nil
            || bufferText.range(of: #"(?i)\bcodex\s*>"#, options: .regularExpression) != nil
            || bufferText.range(of: #"(?i)\bgemini\s*>"#, options: .regularExpression) != nil

        if looksLikeShellPrompt && !hasAgentSignature {
            Self.debugLog("checkForAgentExit: downgrading session=\(session.name) back to plain shell")
            downgradeFromAgent(session: session)
        }
    }

    // MARK: - Private

    func findProject(for session: Session) -> Project? {
        projectStore.projects.first { $0.sessions.contains { $0.id == session.id } }
    }

    private func handleSessionExit(_ session: Session) {
        let wasRunning = session.isRunning
        session.isRunning = false
        session.agentState = .inactive

        // Log session exit
        if let project = findProject(for: session) {
            project.activityLog.append(ActivityEvent(
                timestamp: Date(),
                sessionId: session.id,
                sessionName: session.name,
                kind: .taskCompleted(duration: 0)
            ))
        }

        // Stop recording if active
        stateLock.lock()
        let recorder = recorders.removeValue(forKey: session.id)
        stateLock.unlock()
        recorder?.close()

        // Mark unexpected exit (process died while it was running)
        if wasRunning {
            session.exitedUnexpectedly = true
        }

        if session.autoRestart {
            session.restartAttempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + session.restartDelay) { [weak self] in
                try? self?.startSession(session)
            }
        }

        // Rebuild session list so UI reflects the exit
        DispatchQueue.main.async { [weak self] in
            self?.onSessionListChanged?()
        }
    }
}
