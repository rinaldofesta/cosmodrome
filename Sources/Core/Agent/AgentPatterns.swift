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
                    regex: #"(?i)(Allow\s+\w+.*\?|yes/no|\[y/n\]|\(y\)|\(n\)|\(Y\)es|\(N\)o|Do you want to|permission)"#,
                    lastLineOnly: false,
                    priority: 30
                ),
                AgentPattern(
                    state: .error,
                    regex: #"(?i)(error|failed|exception|panic|fatal)"#,
                    lastLineOnly: false,
                    priority: 20
                ),
                AgentPattern(
                    state: .working,
                    regex: #"[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏●]"#,
                    lastLineOnly: true,
                    priority: 15
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
                    regex: #"(?i)(error|failed|traceback)"#,
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
                    state: .error,
                    regex: #"(?i)(error|failed|exception|could not|unable to)"#,
                    lastLineOnly: false,
                    priority: 20
                ),
                AgentPattern(
                    state: .working,
                    regex: #"[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]"#,
                    lastLineOnly: true,
                    priority: 15
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
                    state: .error,
                    regex: #"(?i)(error|failed|exception|fatal|rate.limit)"#,
                    lastLineOnly: false,
                    priority: 20
                ),
                AgentPattern(
                    state: .working,
                    regex: #"[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏●]"#,
                    lastLineOnly: true,
                    priority: 15
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
                    state: .error,
                    regex: #"(?i)(error|failed|exception)"#,
                    lastLineOnly: false,
                    priority: 20
                ),
                AgentPattern(
                    state: .working,
                    regex: #"[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]"#,
                    lastLineOnly: true,
                    priority: 10
                ),
            ]
        }
    }

    /// Try to detect agent type from the command name.
    public static func detectType(from command: String) -> String? {
        let cmd = (command as NSString).lastPathComponent.lowercased()
        if cmd.contains("claude") { return "claude" }
        if cmd.contains("aider") { return "aider" }
        if cmd.contains("codex") { return "codex" }
        if cmd.contains("gemini") { return "gemini" }
        return nil
    }
}
