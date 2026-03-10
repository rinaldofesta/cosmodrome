import Foundation

/// A single event captured from agent output.
public struct ActivityEvent {
    public let timestamp: Date
    public let sessionId: UUID
    public let sessionName: String
    public let kind: EventKind

    public enum EventKind {
        case taskStarted
        case taskCompleted(duration: TimeInterval)
        case fileRead(path: String)
        case fileWrite(path: String, added: Int?, removed: Int?)
        case commandRun(command: String)
        case error(message: String)
        case modelChanged(model: String)
        case stateChanged(from: AgentState, to: AgentState)
        case subagentStarted(name: String, description: String)
        case subagentCompleted(name: String, duration: TimeInterval)
        case commandCompleted(command: String?, exitCode: Int?, duration: TimeInterval)
    }

    public init(timestamp: Date, sessionId: UUID, sessionName: String, kind: EventKind) {
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.sessionName = sessionName
        self.kind = kind
    }
}

/// Per-project activity log. Append-only, in-memory, bounded.
/// Thread-safe: events are appended from the I/O thread, read from the main thread.
public final class ActivityLog {
    private var _events: [ActivityEvent] = []
    private let lock = NSLock()
    private let maxEvents = 10_000

    public init() {}

    /// Append an event. Called from I/O thread, must be fast.
    public func append(_ event: ActivityEvent) {
        lock.lock()
        _events.append(event)
        if _events.count > maxEvents {
            _events.removeFirst(_events.count - maxEvents)
        }
        lock.unlock()
    }

    /// Append multiple events at once.
    public func append(contentsOf events: [ActivityEvent]) {
        guard !events.isEmpty else { return }
        lock.lock()
        _events.append(contentsOf: events)
        if _events.count > maxEvents {
            _events.removeFirst(_events.count - maxEvents)
        }
        lock.unlock()
    }

    /// Snapshot of all events. Safe from any thread.
    public var events: [ActivityEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    /// Events for a specific session.
    public func events(for sessionId: UUID) -> [ActivityEvent] {
        events.filter { $0.sessionId == sessionId }
    }

    /// Files written across all sessions in this project.
    public var filesChanged: [String] {
        events.compactMap {
            if case .fileWrite(let path, _, _) = $0.kind { return path }
            return nil
        }
    }

    /// Events from the last N minutes.
    public func summary(last minutes: Int) -> [ActivityEvent] {
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        return events.filter { $0.timestamp > cutoff }
    }

    /// Total event count.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _events.count
    }
}
