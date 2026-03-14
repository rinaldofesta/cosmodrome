import XCTest
@testable import Core

final class ConfigParserTests: XCTestCase {
    let parser = ConfigParser()

    // MARK: - Project Config

    func testParseMinimalProject() throws {
        let yaml = """
        name: "Test Project"
        sessions:
          - name: "Shell"
            command: "zsh"
        """
        let config = try parser.parseProjectConfig(yaml: yaml)
        XCTAssertEqual(config.name, "Test Project")
        XCTAssertEqual(config.sessions.count, 1)
        XCTAssertEqual(config.sessions[0].name, "Shell")
        XCTAssertEqual(config.sessions[0].command, "zsh")
    }

    func testParseFullProject() throws {
        let yaml = """
        name: "API v2"
        color: "#4A90D9"
        layout: grid
        sessions:
          - name: "Claude Code"
            command: "claude"
            agent: true
            agent_type: "claude"
            auto_start: true
          - name: "Dev Server"
            command: "npm"
            args: ["run", "dev"]
            cwd: "./frontend"
            env:
              PORT: "3000"
            auto_start: true
            auto_restart: true
            restart_delay: 2.0
          - name: "Database"
            command: "docker"
            args: ["compose", "up", "postgres"]
            auto_start: true
        """
        let config = try parser.parseProjectConfig(yaml: yaml)
        XCTAssertEqual(config.name, "API v2")
        XCTAssertEqual(config.color, "#4A90D9")
        XCTAssertEqual(config.layout, "grid")
        XCTAssertEqual(config.sessions.count, 3)

        let claude = config.sessions[0]
        XCTAssertEqual(claude.name, "Claude Code")
        XCTAssertEqual(claude.command, "claude")
        XCTAssertEqual(claude.agent, true)
        XCTAssertEqual(claude.agentType, "claude")
        XCTAssertEqual(claude.autoStart, true)

        let dev = config.sessions[1]
        XCTAssertEqual(dev.args, ["run", "dev"])
        XCTAssertEqual(dev.cwd, "./frontend")
        XCTAssertEqual(dev.env?["PORT"], "3000")
        XCTAssertEqual(dev.autoRestart, true)
        XCTAssertEqual(dev.restartDelay, 2.0)

        let db = config.sessions[2]
        XCTAssertEqual(db.args, ["compose", "up", "postgres"])
    }

    func testParseMissingOptionals() throws {
        let yaml = """
        name: "Minimal"
        sessions:
          - name: "Shell"
            command: "bash"
        """
        let config = try parser.parseProjectConfig(yaml: yaml)
        let session = config.sessions[0]
        XCTAssertNil(session.agent)
        XCTAssertNil(session.agentType)
        XCTAssertNil(session.autoStart)
        XCTAssertNil(session.autoRestart)
        XCTAssertNil(session.restartDelay)
        XCTAssertNil(session.cwd)
        XCTAssertNil(session.env)
        XCTAssertNil(session.args)
    }

    func testInvalidYaml() {
        let yaml = "{{invalid yaml"
        XCTAssertThrowsError(try parser.parseProjectConfig(yaml: yaml)) { error in
            XCTAssertTrue(error is ConfigError)
        }
    }

    // MARK: - User Config

    func testParseUserConfig() throws {
        let yaml = """
        font:
          family: "JetBrains Mono"
          size: 14
          lineHeight: 1.2
        theme: "dark"
        window:
          opacity: 0.95
          restore_state: true
        notifications:
          needs_input: true
          error: true
          completed: false
          sound: true
          idle_threshold: 60
        """
        let config = try parser.parseUserConfig(yaml: yaml)
        XCTAssertEqual(config.font?.family, "JetBrains Mono")
        XCTAssertEqual(config.font?.size, 14)
        XCTAssertEqual(config.font?.lineHeight, 1.2)
        XCTAssertEqual(config.theme, "dark")
        XCTAssertEqual(config.window?.opacity, 0.95)
        XCTAssertEqual(config.window?.restoreState, true)
        XCTAssertEqual(config.notifications?.needsInput, true)
        XCTAssertEqual(config.notifications?.error, true)
        XCTAssertEqual(config.notifications?.completed, false)
        XCTAssertEqual(config.notifications?.sound, true)
        XCTAssertEqual(config.notifications?.idleThreshold, 60)
    }

    func testParseNotificationDefaults() throws {
        let yaml = """
        notifications: {}
        """
        let config = try parser.parseUserConfig(yaml: yaml)
        // All fields should get their default values when parsing empty notifications section
        let notif = config.notifications!
        XCTAssertEqual(notif.needsInput, true)
        XCTAssertEqual(notif.error, true)
        XCTAssertEqual(notif.completed, false)
        XCTAssertEqual(notif.sound, false)
        XCTAssertEqual(notif.idleThreshold, 30)
    }

    func testParseEmptyUserConfig() throws {
        let yaml = "{}"
        let config = try parser.parseUserConfig(yaml: yaml)
        XCTAssertNil(config.font)
        XCTAssertNil(config.theme)
    }

    // MARK: - Conversion

    func testCreateProjectFromConfig() {
        let config = ProjectConfig(
            name: "Test",
            color: "#FF0000",
            sessions: [
                SessionConfig(
                    name: "Claude",
                    command: "claude",
                    agent: true,
                    agentType: "claude",
                    autoStart: true
                ),
                SessionConfig(
                    name: "Shell",
                    command: "zsh"
                ),
            ],
            layout: "focus"
        )
        let project = parser.createProject(from: config, rootPath: "/tmp/test")
        XCTAssertEqual(project.name, "Test")
        XCTAssertEqual(project.color, "#FF0000")
        XCTAssertEqual(project.rootPath, "/tmp/test")
        XCTAssertEqual(project.sessions.count, 2)

        let claude = project.sessions[0]
        XCTAssertEqual(claude.name, "Claude")
        XCTAssertEqual(claude.command, "claude")
        XCTAssertEqual(claude.isAgent, true)
        XCTAssertEqual(claude.agentType, "claude")
        XCTAssertEqual(claude.autoStart, true)
        XCTAssertEqual(claude.cwd, "/tmp/test")

        let shell = project.sessions[1]
        XCTAssertEqual(shell.name, "Shell")
        XCTAssertEqual(shell.isAgent, false)
    }

    func testDefaultColor() {
        let config = ProjectConfig(name: "No Color", sessions: [])
        let project = parser.createProject(from: config)
        XCTAssertEqual(project.color, "#4A90D9")
    }
}
