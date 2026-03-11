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
    /// Called on main thread when the session list changes structurally (exit, restart).
    var onSessionListChanged: (() -> Void)?
    private var recorders: [UUID: AsciicastRecorder] = [:]
    /// Detectors stored by session ID — accessible for hook event forwarding.
    private(set) var detectors: [UUID: AgentDetector] = [:]
    /// Throttle for runtime agent detection in shell sessions.
    private var lastAgentCheck: [UUID: Date] = [:]
    /// Lock for dicts accessed from both I/O and main threads.
    private let stateLock = NSLock()

    /// Socket path for the hook server — injected into spawned sessions' environment.
    var hookSocketPath: String?

    /// Called on main thread when an agent completes a task (working → not working).
    /// Parameters: session, filesChanged, taskDuration
    var onTaskCompleted: ((Session, [String], TimeInterval) -> Void)?

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
        let cwd = session.cwd == "." ? FileManager.default.currentDirectoryPath : session.cwd

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
            detector = AgentDetector(
                agentType: session.agentType ?? "claude",
                sessionId: session.id,
                sessionName: session.name
            )
        } else if let detectedType = AgentPatterns.detectType(from: session.command) {
            session.isAgent = true
            session.agentType = detectedType
            detector = AgentDetector(
                agentType: detectedType,
                sessionId: session.id,
                sessionName: session.name
            )
        } else {
            detector = nil
        }

        if let detector {
            stateLock.lock()
            detectors[session.id] = detector
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

                        // Parse Claude Code status bar (throttled)
                        self?.updateStatusLine(session: session, backend: backend)

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

                        // Handle state transitions
                        if newState != oldState {
                            // Starting a new task
                            if newState == .working && oldState != .working {
                                session.taskStartedAt = Date()
                                session.filesChangedInTask = []
                            }

                            // Task completed (was working, now not)
                            if oldState == .working && newState != .working {
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
                                self?.onTaskCompleted?(session, files, duration)
                            }

                            // Mark session as needing attention + send macOS notification
                            if newState == .needsInput || newState == .error {
                                session.hasUnreadNotification = true
                            }
                            if let project = self?.findProject(for: session) {
                                AgentNotifications.notifyAgentState(project: project, session: session)
                            }
                        }
                    }
                } else {
                    // No detector yet — check if an agent started in this shell session
                    self?.checkForAgentStartup(session: session, backend: backend)
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

        if session.pid > 0 {
            kill(session.pid, SIGTERM)
        }
        if session.ptyFD >= 0 {
            multiplexer.unregister(fd: session.ptyFD)
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
        stateLock.lock()
        lastStatusParse.removeValue(forKey: session.id)
        detectors.removeValue(forKey: session.id)
        lastAgentCheck.removeValue(forKey: session.id)
        stateLock.unlock()
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
        guard recorders[session.id] == nil else { return }

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
            recorders[session.id] = recorder
        } catch {
            FileHandle.standardError.write("[Cosmodrome] Failed to start recording: \(error)\n".data(using: .utf8)!)
        }
    }

    /// Stop recording a session.
    func stopRecording(session: Session) {
        guard let recorder = recorders.removeValue(forKey: session.id) else { return }
        recorder.close()
    }

    /// Check if a session is being recorded.
    func isRecording(session: Session) -> Bool {
        recorders[session.id] != nil
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

        // Read last few lines from the terminal buffer
        backend.lock()
        let rows = backend.rows
        let cols = backend.cols
        var text = ""
        for row in max(0, rows - 5)..<rows {
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

        // Detect agent startup signatures — use spinner chars (reliable, no false positives)
        let agentType: String?
        if text.range(of: #"[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]"#, options: .regularExpression) != nil {
            agentType = "claude"
        } else if text.range(of: #"(?i)\baider\s*>"#, options: .regularExpression) != nil {
            agentType = "aider"
        } else if text.range(of: #"(?i)\bcodex\s*>"#, options: .regularExpression) != nil {
            agentType = "codex"
        } else if text.range(of: #"(?i)\bgemini\s*>"#, options: .regularExpression) != nil {
            agentType = "gemini"
        } else {
            agentType = nil
        }

        if let agentType {
            DispatchQueue.main.async { [weak self] in
                self?.upgradeToAgentSession(session: session, agentType: agentType)
            }
        }
    }

    /// Upgrade a shell session to an agent session: create detector, re-register with multiplexer.
    func upgradeToAgentSession(session: Session, agentType: String) {
        guard !session.isAgent else { return }
        guard session.ptyFD >= 0, let backend = session.backend else { return }

        session.isAgent = true
        session.agentType = agentType

        let detector = AgentDetector(
            agentType: agentType,
            sessionId: session.id,
            sessionName: session.name
        )
        stateLock.lock()
        detectors[session.id] = detector
        stateLock.unlock()

        // Re-register with multiplexer to include the detector for inline analysis
        let sessionId = session.id
        let onDirty = onSessionDirty ?? {}

        let io = PTYMultiplexer.SessionIO(
            id: sessionId,
            backend: backend,
            agentDetector: detector,
            onOutput: { [weak self] in
                if let detector = self?.detectors[sessionId] {
                    let newState = detector.state
                    let oldState = session.agentState
                    let model = detector.modelDetector.currentModel
                    let events = detector.consumeEvents()

                    DispatchQueue.main.async {
                        session.agentState = newState
                        if model != session.agentModel { session.agentModel = model }
                        self?.updateStatusLine(session: session, backend: backend)

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

                        if newState != oldState {
                            if newState == .working && oldState != .working {
                                session.taskStartedAt = Date()
                                session.filesChangedInTask = []
                            }
                            if oldState == .working && newState != .working {
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
                                self?.onTaskCompleted?(session, files, duration)
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

    // MARK: - Status Line Parsing

    private static let debugStatus = ProcessInfo.processInfo.environment["COSMODROME_DEBUG_STATUS"] != nil

    private static func debugLog(_ message: @autoclosure () -> String) {
        if debugStatus {
            FileHandle.standardError.write("[StatusParse] \(message())\n".data(using: .utf8)!)
        }
    }

    /// Parse Claude Code's status bar from the terminal buffer (throttled to every 2s).
    private func updateStatusLine(session: Session, backend: TerminalBackend) {
        let now = Date()
        if let last = lastStatusParse[session.id], now.timeIntervalSince(last) < 2.0 {
            return
        }
        lastStatusParse[session.id] = now

        let info = Self.parseStatusLine(from: backend)
        if info.context != session.agentContext { session.agentContext = info.context }
        if info.mode != session.agentMode { session.agentMode = info.mode }
        if info.effort != session.agentEffort { session.agentEffort = info.effort }
        if info.cost != session.agentCost { session.agentCost = info.cost }
        if let model = info.model, model != session.agentModel {
            session.agentModel = model
        }
    }

    struct StatusLineInfo {
        var context: String?
        var mode: String?
        var effort: String?
        var cost: String?
        var model: String?
    }

    /// Read the bottom rows of the terminal buffer and extract status bar info.
    /// Claude Code's status line format (2 lines at bottom):
    ///   Line 1: user@host  /path  Opus 4.6 | ctx: 89%   ● high · /effort
    ///   Line 2: ⏸ plan mode on (shift+tab to cycle)
    static func parseStatusLine(from backend: TerminalBackend) -> StatusLineInfo {
        backend.lock()
        let rows = backend.rows
        let cols = backend.cols

        // Read bottom 6 rows into individual trimmed strings
        var rowStrings: [String] = []
        for row in max(0, rows - 6)..<rows {
            var line = ""
            for col in 0..<cols {
                let cell = backend.cell(row: row, col: col)
                let cp = cell.codepoint
                if cp >= 32 && cp < 0x110000 {
                    line.append(Character(Unicode.Scalar(cp)!))
                } else {
                    line.append(" ")
                }
            }
            // Trim trailing whitespace
            while line.hasSuffix(" ") { line.removeLast() }
            rowStrings.append(line)
        }
        backend.unlock()

        debugLog("Bottom 6 rows: \(rowStrings.enumerated().map { "[\($0)]: \($1)" }.joined(separator: " | "))")

        var info = StatusLineInfo()

        // Classify rows: find the "info row" (ctx: or model) and "mode row" (mode on/off)
        var infoRow: String?
        var modeRow: String?

        for row in rowStrings {
            if row.range(of: #"ctx:\s*\d+"#, options: .regularExpression) != nil
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
        if let range = infoText.range(of: #"ctx:\s*(\d+%)"#, options: .regularExpression) {
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

        // Match confirmed Claude Code formats: "plan mode on", "accept edits on", "bypass permissions on"
        let modePatterns: [(pattern: String, label: String)] = [
            (#"(?i)\bbypass\s+permissions?"#, "Bypass"),
            (#"(?i)\baccept\s+edits?"#, "Accept Edits"),
            (#"(?i)\bplan\s+mode"#, "Plan"),
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
        if let recorder = recorders.removeValue(forKey: session.id) {
            recorder.close()
        }

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
