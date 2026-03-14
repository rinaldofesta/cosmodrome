import Foundation

public struct AgentPattern: Sendable {
    public let state: AgentState
    public let regex: String
    public let lastLineOnly: Bool
    public let priority: Int

    public init(state: AgentState, regex: String, lastLineOnly: Bool, priority: Int) {
        self.state = state
        self.regex = regex
        self.lastLineOnly = lastLineOnly
        self.priority = priority
    }
}

/// Built-in pattern definitions for known AI agents.
public enum AgentPatterns {

    /// All known agent type identifiers.
    public static let knownTypes = ["claude", "aider", "codex", "gemini"]

    public static func patterns(for agentType: String) -> [AgentPattern] {
        switch agentType.lowercased() {
        case "claude":
            return [
                AgentPattern(
                    state: .needsInput,
                    regex: #"(?i)(Allow\s+\w+.*\?|Allow for this session|Always allow|Allow once|yes/no|\[y/n\]|\[Y/n\]|\(y\)|\(n\)|\(Y\)es|\(N\)o|Do you want to allow|Press Enter to|approve this)"#,
                    lastLineOnly: false,
                    priority: 30
                ),
                AgentPattern(
                    state: .working,
                    regex: #"[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏●]"#,
                    lastLineOnly: true,
                    priority: 25
                ),
                AgentPattern(
                    state: .error,
                    regex: #"(?:Error:|error:|ERROR[ :\n]|FAILED|fatal error|panic:|×\s)"#,
                    lastLineOnly: false,
                    priority: 20
                ),
                AgentPattern(
                    state: .working,
                    regex: #"(Read|Write|Execute|Bash|Search|Glob|Grep|Edit|Agent)\s"#,
                    lastLineOnly: false,
                    priority: 10
                ),
            ]

        case "aider":
            return [
                AgentPattern(
                    state: .needsInput,
                    regex: #"(?i)(\[y/n\]|yes/no|confirm|> $)"#,
                    lastLineOnly: true,
                    priority: 30
                ),
                AgentPattern(
                    state: .error,
                    regex: #"(?i)(error:|Error |traceback|FAILED)"#,
                    lastLineOnly: false,
                    priority: 20
                ),
                AgentPattern(
                    state: .working,
                    regex: #"(?i)(thinking|streaming|applying|Editing)"#,
                    lastLineOnly: false,
                    priority: 10
                ),
            ]

        case "codex":
            return [
                AgentPattern(
                    state: .needsInput,
                    regex: #"(?i)(approve|deny|confirm|\[y/n\]|waiting for review|accept changes)"#,
                    lastLineOnly: false,
                    priority: 30
                ),
                AgentPattern(
                    state: .working,
                    regex: #"[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]"#,
                    lastLineOnly: true,
                    priority: 25
                ),
                AgentPattern(
                    state: .error,
                    regex: #"(?i)(error:|Error |ERROR|FAILED|could not|unable to)"#,
                    lastLineOnly: false,
                    priority: 20
                ),
                AgentPattern(
                    state: .working,
                    regex: #"(?i)(running|executing|generating|reading|writing|patching)"#,
                    lastLineOnly: false,
                    priority: 10
                ),
            ]

        case "gemini":
            return [
                AgentPattern(
                    state: .needsInput,
                    regex: #"(?i)(confirm|approve|\[y/n\]|yes/no|do you want|shall I)"#,
                    lastLineOnly: false,
                    priority: 30
                ),
                AgentPattern(
                    state: .working,
                    regex: #"[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏●]"#,
                    lastLineOnly: true,
                    priority: 25
                ),
                AgentPattern(
                    state: .error,
                    regex: #"(?i)(error:|Error |ERROR|FAILED|fatal error|rate.limit)"#,
                    lastLineOnly: false,
                    priority: 20
                ),
                AgentPattern(
                    state: .working,
                    regex: #"(?i)(thinking|generating|processing|analyzing|searching)"#,
                    lastLineOnly: false,
                    priority: 10
                ),
            ]

        default:
            return [
                AgentPattern(
                    state: .needsInput,
                    regex: #"(?i)(\[y/n\]|yes/no|confirm|approve)"#,
                    lastLineOnly: false,
                    priority: 30
                ),
                AgentPattern(
                    state: .working,
                    regex: #"[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]"#,
                    lastLineOnly: true,
                    priority: 25
                ),
                AgentPattern(
                    state: .error,
                    regex: #"(?i)(error:|\bERROR\b|\bFAILED\b|exception:|panic:)"#,
                    lastLineOnly: false,
                    priority: 20
                ),
            ]
        }
    }

    /// Try to detect agent type from the command name or full command string.
    /// Matches bare commands (`claude`), full paths (`/usr/local/bin/claude`),
    /// and npx invocations (`npx @anthropic-ai/claude-code`, `npx claude`).
    public static func detectType(from command: String) -> String? {
        let cmd = (command as NSString).lastPathComponent.lowercased()
        let full = command.lowercased()
        if cmd.contains("claude") || full.contains("claude-code") || full.contains("claude code") { return "claude" }
        if cmd.contains("aider") { return "aider" }
        if cmd.contains("codex") { return "codex" }
        if cmd.contains("gemini") { return "gemini" }
        return nil
    }
}
