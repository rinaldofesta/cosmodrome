import Foundation

/// Suggests next actions when an agent completes a task.
public struct CompletionActions {

    public struct Action {
        public let label: String
        public let icon: String // SF Symbol name
        public let id: String   // For identification

        public init(label: String, icon: String, id: String) {
            self.label = label
            self.icon = icon
            self.id = id
        }
    }

    /// Rich context for generating completion suggestions.
    public struct CompletionContext {
        public let filesChanged: [String]
        public let taskDuration: TimeInterval
        public let hasTestCommand: Bool
        public let stats: SessionStats
        public let events: [ActivityEvent]
        public let narrative: SessionNarrative.Summary?
        public let stuckInfo: StuckDetector.StuckInfo?

        public init(
            filesChanged: [String],
            taskDuration: TimeInterval,
            hasTestCommand: Bool,
            stats: SessionStats,
            events: [ActivityEvent],
            narrative: SessionNarrative.Summary?,
            stuckInfo: StuckDetector.StuckInfo?
        ) {
            self.filesChanged = filesChanged
            self.taskDuration = taskDuration
            self.hasTestCommand = hasTestCommand
            self.stats = stats
            self.events = events
            self.narrative = narrative
            self.stuckInfo = stuckInfo
        }
    }

    /// Generate suggested actions based on what the agent did during the task.
    public static func suggest(
        filesChanged: [String],
        taskDuration: TimeInterval,
        hasTestCommand: Bool
    ) -> [Action] {
        suggest(context: CompletionContext(
            filesChanged: filesChanged,
            taskDuration: taskDuration,
            hasTestCommand: hasTestCommand,
            stats: SessionStats(),
            events: [],
            narrative: nil,
            stuckInfo: nil
        ))
    }

    /// Generate context-aware suggested actions using full session data.
    public static func suggest(context: CompletionContext) -> [Action] {
        var actions: [Action] = []

        // Open diff (if files changed)
        if !context.filesChanged.isEmpty {
            actions.append(Action(
                label: "Open diff (\(context.filesChanged.count) files)",
                icon: "doc.text.magnifyingglass",
                id: "open_diff"
            ))
        }

        // Run tests — prioritize if tests were failing or no test was run during task
        let testResult = lastTestResult(in: context.events)
        if context.hasTestCommand || testResult != nil {
            let testLabel: String
            if testResult == .failing {
                testLabel = "Re-run tests (were failing)"
            } else if testResult == .passing {
                testLabel = "Verify tests"
            } else {
                testLabel = "Run tests"
            }
            actions.append(Action(
                label: testLabel,
                icon: testResult == .failing ? "exclamationmark.triangle" : "checkmark.circle",
                id: "run_tests"
            ))
        }

        // Start review agent (if task took >60s and files changed)
        if context.taskDuration > 60 && !context.filesChanged.isEmpty {
            actions.append(Action(
                label: "Start review agent",
                icon: "eye",
                id: "start_review"
            ))
        }

        return actions
    }

    /// Build a rich summary line for the completion bar.
    /// Example: "Completed: auth refactor. 15 files, tests passing. 23 min, $4.20."
    public static func summaryLine(context: CompletionContext) -> String {
        var parts: [String] = []

        // Use narrative headline if available (it already has the "what" context)
        if let narrative = context.narrative, !narrative.headline.hasPrefix("Done") {
            parts.append(narrative.headline)
        } else {
            parts.append("Task completed")
        }

        // Stats segment: files, duration, cost
        var statParts: [String] = []
        if !context.filesChanged.isEmpty {
            statParts.append("\(context.filesChanged.count) files")
        }

        let testResult = lastTestResult(in: context.events)
        if testResult == .passing {
            statParts.append("tests passing")
        } else if testResult == .failing {
            statParts.append("tests failing")
        }

        let durationStr = SessionStats.formatDuration(context.taskDuration)
        statParts.append(durationStr)

        let cost = context.stats.totalCost
        if cost > 0 {
            statParts.append(SessionStats.formatCost(cost))
        }

        if !statParts.isEmpty {
            parts.append(statParts.joined(separator: ", "))
        }

        return parts.joined(separator: ". ") + "."
    }

    /// Build a review prompt listing the changed files.
    public static func reviewPrompt(filesChanged: [String]) -> String {
        let fileList = filesChanged.prefix(10).joined(separator: ", ")
        let suffix = filesChanged.count > 10 ? " and \(filesChanged.count - 10) more" : ""
        return "Review the changes in \(fileList)\(suffix) and check for bugs, edge cases, and style issues"
    }

    // MARK: - Helpers

    private enum TestResult { case passing, failing }

    private static func lastTestResult(in events: [ActivityEvent]) -> TestResult? {
        let testCommands = events.suffix(20).filter {
            if case .commandCompleted(let cmd, _, _) = $0.kind {
                let c = cmd ?? ""
                return c.contains("test") || c.contains("spec") || c.contains("check")
            }
            return false
        }

        guard let last = testCommands.last,
              case .commandCompleted(_, let exitCode, _) = last.kind else { return nil }

        return exitCode == 0 ? .passing : .failing
    }
}
