import Foundation
import Observation

@Observable
public final class Project: Identifiable {
    public let id: UUID
    public var name: String
    public var color: String
    public var rootPath: String?
    public var sessions: [Session]
    @ObservationIgnored public let activityLog = ActivityLog()

    public var aggregateState: AgentState {
        let agents = sessions.filter { $0.isAgent }
        if agents.contains(where: { $0.agentState == .error }) { return .error }
        if agents.contains(where: { $0.agentState == .needsInput }) { return .needsInput }
        if agents.contains(where: { $0.agentState == .working }) { return .working }
        return .inactive
    }

    public var attentionCount: Int {
        sessions.count(where: { $0.agentState == .needsInput || $0.agentState == .error })
    }

    // MARK: - Aggregated Stats

    /// Total cost across all agent sessions in this project.
    public var totalCost: Double {
        sessions.filter(\.isAgent).reduce(0) { $0 + $1.stats.totalCost }
    }

    /// Total tasks completed across all agent sessions.
    public var totalTasks: Int {
        sessions.filter(\.isAgent).reduce(0) { $0 + $1.stats.totalTasks }
    }

    /// Total files changed across all agent sessions.
    public var totalFilesChanged: Int {
        sessions.filter(\.isAgent).reduce(0) { $0 + $1.stats.totalFilesChanged }
    }

    /// Count of agent sessions in each state.
    public var agentCounts: (working: Int, idle: Int, needsInput: Int, error: Int) {
        let agents = sessions.filter(\.isAgent)
        return (
            working: agents.count(where: { $0.agentState == .working }),
            idle: agents.count(where: { $0.agentState == .inactive }),
            needsInput: agents.count(where: { $0.agentState == .needsInput }),
            error: agents.count(where: { $0.agentState == .error })
        )
    }

    public init(
        id: UUID = UUID(),
        name: String,
        color: String = "#4A90D9",
        rootPath: String? = nil,
        sessions: [Session] = []
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.rootPath = rootPath
        self.sessions = sessions
    }
}
