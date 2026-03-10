import AppKit
import Core
import Foundation

/// Manages the lifecycle of terminal sessions: spawning PTY processes,
/// connecting them to backends and the multiplexer, handling exits.
final class SessionManager {
    let multiplexer: PTYMultiplexer
    let projectStore: ProjectStore
    private var onSessionDirty: (() -> Void)?
    /// Called on main thread when the session list changes structurally (exit, restart).
    var onSessionListChanged: (() -> Void)?
    private var recorders: [UUID: AsciicastRecorder] = [:]

    /// Socket path for the hook server — injected into spawned sessions' environment.
    var hookSocketPath: String?

    /// Called on main thread when an agent completes a task (working → not working).
    /// Parameters: session, filesChanged, taskDuration
    var onTaskCompleted: ((Session, [String], TimeInterval) -> Void)?

    init(projectStore: ProjectStore) {
        self.projectStore = projectStore
        self.multiplexer = PTYMultiplexer()
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

        let detector: AgentDetector? = session.isAgent
            ? AgentDetector(
                agentType: session.agentType ?? "claude",
                sessionId: session.id,
                sessionName: session.name
            )
            : nil

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
                if let detector {
                    let newState = detector.state
                    let oldState = session.agentState
                    let model = detector.modelDetector.currentModel
                    let events = detector.consumeEvents()

                    DispatchQueue.main.async {
                        session.agentState = newState
                        session.agentModel = model

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

                            // Notification on state change to needsInput/error
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
                self?.recorders[sessionId]?.recordOutput(bytes)
            }
        )

        multiplexer.register(fd: result.fd, session: io)
    }

    /// Stop a session: kill the process, clean up.
    func stopSession(_ session: Session) {
        guard session.isRunning else { return }

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
        session.taskStartedAt = nil
        session.filesChangedInTask = []
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

    // MARK: - Private

    func findProject(for session: Session) -> Project? {
        projectStore.projects.first { $0.sessions.contains { $0.id == session.id } }
    }

    private func handleSessionExit(_ session: Session) {
        let wasRunning = session.isRunning
        session.isRunning = false
        session.agentState = .inactive

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
