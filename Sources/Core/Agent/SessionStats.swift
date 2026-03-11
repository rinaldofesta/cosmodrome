import Foundation

/// Per-session usage statistics. Updated inline on I/O thread via AgentDetector,
/// read on main thread for UI. Thread-safe via NSLock.
public final class SessionStats {
    private let lock = NSLock()

    // Accumulated metrics
    private var _totalCost: Double = 0
    private var _totalTasks: Int = 0
    private var _totalErrors: Int = 0
    private var _totalFilesChanged: Int = 0
    private var _totalCommands: Int = 0
    private var _totalSubagents: Int = 0

    // Idle tracking
    private var _idleStartedAt: Date?
    private var _totalIdleTime: TimeInterval = 0
    private var _lastActiveAt: Date?

    // Session lifetime
    public let sessionStartedAt: Date

    // Cost history for sparklines (timestamp, cumulative cost)
    private var _costHistory: [(Date, Double)] = []
    private let maxCostHistory = 200

    public init(startedAt: Date = Date()) {
        self.sessionStartedAt = startedAt
    }

    // MARK: - Thread-safe reads

    public var totalCost: Double { lock.withLock { _totalCost } }
    public var totalTasks: Int { lock.withLock { _totalTasks } }
    public var totalErrors: Int { lock.withLock { _totalErrors } }
    public var totalFilesChanged: Int { lock.withLock { _totalFilesChanged } }
    public var totalCommands: Int { lock.withLock { _totalCommands } }
    public var totalSubagents: Int { lock.withLock { _totalSubagents } }
    public var lastActiveAt: Date? { lock.withLock { _lastActiveAt } }
    public var costHistory: [(Date, Double)] { lock.withLock { _costHistory } }

    /// Current idle duration. Returns 0 if the agent is active.
    public var currentIdleDuration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        if let idleStart = _idleStartedAt {
            return Date().timeIntervalSince(idleStart)
        }
        return 0
    }

    /// Total accumulated idle time (including current idle stretch if any).
    public var totalIdleTime: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        var total = _totalIdleTime
        if let idleStart = _idleStartedAt {
            total += Date().timeIntervalSince(idleStart)
        }
        return total
    }

    /// Session uptime.
    public var uptime: TimeInterval {
        Date().timeIntervalSince(sessionStartedAt)
    }

    // MARK: - Mutations (called from I/O thread)

    /// Record a cost update (parsed from agent status line).
    public func recordCost(_ cost: Double) {
        lock.lock()
        _totalCost = cost
        let now = Date()
        _costHistory.append((now, cost))
        if _costHistory.count > maxCostHistory {
            _costHistory.removeFirst()
        }
        lock.unlock()
    }

    /// Record a task completion.
    public func recordTaskCompleted() {
        lock.withLock { _totalTasks += 1 }
    }

    /// Record an error.
    public func recordError() {
        lock.withLock { _totalErrors += 1 }
    }

    /// Record a file write.
    public func recordFileChanged() {
        lock.withLock { _totalFilesChanged += 1 }
    }

    /// Record a command execution.
    public func recordCommand() {
        lock.withLock { _totalCommands += 1 }
    }

    /// Record a subagent spawn.
    public func recordSubagent() {
        lock.withLock { _totalSubagents += 1 }
    }

    /// Called on state transition. Tracks idle time accumulation.
    public func recordStateTransition(from: AgentState, to: AgentState) {
        lock.lock()
        let now = Date()

        if to == .inactive {
            // Entering idle
            if _idleStartedAt == nil {
                _idleStartedAt = now
            }
        } else {
            // Leaving idle
            if let idleStart = _idleStartedAt {
                _totalIdleTime += now.timeIntervalSince(idleStart)
                _idleStartedAt = nil
            }
            _lastActiveAt = now
        }

        lock.unlock()
    }
}

// MARK: - Formatting helpers

extension SessionStats {
    /// Human-readable idle duration string. Returns nil if not idle.
    public var idleDurationString: String? {
        let idle = currentIdleDuration
        guard idle > 10 else { return nil } // Don't show for <10s
        return Self.formatDuration(idle)
    }

    /// Human-readable uptime string.
    public var uptimeString: String {
        Self.formatDuration(uptime)
    }

    /// Format a duration as "5s", "2m", "1h 23m", etc.
    public static func formatDuration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainMinutes = minutes % 60
        if remainMinutes == 0 { return "\(hours)h" }
        return "\(hours)h \(remainMinutes)m"
    }

    /// Format cost as "$X.XX".
    public static func formatCost(_ cost: Double) -> String {
        if cost < 0.01 { return "$0.00" }
        return String(format: "$%.2f", cost)
    }
}
