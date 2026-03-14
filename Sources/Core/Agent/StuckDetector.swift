import Foundation

/// Detects when an agent is stuck in an error→retry loop.
/// Consumes recent activity events and identifies repetition patterns.
///
/// "Stuck" means: the agent has been retrying the same kind of error
/// for a sustained period without making progress. This is interpretation:
/// it adds the judgment "this needs your attention" to the raw data "error".
public enum StuckDetector {

    /// Result of stuck detection.
    public struct StuckInfo {
        /// How many times the error pattern repeated.
        public let retryCount: Int
        /// How long the loop has been going.
        public let duration: TimeInterval
        /// Short description of the repeating pattern (e.g. "compile error").
        public let pattern: String?

        public init(retryCount: Int, duration: TimeInterval, pattern: String?) {
            self.retryCount = retryCount
            self.duration = duration
            self.pattern = pattern
        }
    }

    /// Minimum retries before flagging as stuck.
    private static let minRetries = 3
    /// Time window to look for repeating errors.
    private static let lookbackWindow: TimeInterval = 600 // 10 minutes

    /// Analyze recent events and determine if the session is stuck.
    /// - Parameters:
    ///   - events: Activity events for a single session (recent, ordered by time).
    ///   - currentState: The session's current agent state.
    /// - Returns: StuckInfo if stuck, nil otherwise.
    public static func detect(
        events: [ActivityEvent],
        currentState: AgentState
    ) -> StuckInfo? {
        // Only detect stuck when in working or error state
        guard currentState == .working || currentState == .error else { return nil }

        let cutoff = Date().addingTimeInterval(-lookbackWindow)
        let recentEvents = events.filter { $0.timestamp > cutoff }

        // Look for error→stateChanged→error cycles
        let errorEvents = recentEvents.filter { isErrorEvent($0) }
        guard errorEvents.count >= minRetries else { return nil }

        // Check for the error→working→error pattern (retry loop)
        let stateChanges = recentEvents.filter {
            if case .stateChanged = $0.kind { return true }
            return false
        }

        let errorToWorkingCycles = countErrorCycles(stateChanges: stateChanges)
        guard errorToWorkingCycles >= minRetries else { return nil }

        // Calculate loop duration
        guard let firstError = errorEvents.first?.timestamp else { return nil }
        let duration = Date().timeIntervalSince(firstError)

        // Try to identify the error pattern
        let pattern = identifyPattern(errors: errorEvents)

        return StuckInfo(
            retryCount: errorToWorkingCycles,
            duration: duration,
            pattern: pattern
        )
    }

    // MARK: - Private

    private static func isErrorEvent(_ event: ActivityEvent) -> Bool {
        switch event.kind {
        case .error:
            return true
        case .commandCompleted(_, let exitCode, _):
            return exitCode != nil && exitCode != 0
        case .stateChanged(_, let to):
            return to == .error
        default:
            return false
        }
    }

    /// Count error→working→error cycles in state changes.
    private static func countErrorCycles(stateChanges: [ActivityEvent]) -> Int {
        var cycles = 0
        var lastState: AgentState?

        for event in stateChanges {
            guard case .stateChanged(_, let to) = event.kind else { continue }

            if to == .error && lastState == .working {
                cycles += 1
            }
            lastState = to
        }

        return cycles
    }

    /// Try to identify a short pattern description from error messages.
    private static func identifyPattern(errors: [ActivityEvent]) -> String? {
        var messages: [String] = []
        for event in errors {
            switch event.kind {
            case .error(let msg):
                messages.append(msg)
            case .commandCompleted(let cmd, _, _):
                if let cmd { messages.append(cmd) }
            default:
                break
            }
        }

        guard !messages.isEmpty else { return nil }

        // Find common keywords across error messages
        if messages.allSatisfy({ $0.localizedCaseInsensitiveContains("compile") || $0.localizedCaseInsensitiveContains("build") }) {
            return "compile error"
        }
        if messages.allSatisfy({ $0.localizedCaseInsensitiveContains("test") }) {
            return "test failure"
        }
        if messages.allSatisfy({ $0.localizedCaseInsensitiveContains("permission") || $0.localizedCaseInsensitiveContains("denied") }) {
            return "permission denied"
        }
        if messages.allSatisfy({ $0.localizedCaseInsensitiveContains("timeout") }) {
            return "timeout"
        }

        // Fall back to first short error message
        let first = messages[0]
        if first.count <= 40 { return first }
        return String(first.prefix(37)) + "\u{2026}"
    }
}
