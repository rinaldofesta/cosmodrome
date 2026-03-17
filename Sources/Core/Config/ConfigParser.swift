import Foundation
import Yams

public enum ConfigError: Error {
    case fileNotFound(String)
    case parseError(String)
    case invalidFormat(String)
}

public struct ConfigParser {
    public init() {}

    // MARK: - Project Config

    /// Parse a cosmodrome.yml file into a ProjectConfig.
    public func parseProjectConfig(at path: String) throws -> ProjectConfig {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw ConfigError.fileNotFound(path)
        }
        let data = try Data(contentsOf: url)
        return try parseProjectConfig(from: data)
    }

    /// Parse YAML data into a ProjectConfig.
    public func parseProjectConfig(from data: Data) throws -> ProjectConfig {
        guard let yaml = String(data: data, encoding: .utf8) else {
            throw ConfigError.invalidFormat("Cannot decode YAML as UTF-8")
        }
        return try parseProjectConfig(yaml: yaml)
    }

    /// Parse a YAML string into a ProjectConfig.
    public func parseProjectConfig(yaml: String) throws -> ProjectConfig {
        let decoder = YAMLDecoder()
        do {
            return try decoder.decode(ProjectConfig.self, from: yaml)
        } catch {
            throw ConfigError.parseError("Failed to parse project config: \(error.localizedDescription)")
        }
    }

    // MARK: - User Config

    /// Parse user config from ~/.config/cosmodrome/config.yml.
    public func parseUserConfig(at path: String) throws -> UserConfig {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ConfigError.fileNotFound(path)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let yaml = String(data: data, encoding: .utf8) else {
            throw ConfigError.invalidFormat("Cannot decode YAML as UTF-8")
        }
        let decoder = YAMLDecoder()
        do {
            return try decoder.decode(UserConfig.self, from: yaml)
        } catch {
            throw ConfigError.parseError("Failed to parse user config: \(error.localizedDescription)")
        }
    }

    /// Parse a YAML string into a UserConfig.
    public func parseUserConfig(yaml: String) throws -> UserConfig {
        let decoder = YAMLDecoder()
        do {
            return try decoder.decode(UserConfig.self, from: yaml)
        } catch {
            throw ConfigError.parseError("Failed to parse user config: \(error.localizedDescription)")
        }
    }

    // MARK: - Theme

    /// Parse a theme YAML file.
    public func parseTheme(at path: String) throws -> Theme {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ConfigError.fileNotFound(path)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let yaml = String(data: data, encoding: .utf8) else {
            throw ConfigError.invalidFormat("Cannot decode YAML as UTF-8")
        }
        return try parseTheme(yaml: yaml)
    }

    /// Parse a theme from YAML string.
    public func parseTheme(yaml: String) throws -> Theme {
        let decoder = YAMLDecoder()
        do {
            return try decoder.decode(Theme.self, from: yaml)
        } catch {
            throw ConfigError.parseError("Failed to parse theme: \(error.localizedDescription)")
        }
    }

    // MARK: - App State

    /// Load app state from disk.
    public func loadAppState(at path: String) throws -> AppState {
        guard FileManager.default.fileExists(atPath: path) else {
            return AppState() // Return defaults if no state file
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let yaml = String(data: data, encoding: .utf8) else {
            throw ConfigError.invalidFormat("Cannot decode YAML as UTF-8")
        }
        let decoder = YAMLDecoder()
        return try decoder.decode(AppState.self, from: yaml)
    }

    /// Save app state to disk.
    public func saveAppState(_ state: AppState, to path: String) throws {
        let encoder = YAMLEncoder()
        let yaml = try encoder.encode(state)

        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Conversion

    /// Convert a ProjectConfig to a Project model.
    public func createProject(from config: ProjectConfig, rootPath: String? = nil) -> Project {
        let project = Project(
            name: config.name,
            color: config.color ?? "#4A90D9",
            rootPath: rootPath
        )

        project.sessions = config.sessions.map { sessionConfig in
            createSession(from: sessionConfig, rootPath: rootPath ?? ".")
        }

        return project
    }

    public func createSession(from config: SessionConfig, rootPath: String) -> Session {
        let session = Session(
            name: config.name,
            command: config.command,
            arguments: config.args ?? [],
            cwd: config.cwd ?? rootPath,
            environment: config.env ?? [:],
            autoStart: config.autoStart ?? false,
            autoRestart: config.autoRestart ?? false,
            restartDelay: config.restartDelay ?? 1.0,
            isAgent: config.agent ?? false,
            agentType: config.agentType
        )
        session.source = .config
        return session
    }
}
