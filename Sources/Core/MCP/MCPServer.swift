import Foundation

/// Model Context Protocol server for Cosmodrome.
/// Exposes tools for AI agents to interact with terminal sessions.
/// Uses JSON-RPC 2.0 over stdio.
public final class MCPServer {

    /// Handler that the app layer implements to bridge MCP requests to actual sessions.
    public weak var delegate: MCPServerDelegate?

    private var inputBuffer = Data()
    private let readQueue = DispatchQueue(label: "com.cosmodrome.mcp.read")
    private let writeQueue = DispatchQueue(label: "com.cosmodrome.mcp.write")
    private var isRunning = false

    public init() {}

    // MARK: - Server Lifecycle

    /// Start listening for JSON-RPC messages on stdin, writing responses to stdout.
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        readQueue.async { [weak self] in
            self?.readLoop()
        }
    }

    /// Stop the server.
    public func stop() {
        isRunning = false
    }

    // MARK: - Tool Definitions

    /// MCP tools exposed by Cosmodrome.
    public static let toolDefinitions: [[String: Any]] = [
        [
            "name": "list_projects",
            "description": "List all projects and their sessions with agent states.",
            "inputSchema": [
                "type": "object",
                "properties": [:] as [String: Any],
            ],
        ],
        [
            "name": "list_sessions",
            "description": "List sessions for a specific project.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string", "description": "Project UUID"],
                ],
                "required": ["project_id"],
            ],
        ],
        [
            "name": "get_session_content",
            "description": "Get the visible terminal content of a session.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "session_id": ["type": "string", "description": "Session UUID"],
                    "last_n_lines": ["type": "integer", "description": "Number of lines from bottom (default: all visible)"],
                ],
                "required": ["session_id"],
            ],
        ],
        [
            "name": "get_agent_states",
            "description": "Get all agent states across all projects.",
            "inputSchema": [
                "type": "object",
                "properties": [:] as [String: Any],
            ],
        ],
        [
            "name": "focus_session",
            "description": "Switch focus to a specific session.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "session_id": ["type": "string", "description": "Session UUID"],
                ],
                "required": ["session_id"],
            ],
        ],
        [
            "name": "start_recording",
            "description": "Start recording a session in asciicast format.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "session_id": ["type": "string", "description": "Session UUID"],
                    "path": ["type": "string", "description": "Output file path (.cast)"],
                ],
                "required": ["session_id"],
            ],
        ],
        [
            "name": "stop_recording",
            "description": "Stop recording a session.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "session_id": ["type": "string", "description": "Session UUID"],
                ],
                "required": ["session_id"],
            ],
        ],
        [
            "name": "get_fleet_stats",
            "description": "Get fleet-wide statistics: agent counts by state, total cost, tasks completed, files changed.",
            "inputSchema": [
                "type": "object",
                "properties": [:] as [String: Any],
            ],
        ],
        [
            "name": "get_activity_log",
            "description": "Get the activity log: structured timeline of agent events (file changes, commands, errors, tasks) across all projects.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "since_minutes": ["type": "integer", "description": "Only events from last N minutes (default: all)"],
                    "session_id": ["type": "string", "description": "Filter to a specific session UUID"],
                    "category": ["type": "string", "description": "Filter by category: files, commands, errors, tasks, subagents, state"],
                ] as [String: Any],
            ],
        ],
    ]

    // MARK: - Read Loop

    private func readLoop() {
        let stdin = FileHandle.standardInput

        while isRunning {
            let data = stdin.availableData
            guard !data.isEmpty else {
                // EOF
                isRunning = false
                break
            }

            inputBuffer.append(data)
            processBuffer()
        }
    }

    private func processBuffer() {
        // MCP uses Content-Length header framing (like LSP)
        while let message = extractMessage() {
            handleMessage(message)
        }
    }

    private func extractMessage() -> Data? {
        guard let headerEnd = findHeaderEnd() else { return nil }

        let headerData = inputBuffer[0..<headerEnd]
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }

        // Parse Content-Length
        var contentLength: Int?
        for line in headerStr.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("Content-Length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(value)
            }
        }

        guard let length = contentLength else {
            // Try bare JSON (no headers) — some MCP clients send raw JSON lines
            if let newline = inputBuffer.firstIndex(of: 0x0A) {
                let lineData = inputBuffer[0..<newline]
                inputBuffer = inputBuffer[(newline + 1)...]
                return Data(lineData)
            }
            return nil
        }

        let bodyStart = headerEnd + 4 // skip \r\n\r\n
        let messageEnd = bodyStart + length

        guard inputBuffer.count >= messageEnd else { return nil }

        let body = inputBuffer[bodyStart..<messageEnd]
        inputBuffer = inputBuffer[messageEnd...]
        return Data(body)
    }

    private func findHeaderEnd() -> Int? {
        // Look for \r\n\r\n
        let bytes = Array(inputBuffer)
        for i in 0..<(bytes.count - 3) {
            if bytes[i] == 0x0D && bytes[i+1] == 0x0A && bytes[i+2] == 0x0D && bytes[i+3] == 0x0A {
                return i
            }
        }
        return nil
    }

    // MARK: - Message Handling

    private func handleMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let id = json["id"]
        let method = json["method"] as? String ?? ""
        let params = json["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            handleInitialize(id: id, params: params)
        case "tools/list":
            handleToolsList(id: id)
        case "tools/call":
            handleToolsCall(id: id, params: params)
        case "notifications/initialized":
            // Client ack — no response needed
            break
        default:
            sendError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func handleInitialize(id: Any?, params: [String: Any]) {
        let response: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "tools": [:] as [String: Any],
            ],
            "serverInfo": [
                "name": "cosmodrome",
                "version": "0.2.0",
            ],
        ]
        sendResult(id: id, result: response)
    }

    private func handleToolsList(id: Any?) {
        sendResult(id: id, result: ["tools": MCPServer.toolDefinitions])
    }

    private func handleToolsCall(id: Any?, params: [String: Any]) {
        guard let toolName = params["name"] as? String else {
            sendError(id: id, code: -32602, message: "Missing tool name")
            return
        }

        let arguments = params["arguments"] as? [String: Any] ?? [:]

        guard let delegate else {
            sendError(id: id, code: -32603, message: "Server not connected to application")
            return
        }

        let result = delegate.handleToolCall(name: toolName, arguments: arguments)

        switch result {
        case .success(let value):
            sendResult(id: id, result: [
                "content": [
                    ["type": "text", "text": value],
                ],
            ])
        case .failure(let error):
            sendResult(id: id, result: [
                "content": [
                    ["type": "text", "text": error.localizedDescription],
                ],
                "isError": true,
            ])
        }
    }

    // MARK: - Response Writing

    private func sendResult(id: Any?, result: Any) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result,
        ]
        if let id { response["id"] = id }
        sendJSON(response)
    }

    private func sendError(id: Any?, code: Int, message: String) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message,
            ],
        ]
        if let id { response["id"] = id }
        sendJSON(response)
    }

    private func sendJSON(_ obj: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }

        writeQueue.sync {
            let header = "Content-Length: \(data.count)\r\n\r\n"
            FileHandle.standardOutput.write(header.data(using: .utf8)!)
            FileHandle.standardOutput.write(data)
        }
    }
}

/// Protocol for the app layer to implement, bridging MCP requests to real sessions.
public protocol MCPServerDelegate: AnyObject {
    func handleToolCall(name: String, arguments: [String: Any]) -> Result<String, Error>
}
