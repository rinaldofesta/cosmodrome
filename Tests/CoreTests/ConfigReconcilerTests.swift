import XCTest
@testable import Core

final class ConfigReconcilerTests: XCTestCase {

    let reconciler = ConfigReconciler()

    // MARK: - Helpers

    private func makeSession(
        name: String,
        command: String = "zsh",
        source: SessionSource = .config,
        isRunning: Bool = false
    ) -> Session {
        let s = Session(name: name, command: command)
        s.source = source
        s.isRunning = isRunning
        return s
    }

    private func makeConfig(sessions: [(name: String, command: String)]) -> ProjectConfig {
        ProjectConfig(
            name: "Test",
            sessions: sessions.map { SessionConfig(name: $0.name, command: $0.command) }
        )
    }

    // MARK: - Tests

    func testNoChanges() {
        let config = makeConfig(sessions: [("Shell", "zsh"), ("Server", "node")])
        let current = [makeSession(name: "Shell"), makeSession(name: "Server")]
        let diff = reconciler.diff(config: config, currentSessions: current)
        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertEqual(diff.updated.count, 2)
        XCTAssertTrue(diff.unchanged.isEmpty)
    }

    func testAddedSessions() {
        let config = makeConfig(sessions: [("Shell", "zsh"), ("New", "bash")])
        let current = [makeSession(name: "Shell")]
        let diff = reconciler.diff(config: config, currentSessions: current)
        XCTAssertEqual(diff.added.count, 1)
        XCTAssertEqual(diff.added[0].name, "New")
        XCTAssertTrue(diff.removed.isEmpty)
    }

    func testRemovedSessions() {
        let config = makeConfig(sessions: [("Shell", "zsh")])
        let current = [makeSession(name: "Shell"), makeSession(name: "Old")]
        let diff = reconciler.diff(config: config, currentSessions: current)
        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertEqual(diff.removed.count, 1)
        XCTAssertEqual(diff.removed[0].name, "Old")
    }

    func testManualSessionsNeverRemoved() {
        let config = makeConfig(sessions: [("Shell", "zsh")])
        let current = [makeSession(name: "Shell"), makeSession(name: "MyTerm", source: .manual)]
        let diff = reconciler.diff(config: config, currentSessions: current)
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertTrue(diff.unchanged.contains(where: { $0.name == "MyTerm" }))
    }

    func testUpdatedStoppedSession() {
        let config = makeConfig(sessions: [("Shell", "bash")])
        let current = [makeSession(name: "Shell", command: "zsh", isRunning: false)]
        let diff = reconciler.diff(config: config, currentSessions: current)
        XCTAssertEqual(diff.updated.count, 1)
        XCTAssertEqual(diff.updated[0].session.name, "Shell")
        XCTAssertEqual(diff.updated[0].config.command, "bash")
    }

    func testRunningSessionNotUpdated() {
        let config = makeConfig(sessions: [("Shell", "bash")])
        let current = [makeSession(name: "Shell", command: "zsh", isRunning: true)]
        let diff = reconciler.diff(config: config, currentSessions: current)
        XCTAssertTrue(diff.updated.isEmpty)
        XCTAssertTrue(diff.unchanged.contains(where: { $0.name == "Shell" }))
    }

    func testMixedDiff() {
        let config = makeConfig(sessions: [
            ("Keep", "zsh"),
            ("Update", "bash"),
            ("New", "fish"),
        ])
        let current = [
            makeSession(name: "Keep", command: "zsh", isRunning: true),
            makeSession(name: "Update", command: "zsh", isRunning: false),
            makeSession(name: "Remove", command: "zsh"),
            makeSession(name: "Manual", command: "zsh", source: .manual),
        ]
        let diff = reconciler.diff(config: config, currentSessions: current)
        XCTAssertEqual(diff.added.count, 1)
        XCTAssertEqual(diff.added[0].name, "New")
        XCTAssertEqual(diff.removed.count, 1)
        XCTAssertEqual(diff.removed[0].name, "Remove")
        XCTAssertEqual(diff.updated.count, 1)
        XCTAssertEqual(diff.updated[0].session.name, "Update")
        XCTAssertEqual(diff.unchanged.count, 2)
    }

    func testEmptyConfig() {
        let config = makeConfig(sessions: [])
        let current = [
            makeSession(name: "A"),
            makeSession(name: "B"),
        ]
        let diff = reconciler.diff(config: config, currentSessions: current)
        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertEqual(diff.removed.count, 2)
        XCTAssertTrue(diff.updated.isEmpty)
    }

    func testEmptyCurrentSessions() {
        let config = makeConfig(sessions: [("A", "zsh"), ("B", "bash")])
        let diff = reconciler.diff(config: config, currentSessions: [])
        XCTAssertEqual(diff.added.count, 2)
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertTrue(diff.updated.isEmpty)
        XCTAssertTrue(diff.unchanged.isEmpty)
    }

    func testDuplicateSessionNamesInConfig() {
        let config = makeConfig(sessions: [("Shell", "zsh"), ("Shell", "bash")])
        let current = [makeSession(name: "Shell", command: "zsh", isRunning: false)]
        let diff = reconciler.diff(config: config, currentSessions: current)
        // Duplicate config entries are deduped — first one wins
        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertEqual(diff.updated.count, 1)
        XCTAssertEqual(diff.updated[0].config.command, "zsh")
    }

    func testDuplicateSessionNamesInConfigNoExisting() {
        let config = makeConfig(sessions: [("Shell", "zsh"), ("Shell", "bash")])
        let diff = reconciler.diff(config: config, currentSessions: [])
        // Only one "Shell" should be added, not two
        XCTAssertEqual(diff.added.count, 1)
        XCTAssertEqual(diff.added[0].command, "zsh")
    }
}
