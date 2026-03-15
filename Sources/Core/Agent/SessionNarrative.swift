import Foundation

/// Produces human-readable narrative summaries from raw session data.
/// Replaces bare state labels ("working", "needsInput") with contextual descriptions.
///
/// All logic is heuristic — zero LLM calls, zero latency, works offline.
public struct SessionNarrative {

    /// A narrative summary for a session at a point in time.
    public struct Summary {
        /// One-line narrative (shown in session card, fleet card).
        public let headline: String
        /// Longer description with stats (shown in tooltips, expanded views).
        public let detail: String?
        /// Whether this state warrants user attention.
        public let needsAttention: Bool
        /// Urgency scoring for priority sorting.
        public let urgency: UrgencyScorer.Urgency?
        /// Interpretation context (e.g. task classification).
        public let interpretation: String?

        public init(headline: String, detail: String? = nil, needsAttention: Bool,
                    urgency: UrgencyScorer.Urgency? = nil, interpretation: String? = nil) {
            self.headline = headline
            self.detail = detail
            self.needsAttention = needsAttention
            self.urgency = urgency
            self.interpretation = interpretation
        }
    }

    // MARK: - Public API

    /// Generate a narrative summary for a session.
    /// - Parameters:
    ///   - state: Current agent state.
    ///   - events: Recent activity events for this session (from ActivityLog).
    ///   - stats: Session usage stats.
    ///   - taskStartedAt: When the current task began (nil if no active task).
    ///   - stuckInfo: Stuck detection result (nil if not stuck).
    ///   - promptContext: Extracted text of what the agent is asking (nil if not needsInput).
    public static func summarize(
        state: AgentState,
        events: [ActivityEvent],
        stats: SessionStats,
        taskStartedAt: Date?,
        stuckInfo: StuckDetector.StuckInfo?,
        promptContext: String? = nil,
        stateEnteredAt: Date? = nil
    ) -> Summary {
        if let stuckInfo {
            return summarizeStuck(stuckInfo: stuckInfo, stats: stats)
        }

        switch state {
        case .working:
            return summarizeWorking(events: events, stats: stats, taskStartedAt: taskStartedAt)
        case .needsInput:
            return summarizeNeedsInput(events: events, promptContext: promptContext)
        case .error:
            return summarizeError(events: events, stats: stats)
        case .inactive:
            return summarizeInactive(events: events, stats: stats)
        }
    }

    // MARK: - State-specific narratives

    private static func summarizeWorking(
        events: [ActivityEvent],
        stats: SessionStats,
        taskStartedAt: Date?
    ) -> Summary {
        let recentEvents = recentTaskEvents(events)
        let filesInTask = uniqueFilesWritten(in: recentEvents)
        let elapsed = taskStartedAt.map { SessionStats.formatDuration(Date().timeIntervalSince($0)) }

        // Detect what kind of work is happening from recent events
        let activity = detectActivity(from: recentEvents)

        var parts: [String] = []
        if let activity { parts.append(activity) }

        var statParts: [String] = []
        if !filesInTask.isEmpty { statParts.append("\(filesInTask.count) files") }
        if let elapsed { statParts.append(elapsed) }

        let headline: String
        if parts.isEmpty && statParts.isEmpty {
            headline = "Working\u{2026}"
        } else if parts.isEmpty {
            headline = "Working — \(statParts.joined(separator: ", "))"
        } else {
            let suffix = statParts.isEmpty ? "" : " — \(statParts.joined(separator: ", "))"
            headline = parts.joined(separator: " ") + suffix
        }

        let detail = buildDetail(stats: stats, filesInTask: filesInTask)

        return Summary(headline: headline, detail: detail, needsAttention: false)
    }

    private static func summarizeNeedsInput(
        events: [ActivityEvent],
        promptContext: String?
    ) -> Summary {
        let headline: String
        if let context = promptContext {
            // Truncate long prompts
            let trimmed = context.prefix(80)
            headline = "Waiting: \(trimmed)"
        } else {
            // Fall back to generic with what we know from events
            let lastTool = lastToolMention(in: events)
            if let tool = lastTool {
                headline = "Waiting for approval — \(tool)"
            } else {
                headline = "Waiting for input"
            }
        }

        return Summary(headline: headline, detail: nil, needsAttention: true)
    }

    private static func summarizeError(
        events: [ActivityEvent],
        stats: SessionStats
    ) -> Summary {
        let recentErrors = events.suffix(20).filter {
            if case .error = $0.kind { return true }
            if case .commandCompleted(_, let exit, _) = $0.kind, let e = exit, e != 0 { return true }
            return false
        }

        let errorCount = stats.totalErrors
        let lastError = recentErrors.last

        var headline = "Error"
        if let lastError, case .error(let msg) = lastError.kind {
            let trimmed = String(msg.prefix(60))
            headline = "Error: \(trimmed)"
        } else if let lastError, case .commandCompleted(let cmd, let exit, _) = lastError.kind {
            let cmdName = cmd.map { String($0.prefix(30)) } ?? "command"
            headline = "Failed: \(cmdName) (exit \(exit ?? 1))"
        }

        if errorCount > 1 {
            headline += " (\(errorCount) total)"
        }

        return Summary(headline: headline, detail: nil, needsAttention: true)
    }

    private static func summarizeInactive(
        events: [ActivityEvent],
        stats: SessionStats
    ) -> Summary {
        // Check if we just completed a task (has taskCompleted events)
        let lastCompletion = events.last { if case .taskCompleted = $0.kind { return true }; return false }
        let hasActivity = stats.totalTasks > 0 || stats.totalFilesChanged > 0

        if let lastCompletion, case .taskCompleted(let duration) = lastCompletion.kind {
            return summarizeCompleted(duration: duration, events: events, stats: stats)
        }

        if hasActivity {
            // Idle after doing work
            var parts: [String] = ["Idle"]
            if let idle = stats.idleDurationString {
                parts[0] = "Idle \(idle)"
            }
            var statParts: [String] = []
            if stats.totalTasks > 0 { statParts.append("\(stats.totalTasks) tasks") }
            if stats.totalFilesChanged > 0 { statParts.append("\(stats.totalFilesChanged) files") }
            if stats.totalCost > 0 { statParts.append(SessionStats.formatCost(stats.totalCost)) }
            if !statParts.isEmpty {
                parts.append(statParts.joined(separator: ", "))
            }
            let headline = parts.joined(separator: ". ")
            return Summary(headline: headline, detail: nil, needsAttention: false)
        }

        // No activity yet — fresh session
        return Summary(headline: "Ready", detail: nil, needsAttention: false)
    }

    private static func summarizeCompleted(
        duration: TimeInterval,
        events: [ActivityEvent],
        stats: SessionStats
    ) -> Summary {
        let filesInTask = uniqueFilesWritten(in: recentTaskEvents(events))
        let durationStr = SessionStats.formatDuration(duration)

        var parts: [String] = ["Done"]

        var statParts: [String] = []
        if !filesInTask.isEmpty { statParts.append("\(filesInTask.count) files") }
        statParts.append(durationStr)
        if stats.totalCost > 0 { statParts.append(SessionStats.formatCost(stats.totalCost)) }
        parts.append(statParts.joined(separator: ", "))

        // Check for test results
        let testResult = lastTestResult(in: events)
        if let result = testResult {
            parts.append(result)
        }

        return Summary(
            headline: parts.joined(separator: ". "),
            detail: buildDetail(stats: stats, filesInTask: filesInTask),
            needsAttention: false
        )
    }

    private static func summarizeStuck(
        stuckInfo: StuckDetector.StuckInfo,
        stats: SessionStats
    ) -> Summary {
        let durationStr = SessionStats.formatDuration(stuckInfo.duration)
        var headline = "Stuck"
        if let pattern = stuckInfo.pattern {
            headline = "Stuck: \(pattern) (\(stuckInfo.retryCount)x, \(durationStr))"
        } else {
            headline = "Stuck — \(stuckInfo.retryCount) retries over \(durationStr)"
        }

        return Summary(headline: headline, detail: nil, needsAttention: true)
    }

    // MARK: - Helpers

    /// Detect the dominant activity from recent events.
    private static func detectActivity(from events: [ActivityEvent]) -> String? {
        let recent = events.suffix(10)

        // Check for subagent activity
        let subagents = recent.filter { if case .subagentStarted = $0.kind { return true }; return false }
        if let last = subagents.last, case .subagentStarted(let name, _) = last.kind {
            return "Running agent: \(String(name.prefix(40)))"
        }

        // Check for command execution
        let commands = recent.filter { if case .commandRun = $0.kind { return true }; return false }
        if let last = commands.last, case .commandRun(let cmd) = last.kind {
            let shortCmd = String(cmd.prefix(40))
            return "Running: \(shortCmd)"
        }

        // Check for file activity
        let writes = recent.filter { if case .fileWrite = $0.kind { return true }; return false }
        let reads = recent.filter { if case .fileRead = $0.kind { return true }; return false }

        if !writes.isEmpty {
            let paths = writes.compactMap { e -> String? in
                if case .fileWrite(let p, _, _) = e.kind { return p }
                return nil
            }
            if let commonDir = commonDirectory(paths) {
                return "Editing \(commonDir)"
            }
            return "Editing files"
        }

        if !reads.isEmpty {
            return "Reading code"
        }

        return nil
    }

    /// Get the last tool/file mentioned in events (for needsInput context).
    private static func lastToolMention(in events: [ActivityEvent]) -> String? {
        for event in events.suffix(5).reversed() {
            switch event.kind {
            case .fileWrite(let path, _, _): return path
            case .fileRead(let path): return path
            case .commandRun(let cmd): return String(cmd.prefix(30))
            default: continue
            }
        }
        return nil
    }

    /// Get events from the current/last task.
    private static func recentTaskEvents(_ events: [ActivityEvent]) -> [ActivityEvent] {
        // Find the last taskStarted event and return everything after it
        guard let lastStartIdx = events.lastIndex(where: {
            if case .taskStarted = $0.kind { return true }
            return false
        }) else {
            // No task boundary — return last 50 events
            return Array(events.suffix(50))
        }
        return Array(events[lastStartIdx...])
    }

    /// Unique file paths written in the given events.
    private static func uniqueFilesWritten(in events: [ActivityEvent]) -> Set<String> {
        var files = Set<String>()
        for event in events {
            if case .fileWrite(let path, _, _) = event.kind {
                files.insert(path)
            }
        }
        return files
    }

    /// Find a common directory prefix from file paths.
    private static func commonDirectory(_ paths: [String]) -> String? {
        guard paths.count >= 2 else { return paths.first.map { ($0 as NSString).lastPathComponent } }

        let components = paths.map { $0.split(separator: "/").map(String.init) }
        var common: [String] = []
        let minLen = components.map(\.count).min() ?? 0

        for i in 0..<minLen {
            let comp = components[0][i]
            if components.allSatisfy({ $0.count > i && $0[i] == comp }) {
                common.append(comp)
            } else {
                break
            }
        }

        if common.isEmpty { return nil }
        // Return the deepest directory name
        return common.last
    }

    /// Check for test results in recent command completions.
    private static func lastTestResult(in events: [ActivityEvent]) -> String? {
        let testCommands = events.suffix(20).filter {
            if case .commandCompleted(let cmd, _, _) = $0.kind {
                let c = cmd ?? ""
                return c.contains("test") || c.contains("spec") || c.contains("check")
            }
            return false
        }

        guard let last = testCommands.last,
              case .commandCompleted(_, let exitCode, _) = last.kind else { return nil }

        if exitCode == 0 { return "Tests passing" }
        return "Tests failing"
    }

    /// Build a detail string with full stats.
    private static func buildDetail(stats: SessionStats, filesInTask: Set<String>) -> String? {
        var parts: [String] = []
        if stats.totalTasks > 0 { parts.append("\(stats.totalTasks) tasks") }
        if !filesInTask.isEmpty { parts.append("\(filesInTask.count) files changed") }
        if stats.totalCommands > 0 { parts.append("\(stats.totalCommands) commands") }
        if stats.totalSubagents > 0 { parts.append("\(stats.totalSubagents) subagents") }
        if stats.totalCost > 0 { parts.append(SessionStats.formatCost(stats.totalCost)) }
        parts.append(stats.uptimeString)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
