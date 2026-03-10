import XCTest
@testable import Core

final class GitWorktreeTests: XCTestCase {

    func testIsGitRepoPositive() {
        // /tmp is not a git repo, but the test project itself might be
        // This test verifies the function works without crashing
        let result = GitWorktree.isGitRepo(at: "/tmp")
        // /tmp is typically not a git repo
        XCTAssertFalse(result)
    }

    func testCurrentBranchNonRepo() {
        let branch = GitWorktree.currentBranch(in: "/tmp")
        XCTAssertNil(branch)
    }

    func testListNonRepo() {
        let worktrees = GitWorktree.list(in: "/tmp")
        XCTAssertTrue(worktrees.isEmpty)
    }

    func testShortStatusNonRepo() {
        let status = GitWorktree.shortStatus(in: "/tmp")
        XCTAssertNil(status)
    }

    func testDetectAgentType() {
        XCTAssertEqual(AgentPatterns.detectType(from: "claude"), "claude")
        XCTAssertEqual(AgentPatterns.detectType(from: "/usr/local/bin/claude"), "claude")
        XCTAssertEqual(AgentPatterns.detectType(from: "aider"), "aider")
        XCTAssertEqual(AgentPatterns.detectType(from: "codex"), "codex")
        XCTAssertEqual(AgentPatterns.detectType(from: "gemini"), "gemini")
        XCTAssertNil(AgentPatterns.detectType(from: "zsh"))
        XCTAssertNil(AgentPatterns.detectType(from: "npm"))
    }

    func testKnownAgentTypes() {
        XCTAssertTrue(AgentPatterns.knownTypes.contains("claude"))
        XCTAssertTrue(AgentPatterns.knownTypes.contains("aider"))
        XCTAssertTrue(AgentPatterns.knownTypes.contains("codex"))
        XCTAssertTrue(AgentPatterns.knownTypes.contains("gemini"))
    }
}
