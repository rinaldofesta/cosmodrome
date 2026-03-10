import Foundation

// MARK: - Project Configuration (cosmodrome.yml)

public struct ProjectConfig: Codable {
    public var name: String
    public var color: String?
    public var sessions: [SessionConfig]
    public var layout: String?

    public init(name: String, color: String? = nil, sessions: [SessionConfig] = [], layout: String? = nil) {
        self.name = name
        self.color = color
        self.sessions = sessions
        self.layout = layout
    }
}

public struct SessionConfig: Codable {
    public var name: String
    public var command: String
    public var args: [String]?
    public var cwd: String?
    public var env: [String: String]?
    public var agent: Bool?
    public var agentType: String?
    public var autoStart: Bool?
    public var autoRestart: Bool?
    public var restartDelay: Double?

    enum CodingKeys: String, CodingKey {
        case name, command, args, cwd, env, agent
        case agentType = "agent_type"
        case autoStart = "auto_start"
        case autoRestart = "auto_restart"
        case restartDelay = "restart_delay"
    }

    public init(
        name: String,
        command: String,
        args: [String]? = nil,
        cwd: String? = nil,
        env: [String: String]? = nil,
        agent: Bool? = nil,
        agentType: String? = nil,
        autoStart: Bool? = nil,
        autoRestart: Bool? = nil,
        restartDelay: Double? = nil
    ) {
        self.name = name
        self.command = command
        self.args = args
        self.cwd = cwd
        self.env = env
        self.agent = agent
        self.agentType = agentType
        self.autoStart = autoStart
        self.autoRestart = autoRestart
        self.restartDelay = restartDelay
    }
}

// MARK: - User Configuration (~/.config/cosmodrome/config.yml)

public struct UserConfig: Codable {
    public var font: FontConfig?
    public var theme: String?
    public var window: WindowConfig?
    public var notifications: NotificationConfig?

    public init(
        font: FontConfig? = nil,
        theme: String? = nil,
        window: WindowConfig? = nil,
        notifications: NotificationConfig? = nil
    ) {
        self.font = font
        self.theme = theme
        self.window = window
        self.notifications = notifications
    }

    public struct FontConfig: Codable {
        public var family: String?
        public var size: Double?
        public var lineHeight: Double?

        public init(family: String? = nil, size: Double? = nil, lineHeight: Double? = nil) {
            self.family = family
            self.size = size
            self.lineHeight = lineHeight
        }
    }

    public struct WindowConfig: Codable {
        public var opacity: Double?
        public var restoreState: Bool?

        enum CodingKeys: String, CodingKey {
            case opacity
            case restoreState = "restore_state"
        }

        public init(opacity: Double? = nil, restoreState: Bool? = nil) {
            self.opacity = opacity
            self.restoreState = restoreState
        }
    }

    public struct NotificationConfig: Codable {
        public var agentNeedsInput: Bool?
        public var agentError: Bool?
        public var processExited: Bool?

        enum CodingKeys: String, CodingKey {
            case agentNeedsInput = "agent_needs_input"
            case agentError = "agent_error"
            case processExited = "process_exited"
        }

        public init(agentNeedsInput: Bool? = nil, agentError: Bool? = nil, processExited: Bool? = nil) {
            self.agentNeedsInput = agentNeedsInput
            self.agentError = agentError
            self.processExited = processExited
        }
    }
}

// MARK: - App State (~/.../Cosmodrome/state.yml)

public struct AppState: Codable {
    public var windowFrame: [Double]
    public var sidebarWidth: Double
    public var activeProjectId: String?
    public var projects: [ProjectStateEntry]

    public init(
        windowFrame: [Double] = [100, 100, 1200, 800],
        sidebarWidth: Double = 200,
        activeProjectId: String? = nil,
        projects: [ProjectStateEntry] = []
    ) {
        self.windowFrame = windowFrame
        self.sidebarWidth = sidebarWidth
        self.activeProjectId = activeProjectId
        self.projects = projects
    }

    public struct ProjectStateEntry: Codable {
        public var id: String
        public var configPath: String?
        public var layout: String?
        public var focusedSessionId: String?

        public init(id: String, configPath: String? = nil, layout: String? = nil, focusedSessionId: String? = nil) {
            self.id = id
            self.configPath = configPath
            self.layout = layout
            self.focusedSessionId = focusedSessionId
        }
    }
}
