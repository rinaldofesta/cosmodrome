import Core
import Foundation

/// Bridges MCP server tool calls to the actual Cosmodrome application.
final class MCPBridge: MCPServerDelegate {
    weak var sessionManager: SessionManager?
    weak var projectStore: ProjectStore?

    // Active recordings keyed by session ID
    private var recorders: [UUID: AsciicastRecorder] = [:]

    // Callback to focus a session in the UI
    var onFocusSession: ((UUID) -> Void)?

    func handleToolCall(name: String, arguments: [String: Any]) -> Result<String, Error> {
        switch name {
        case "list_projects":
            return listProjects()
        case "list_sessions":
            guard let projectId = arguments["project_id"] as? String,
                  let uuid = UUID(uuidString: projectId) else {
                return .failure(MCPBridgeError.invalidArgument("project_id"))
            }
            return listSessions(projectId: uuid)
        case "get_session_content":
            guard let sessionId = arguments["session_id"] as? String,
                  let uuid = UUID(uuidString: sessionId) else {
                return .failure(MCPBridgeError.invalidArgument("session_id"))
            }
            let lastN = arguments["last_n_lines"] as? Int
            return getSessionContent(sessionId: uuid, lastNLines: lastN)
        case "send_input":
            guard let sessionId = arguments["session_id"] as? String,
                  let uuid = UUID(uuidString: sessionId),
                  let text = arguments["text"] as? String else {
                return .failure(MCPBridgeError.invalidArgument("session_id or text"))
            }
            return sendInput(sessionId: uuid, text: text)
        case "get_agent_states":
            return getAgentStates()
        case "focus_session":
            guard let sessionId = arguments["session_id"] as? String,
                  let uuid = UUID(uuidString: sessionId) else {
                return .failure(MCPBridgeError.invalidArgument("session_id"))
            }
            return focusSession(sessionId: uuid)
        case "start_recording":
            guard let sessionId = arguments["session_id"] as? String,
                  let uuid = UUID(uuidString: sessionId) else {
                return .failure(MCPBridgeError.invalidArgument("session_id"))
            }
            let path = arguments["path"] as? String
            return startRecording(sessionId: uuid, path: path)
        case "stop_recording":
            guard let sessionId = arguments["session_id"] as? String,
                  let uuid = UUID(uuidString: sessionId) else {
                return .failure(MCPBridgeError.invalidArgument("session_id"))
            }
            return stopRecording(sessionId: uuid)
        default:
            return .failure(MCPBridgeError.unknownTool(name))
        }
    }

    // MARK: - Tool Implementations

    private func listProjects() -> Result<String, Error> {
        guard let store = projectStore else {
            return .failure(MCPBridgeError.notConnected)
        }

        var lines: [String] = []
        for project in store.projects {
            let state = project.aggregateState.rawValue
            let attention = project.attentionCount
            lines.append("- \(project.name) (id: \(project.id), state: \(state), attention: \(attention), sessions: \(project.sessions.count))")
        }
        return .success(lines.isEmpty ? "No projects." : lines.joined(separator: "\n"))
    }

    private func listSessions(projectId: UUID) -> Result<String, Error> {
        guard let project = findProject(id: projectId) else {
            return .failure(MCPBridgeError.projectNotFound(projectId))
        }

        var lines: [String] = []
        for session in project.sessions {
            let running = session.isRunning ? "running" : "stopped"
            let agent = session.isAgent ? " [agent:\(session.agentState.rawValue)]" : ""
            lines.append("- \(session.name) (id: \(session.id), \(running)\(agent), cmd: \(session.command))")
        }
        return .success(lines.isEmpty ? "No sessions." : lines.joined(separator: "\n"))
    }

    private func getSessionContent(sessionId: UUID, lastNLines: Int?) -> Result<String, Error> {
        guard let session = findSession(id: sessionId) else {
            return .failure(MCPBridgeError.sessionNotFound(sessionId))
        }
        guard let backend = session.backend else {
            return .success("[Session not running]")
        }

        var lines: [String] = []
        backend.lock()
        for row in 0..<backend.rows {
            var line = ""
            for col in 0..<backend.cols {
                let cell = backend.cell(row: row, col: col)
                if cell.codepoint == 0 || cell.codepoint == 32 {
                    line.append(" ")
                } else if let scalar = Unicode.Scalar(cell.codepoint) {
                    line.append(Character(scalar))
                }
            }
            lines.append(line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
        }
        backend.unlock()

        // Remove trailing empty lines
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }

        if let n = lastNLines, n > 0 {
            lines = Array(lines.suffix(n))
        }

        return .success(lines.joined(separator: "\n"))
    }

    private func sendInput(sessionId: UUID, text: String) -> Result<String, Error> {
        guard let session = findSession(id: sessionId) else {
            return .failure(MCPBridgeError.sessionNotFound(sessionId))
        }
        guard session.isRunning else {
            return .failure(MCPBridgeError.sessionNotRunning(sessionId))
        }

        // Replace escape sequences
        let processed = text
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\t", with: "\t")

        if let data = processed.data(using: .utf8) {
            sessionManager?.write(to: session, data: data)

            // Record input if recording
            if let recorder = recorders[session.id] {
                recorder.recordInput(data)
            }
        }
        return .success("Input sent.")
    }

    private func getAgentStates() -> Result<String, Error> {
        guard let store = projectStore else {
            return .failure(MCPBridgeError.notConnected)
        }

        var lines: [String] = []
        for project in store.projects {
            for session in project.sessions where session.isAgent {
                lines.append("- \(project.name)/\(session.name): \(session.agentState.rawValue)")
            }
        }
        return .success(lines.isEmpty ? "No agents running." : lines.joined(separator: "\n"))
    }

    private func focusSession(sessionId: UUID) -> Result<String, Error> {
        guard findSession(id: sessionId) != nil else {
            return .failure(MCPBridgeError.sessionNotFound(sessionId))
        }
        DispatchQueue.main.async { [weak self] in
            self?.onFocusSession?(sessionId)
        }
        return .success("Session focused.")
    }

    private func startRecording(sessionId: UUID, path: String?) -> Result<String, Error> {
        guard let session = findSession(id: sessionId) else {
            return .failure(MCPBridgeError.sessionNotFound(sessionId))
        }
        guard recorders[sessionId] == nil else {
            return .success("Already recording.")
        }

        let backend = session.backend
        let width = backend?.cols ?? 80
        let height = backend?.rows ?? 24

        let filePath = path ?? {
            let dir = NSTemporaryDirectory()
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            return "\(dir)cosmodrome-\(session.name)-\(timestamp).cast"
        }()

        do {
            let recorder = try AsciicastRecorder(
                path: filePath, width: width, height: height, title: session.name
            )
            recorders[sessionId] = recorder
            return .success("Recording started: \(filePath)")
        } catch {
            return .failure(error)
        }
    }

    private func stopRecording(sessionId: UUID) -> Result<String, Error> {
        guard let recorder = recorders.removeValue(forKey: sessionId) else {
            return .success("Not recording.")
        }
        recorder.close()
        return .success("Recording stopped.")
    }

    /// Called from the I/O path to record output if a recorder is active.
    func recordOutputIfNeeded(sessionId: UUID, bytes: UnsafeRawBufferPointer) {
        recorders[sessionId]?.recordOutput(bytes)
    }

    // MARK: - Helpers

    private func findProject(id: UUID) -> Project? {
        projectStore?.projects.first { $0.id == id }
    }

    private func findSession(id: UUID) -> Session? {
        projectStore?.projects.flatMap(\.sessions).first { $0.id == id }
    }
}

enum MCPBridgeError: LocalizedError {
    case notConnected
    case invalidArgument(String)
    case unknownTool(String)
    case projectNotFound(UUID)
    case sessionNotFound(UUID)
    case sessionNotRunning(UUID)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "MCP bridge not connected to application"
        case .invalidArgument(let name): return "Invalid or missing argument: \(name)"
        case .unknownTool(let name): return "Unknown tool: \(name)"
        case .projectNotFound(let id): return "Project not found: \(id)"
        case .sessionNotFound(let id): return "Session not found: \(id)"
        case .sessionNotRunning(let id): return "Session not running: \(id)"
        }
    }
}
