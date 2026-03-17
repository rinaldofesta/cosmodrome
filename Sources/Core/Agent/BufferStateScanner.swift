import Foundation

/// Result of scanning the rendered terminal buffer for agent state.
public struct BufferStateResult {
    public enum Confidence: String {
        case high, medium, none
    }

    public let state: AgentState
    public let confidence: Confidence
    public let reason: String

    public init(state: AgentState, confidence: Confidence, reason: String) {
        self.state = state
        self.confidence = confidence
        self.reason = reason
    }
}

/// Scans rendered terminal buffer rows (clean text) to detect agent state.
/// Unlike regex-based detection on raw PTY output, this reads what's actually
/// visible on screen — immune to ANSI stripping issues and fragmented reads.
public enum BufferStateScanner {

    // Braille spinner characters used by Claude Code and other TUI agents.
    // Must appear at line start (after optional whitespace) to avoid false matches.
    // Note: ● is intentionally excluded — it appears in Claude Code's status bar
    // as an effort indicator (e.g. "● high", "● low") and causes false positives.
    private static let spinnerPattern = #"(?m)^\s*[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]"#

    // Claude Code status bar signatures (at least one must be present).
    private static let statusBarPatterns: [(pattern: String, options: String.CompareOptions)] = [
        (#"(?i)ctx:\s*\d+"#, [.regularExpression]),
        (#"(?i)\b(opus|sonnet|haiku)\s+\d"#, [.regularExpression]),
        (#"shift\+tab"#, [.regularExpression, .caseInsensitive]),
    ]

    // Structured error indicators (not just the word "error" — requires punctuation/caps).
    private static let errorPattern = #"(?:Error:|error:|ERROR[ :\n]|FAILED|fatal error|panic:|×\s)"#

    // Claude Code idle input prompt: ">" at start of a line.
    // Uses (?m) for multiline mode so ^ and $ match line boundaries.
    private static let idlePromptPattern = #"(?m)^>\s*$"#

    /// Scan pre-read buffer rows to detect agent state.
    /// - Parameters:
    ///   - rows: Array of trimmed strings, one per terminal row (bottom rows of screen).
    ///   - agentType: The agent type ("claude", "aider", etc.) or nil.
    /// - Returns: A state with confidence level, or `.none` confidence if no detection.
    public static func scan(rows: [String], agentType: String?) -> BufferStateResult {
        // Only apply buffer-based detection for Claude Code.
        // Other agents (aider, codex, gemini) are line-mode and the regex detector works fine.
        guard agentType == "claude" else {
            return BufferStateResult(state: .inactive, confidence: .none, reason: "non-claude agent")
        }

        let fullText = rows.joined(separator: "\n")

        // 1. Check for spinner characters (definitive working indicator)
        let hasSpinner = fullText.range(of: spinnerPattern, options: .regularExpression) != nil

        // 2. Check for Claude Code status bar
        let hasStatusBar = statusBarPatterns.contains { pattern, options in
            fullText.range(of: pattern, options: options) != nil
        }

        // 3. Check for idle input prompt
        let hasIdlePrompt = fullText.range(of: idlePromptPattern, options: .regularExpression) != nil

        // 4. Check for error indicators
        let hasError = fullText.range(of: errorPattern, options: .regularExpression) != nil

        // Decision logic
        if hasSpinner {
            // Spinner visible on screen = agent is actively working
            return BufferStateResult(state: .working, confidence: .high, reason: "spinner visible")
        }

        if hasStatusBar {
            if hasIdlePrompt && !hasError {
                // Status bar + idle prompt = agent is waiting for user input (idle)
                return BufferStateResult(state: .inactive, confidence: .high, reason: "status bar + idle prompt")
            }
            if hasError {
                // Status bar + error text visible
                return BufferStateResult(state: .error, confidence: .medium, reason: "status bar + error text")
            }
            // Status bar visible but no spinner, no prompt — ambiguous
            return BufferStateResult(state: .inactive, confidence: .medium, reason: "status bar visible, no spinner")
        }

        return BufferStateResult(state: .inactive, confidence: .none, reason: "no agent signatures")
    }
}
