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

    // Runtime state (not persisted, updated from I/O thread)
    @ObservationIgnored public var agentState: AgentState = .inactive
    @ObservationIgnored public var agentModel: String?
    @ObservationIgnored public var backend: TerminalBackend?
    @ObservationIgnored public var ptyFD: Int32 = -1
    @ObservationIgnored public var pid: pid_t = 0
    @ObservationIgnored public var isRunning: Bool = false
    @ObservationIgnored public var exitedUnexpectedly: Bool = false
    @ObservationIgnored public var restartAttempts: Int = 0
    @ObservationIgnored public var taskStartedAt: Date?
    @ObservationIgnored public var filesChangedInTask: [String] = []

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
