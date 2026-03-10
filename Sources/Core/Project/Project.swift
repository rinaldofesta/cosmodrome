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
