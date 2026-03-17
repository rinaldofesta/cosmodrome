import XCTest
@testable import Core

final class BufferStateScannerTests: XCTestCase {

    // MARK: - Claude Code Detection

    func testSpinnerDetectsWorking() {
        let rows = [
            "Some code output here",
            "⠋ Processing files...",
        ]
        let result = BufferStateScanner.scan(rows: rows, agentType: "claude")
        XCTAssertEqual(result.state, .working)
        XCTAssertEqual(result.confidence, .high)
    }

    func testDifferentSpinnerCharsDetectWorking() {
        // ● is intentionally excluded — it appears in Claude Code's status bar
        // as an effort indicator (e.g. "● high") and causes false positives.
        for spinner in ["⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"] {
            let rows = ["\(spinner) Working on task..."]
            let result = BufferStateScanner.scan(rows: rows, agentType: "claude")
            XCTAssertEqual(result.state, .working, "Spinner '\(spinner)' should detect working")
            XCTAssertEqual(result.confidence, .high)
        }
    }

    func testBulletDoesNotFalsePositiveWorking() {
        // ● in status bar (effort indicator) should NOT trigger working state
        let rows = [
            "user@host  /path  Opus 4.6 | ctx: 89%   ● high",
            "> ",
        ]
        let result = BufferStateScanner.scan(rows: rows, agentType: "claude")
        XCTAssertNotEqual(result.state, .working, "● effort indicator should not trigger working")
    }

    func testStatusBarIdlePromptInactive() {
        let rows = [
            "",
            "user@host  /path  Opus 4.6 | ctx: 89%   ● high",
            "⏸ plan mode on (shift+tab to cycle)",
            "> ",
        ]
        let result = BufferStateScanner.scan(rows: rows, agentType: "claude")
        XCTAssertEqual(result.state, .inactive)
        XCTAssertEqual(result.confidence, .high)
    }

    func testStatusBarWithErrorMediumConfidence() {
        let rows = [
            "Error: permission denied",
            "user@host  Opus 4.6 | ctx: 50%",
        ]
        let result = BufferStateScanner.scan(rows: rows, agentType: "claude")
        XCTAssertEqual(result.state, .error)
        XCTAssertEqual(result.confidence, .medium)
    }

    func testStatusBarAloneInactiveMedium() {
        let rows = [
            "Some content",
            "user@host  /path  Sonnet 4.6 | ctx: 45%",
        ]
        let result = BufferStateScanner.scan(rows: rows, agentType: "claude")
        XCTAssertEqual(result.state, .inactive)
        XCTAssertEqual(result.confidence, .medium)
    }

    func testNoSignaturesNoneConfidence() {
        let rows = [
            "$ ls -la",
            "total 42",
            "drwxr-xr-x  5 user  staff  160 Mar 13 10:00 .",
        ]
        let result = BufferStateScanner.scan(rows: rows, agentType: "claude")
        XCTAssertEqual(result.confidence, .none)
    }

    func testSpinnerWithStatusBar() {
        // Spinner + status bar = working (spinner takes precedence)
        let rows = [
            "⠋ Reading file...",
            "user@host  Opus 4.6 | ctx: 70%",
        ]
        let result = BufferStateScanner.scan(rows: rows, agentType: "claude")
        XCTAssertEqual(result.state, .working)
        XCTAssertEqual(result.confidence, .high)
    }

    func testSpinnerBeatsErrorInBuffer() {
        // Spinner visible + error text in body → .working wins
        let rows = [
            "Error: something went wrong earlier",
            "⠙ Fixing the issue...",
            "user@host  Opus 4.6 | ctx: 80%",
        ]
        let result = BufferStateScanner.scan(rows: rows, agentType: "claude")
        XCTAssertEqual(result.state, .working)
        XCTAssertEqual(result.confidence, .high)
    }

    // MARK: - Non-Claude Agents

    func testNonClaudeReturnsNone() {
        let rows = ["aider> ", "some output"]
        let result = BufferStateScanner.scan(rows: rows, agentType: "aider")
        XCTAssertEqual(result.confidence, .none)
    }

    func testNilAgentTypeReturnsNone() {
        let rows = ["⠋ spinner visible"]
        let result = BufferStateScanner.scan(rows: rows, agentType: nil)
        XCTAssertEqual(result.confidence, .none)
    }

    // MARK: - Edge Cases

    func testEmptyRowsNoneConfidence() {
        let result = BufferStateScanner.scan(rows: [], agentType: "claude")
        XCTAssertEqual(result.confidence, .none)
    }

    func testShiftTabDetectsStatusBar() {
        // "shift+tab" alone is enough to identify Claude Code status bar
        let rows = [
            "⏸ accept edits on (shift+tab to cycle)",
            "> ",
        ]
        let result = BufferStateScanner.scan(rows: rows, agentType: "claude")
        XCTAssertEqual(result.state, .inactive)
        XCTAssertEqual(result.confidence, .high)
    }

    func testCtxPercentDetectsStatusBar() {
        let rows = ["ctx: 95%"]
        let result = BufferStateScanner.scan(rows: rows, agentType: "claude")
        XCTAssertEqual(result.state, .inactive)
        XCTAssertEqual(result.confidence, .medium)
    }

    func testCtxCaseInsensitive() {
        // "Ctx:" and "CTX:" should also be recognized
        for prefix in ["ctx:", "Ctx:", "CTX:"] {
            let rows = ["\(prefix) 80%"]
            let result = BufferStateScanner.scan(rows: rows, agentType: "claude")
            XCTAssertEqual(result.confidence, .medium, "\(prefix) should be detected as status bar")
        }
    }
}
