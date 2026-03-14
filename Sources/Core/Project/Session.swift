import Foundation
import Observation

@Observable
public final class Session: Identifiable {
    public let id: UUID
    public var name: String
    public var command: String
    public var arguments: [String]
    public var cwd: String
    public var environment: [String: String]
    public var autoStart: Bool
    public var autoRestart: Bool
    public var restartDelay: TimeInterval
    public var isAgent: Bool
    public var agentType: String?

    // Runtime state (not persisted)
    public var agentState: AgentState = .inactive
    public var agentModel: String?
    public var agentContext: String?     // e.g. "45k/200k"
    public var agentMode: String?        // e.g. "Plan", "Accept Edits", "Bypass"
    public var agentEffort: String?      // e.g. "high", "medium", "low"
    public var agentCost: String?        // e.g. "$0.34"
    @ObservationIgnored public var backend: TerminalBackend?
    @ObservationIgnored public var ptyFD: Int32 = -1
    @ObservationIgnored public var pid: pid_t = 0
    public var isRunning: Bool = false
    public var exitedUnexpectedly: Bool = false
    @ObservationIgnored public var restartAttempts: Int = 0
    @ObservationIgnored public var taskStartedAt: Date?
    @ObservationIgnored public var filesChangedInTask: [String] = []
    public var hasUnreadNotification: Bool = false
    @ObservationIgnored public var lastNotification: TerminalNotification?
    public var detectedPorts: [UInt16] = []
    public var gitBranch: String?
    @ObservationIgnored public var agentSince: Date?

    // Narrative summary (updated periodically by SessionManager)
    public var narrative: SessionNarrative.Summary?
    @ObservationIgnored public var stuckInfo: StuckDetector.StuckInfo?

    // Usage stats (accumulated from activity events)
    @ObservationIgnored public let stats = SessionStats()

    public init(
        id: UUID = UUID(),
        name: String,
        command: String,
        arguments: [String] = [],
        cwd: String = ".",
        environment: [String: String] = [:],
        autoStart: Bool = false,
        autoRestart: Bool = false,
        restartDelay: TimeInterval = 1.0,
        isAgent: Bool = false,
        agentType: String? = nil
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.arguments = arguments
        self.cwd = cwd
        self.environment = environment
        self.autoStart = autoStart
        self.autoRestart = autoRestart
        self.restartDelay = restartDelay
        self.isAgent = isAgent
        self.agentType = agentType
    }
}
