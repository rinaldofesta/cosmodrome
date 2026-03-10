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

    /// Generate suggested actions based on what the agent did during the task.
    public static func suggest(
        filesChanged: [String],
        taskDuration: TimeInterval,
        hasTestCommand: Bool
    ) -> [Action] {
        var actions: [Action] = []

        // Open diff (if files changed)
        if !filesChanged.isEmpty {
            actions.append(Action(
                label: "Open diff (\(filesChanged.count) files)",
                icon: "doc.text.magnifyingglass",
                id: "open_diff"
            ))
        }

        // Run tests (if project has a test command)
        if hasTestCommand {
            actions.append(Action(
                label: "Run tests",
                icon: "checkmark.circle",
                id: "run_tests"
            ))
        }

        // Start review agent (only if task took >60s and files changed)
        if taskDuration > 60 && !filesChanged.isEmpty {
            actions.append(Action(
                label: "Start review agent",
                icon: "eye",
                id: "start_review"
            ))
        }

        return actions
    }

    /// Build a review prompt listing the changed files.
    public static func reviewPrompt(filesChanged: [String]) -> String {
        let fileList = filesChanged.prefix(10).joined(separator: ", ")
        let suffix = filesChanged.count > 10 ? " and \(filesChanged.count - 10) more" : ""
        return "Review the changes in \(fileList)\(suffix) and check for bugs, edge cases, and style issues"
    }
}
