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
    public var storage: StorageConfig?

    /// Set by the app at startup for global access (e.g., cleanup timer).
    public static var current: UserConfig?

    /// Storage retention in days, with default.
    public var storageRetentionDays: Int {
        storage?.retentionDays ?? 90
    }

    public init(
        font: FontConfig? = nil,
        theme: String? = nil,
        window: WindowConfig? = nil,
        notifications: NotificationConfig? = nil,
        storage: StorageConfig? = nil
    ) {
        self.font = font
        self.theme = theme
        self.window = window
        self.notifications = notifications
        self.storage = storage
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

    public struct StorageConfig: Codable {
        public var enabled: Bool?
        public var retentionDays: Int?

        enum CodingKeys: String, CodingKey {
            case enabled
            case retentionDays = "retention_days"
        }

        public init(enabled: Bool? = nil, retentionDays: Int? = nil) {
            self.enabled = enabled
            self.retentionDays = retentionDays
        }
    }

    public struct NotificationConfig: Codable {
        public var needsInput: Bool
        public var error: Bool
        public var completed: Bool
        public var sound: Bool
        public var idleThreshold: Int  // seconds

        enum CodingKeys: String, CodingKey {
            case needsInput = "needs_input"
            case error
            case completed
            case sound
            case idleThreshold = "idle_threshold"
        }

        public init(
            needsInput: Bool = true,
            error: Bool = true,
            completed: Bool = false,
            sound: Bool = false,
            idleThreshold: Int = 30
        ) {
            self.needsInput = needsInput
            self.error = error
            self.completed = completed
            self.sound = sound
            self.idleThreshold = idleThreshold
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = NotificationConfig()
            needsInput = try container.decodeIfPresent(Bool.self, forKey: .needsInput) ?? defaults.needsInput
            error = try container.decodeIfPresent(Bool.self, forKey: .error) ?? defaults.error
            completed = try container.decodeIfPresent(Bool.self, forKey: .completed) ?? defaults.completed
            sound = try container.decodeIfPresent(Bool.self, forKey: .sound) ?? defaults.sound
            idleThreshold = try container.decodeIfPresent(Int.self, forKey: .idleThreshold) ?? defaults.idleThreshold
        }

        /// Default configuration used when no user config is provided.
        public static let `default` = NotificationConfig()
    }
}

// MARK: - App State (~/.../Cosmodrome/state.yml)

public struct AppState: Codable {
    public var windowFrame: [Double]
    public var windowZoomed: Bool
    public var fontSize: Double?
    public var sidebarWidth: Double
    public var activeProjectId: String?
    public var projects: [ProjectStateEntry]

    public init(
        windowFrame: [Double] = [100, 100, 1200, 800],
        windowZoomed: Bool = false,
        fontSize: Double? = nil,
        sidebarWidth: Double = 200,
        activeProjectId: String? = nil,
        projects: [ProjectStateEntry] = []
    ) {
        self.windowFrame = windowFrame
        self.windowZoomed = windowZoomed
        self.fontSize = fontSize
        self.sidebarWidth = sidebarWidth
        self.activeProjectId = activeProjectId
        self.projects = projects
    }

    public struct ProjectStateEntry: Codable {
        public var id: String
        public var name: String?
        public var color: String?
        public var rootPath: String?
        public var configPath: String?
        public var layout: String?
        public var focusedSessionId: String?
        public var sessions: [SessionStateEntry]?

        public init(
            id: String,
            name: String? = nil,
            color: String? = nil,
            rootPath: String? = nil,
            configPath: String? = nil,
            layout: String? = nil,
            focusedSessionId: String? = nil,
            sessions: [SessionStateEntry]? = nil
        ) {
            self.id = id
            self.name = name
            self.color = color
            self.rootPath = rootPath
            self.configPath = configPath
            self.layout = layout
            self.focusedSessionId = focusedSessionId
            self.sessions = sessions
        }

        enum CodingKeys: String, CodingKey {
            case id, name, color, layout, sessions
            case rootPath = "root_path"
            case configPath = "config_path"
            case focusedSessionId = "focused_session_id"
        }
    }

    public struct SessionStateEntry: Codable {
        public var id: String
        public var name: String
        public var command: String
        public var arguments: [String]?
        public var cwd: String
        public var isAgent: Bool?
        public var agentType: String?
        public var scrollbackFile: String?

        public init(
            id: String,
            name: String,
            command: String,
            arguments: [String]? = nil,
            cwd: String,
            isAgent: Bool? = nil,
            agentType: String? = nil,
            scrollbackFile: String? = nil
        ) {
            self.id = id
            self.name = name
            self.command = command
            self.arguments = arguments
            self.cwd = cwd
            self.isAgent = isAgent
            self.agentType = agentType
            self.scrollbackFile = scrollbackFile
        }

        enum CodingKeys: String, CodingKey {
            case id, name, command, arguments, cwd
            case isAgent = "is_agent"
            case agentType = "agent_type"
            case scrollbackFile = "scrollback_file"
        }
    }
}
