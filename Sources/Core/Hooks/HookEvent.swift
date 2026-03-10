import Foundation

/// Represents an event received from the CosmodromeHook binary via Unix socket.
/// Claude Code invokes hooks at various lifecycle points; each invocation sends
/// a JSON payload that we parse into this struct.
public struct HookEvent {
    public let hookName: String
    public let sessionId: UUID?
    public let timestamp: Date
    public let toolName: String?
    public let toolInput: String?
    public let toolOutput: String?
    public let notification: String?
    public let stopReason: String?

    public init(
        hookName: String,
        sessionId: UUID? = nil,
        timestamp: Date = Date(),
        toolName: String? = nil,
        toolInput: String? = nil,
        toolOutput: String? = nil,
        notification: String? = nil,
        stopReason: String? = nil
    ) {
        self.hookName = hookName
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.toolName = toolName
        self.toolInput = toolInput
        self.toolOutput = toolOutput
        self.notification = notification
        self.stopReason = stopReason
    }

    /// Parse a HookEvent from JSON data received over the socket.
    public static func parse(from data: Data) -> HookEvent? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let hookName = json["hook_name"] as? String else { return nil }

        let sessionId: UUID?
        if let idStr = json["session_id"] as? String {
            sessionId = UUID(uuidString: idStr)
        } else {
            sessionId = nil
        }

        return HookEvent(
            hookName: hookName,
            sessionId: sessionId,
            timestamp: Date(),
            toolName: json["tool_name"] as? String,
            toolInput: json["tool_input"] as? String,
            toolOutput: json["tool_output"] as? String,
            notification: json["notification"] as? String,
            stopReason: json["stop_reason"] as? String
        )
    }

    /// Convert this hook event into an ActivityEvent.EventKind for the activity log.
    public func toEventKind() -> ActivityEvent.EventKind? {
        switch hookName {
        case "PreToolUse":
            guard let tool = toolName else { return nil }
            if tool == "Agent" {
                let desc = toolInput ?? ""
                return .subagentStarted(name: tool, description: desc)
            }
            if tool == "Bash" || tool == "Execute" {
                return .commandRun(command: toolInput ?? tool)
            }
            if tool == "Read" || tool == "Glob" || tool == "Grep" {
                return .fileRead(path: toolInput ?? "")
            }
            if tool == "Write" || tool == "Edit" {
                return .fileWrite(path: toolInput ?? "", added: nil, removed: nil)
            }
            return nil

        case "PostToolUse":
            guard let tool = toolName else { return nil }
            if tool == "Agent" {
                return .subagentCompleted(name: tool, duration: 0)
            }
            return nil

        case "Notification":
            if let msg = notification {
                return .error(message: msg)
            }
            return nil

        case "Stop":
            return .taskCompleted(duration: 0)

        default:
            return nil
        }
    }
}
