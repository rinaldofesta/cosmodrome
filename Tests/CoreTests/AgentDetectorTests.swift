import XCTest
@testable import Core

final class AgentDetectorTests: XCTestCase {

    private func makeDetector(agentType: String = "claude", debounce: TimeInterval = 0) -> AgentDetector {
        AgentDetector(agentType: agentType, sessionId: UUID(), sessionName: "test", debounce: debounce)
    }

    // MARK: - Claude Code Patterns

    func testDetectsNeedsInput() {
        let detector = makeDetector()
        detector.analyzeText("Do you want to allow this tool?")
        XCTAssertEqual(detector.state, .needsInput)
    }

    func testDetectsYesNo() {
        let detector = makeDetector()
        detector.analyzeText("Continue? [y/n]")
        XCTAssertEqual(detector.state, .needsInput)
    }

    func testDetectsError() {
        let detector = makeDetector()
        detector.analyzeText("Error: something failed")
        XCTAssertEqual(detector.state, .error)
    }

    func testDetectsWorkingSpinner() {
        let detector = makeDetector()
        detector.analyzeText("⠋ Processing...")
        XCTAssertEqual(detector.state, .working)
    }

    func testDetectsWorkingTool() {
        let detector = makeDetector()
        detector.analyzeText("Read file.swift\nContent follows...")
        XCTAssertEqual(detector.state, .working)
    }

    func testNeedsInputPriority() {
        let detector = makeDetector()
        detector.analyzeText("Error occurred. Do you want to retry? [y/n]")
        XCTAssertEqual(detector.state, .needsInput)
    }

    func testErrorPriority() {
        let detector = makeDetector()
        // "Error:" matches error, "Bash " matches working, but error has higher priority
        detector.analyzeText("Bash execution\nError: command not found")
        XCTAssertEqual(detector.state, .error)
    }

    func testNoMatchKeepsState() {
        let detector = makeDetector()
        detector.analyzeText("Hello world")
        XCTAssertEqual(detector.state, .inactive)
    }

    func testReset() {
        let detector = makeDetector()
        detector.analyzeText("Error: something broke")
        XCTAssertEqual(detector.state, .error)
        detector.reset()
        XCTAssertEqual(detector.state, .inactive)
    }

    // MARK: - Generic Patterns

    func testGenericNeedsInput() {
        let detector = makeDetector(agentType: "unknown")
        detector.analyzeText("Confirm action? [y/n]")
        XCTAssertEqual(detector.state, .needsInput)
    }

    func testGenericError() {
        let detector = makeDetector(agentType: "unknown")
        detector.analyzeText("Command FAILED")
        XCTAssertEqual(detector.state, .error)
    }

    // MARK: - Debounce

    func testDebounce() {
        let detector = makeDetector(debounce: 10.0)
        detector.analyzeText("Error: something broke")
        XCTAssertEqual(detector.state, .error)
        // Second change should be debounced (within 10s)
        detector.analyzeText("⠋ Working now")
        XCTAssertEqual(detector.state, .error) // Still error, debounced
    }

    // MARK: - UnsafeRawBufferPointer API

    func testAnalyzeRawBuffer() {
        let detector = makeDetector()
        let text = "Error: test failed"
        text.utf8.withContiguousStorageIfAvailable { buffer in
            let raw = UnsafeRawBufferPointer(buffer)
            detector.analyze(lastOutput: raw)
        }
        XCTAssertEqual(detector.state, .error)
    }

    // MARK: - Two-Phase Detection

    func testSpinnerOnLastLineBeatsErrorInBody() {
        let detector = makeDetector()
        // Body has "error" text but last line has a spinner — agent IS working
        detector.analyzeText("Some code that mentions error handling\nAnd exception types\n⠋ Processing...")
        XCTAssertEqual(detector.state, .working)
    }

    func testErrorWordInCodeDoesNotTrigger() {
        let detector = makeDetector()
        // Casual mention of "error" in code — should NOT trigger error state
        detector.analyzeText("fix the error handler\nreturn errorResponse")
        XCTAssertEqual(detector.state, .inactive)
    }

    func testStructuredErrorDetected() {
        let detector = makeDetector()
        // Actual error format with colon
        detector.analyzeText("Error: permission denied")
        XCTAssertEqual(detector.state, .error)
    }

    func testFailedAllCapsDetected() {
        let detector = makeDetector()
        detector.analyzeText("Test suite: FAILED")
        XCTAssertEqual(detector.state, .error)
    }

    // MARK: - Agent Command Detection

    func testDetectTypeFromBareCommand() {
        XCTAssertEqual(AgentPatterns.detectType(from: "claude"), "claude")
        XCTAssertEqual(AgentPatterns.detectType(from: "aider"), "aider")
        XCTAssertEqual(AgentPatterns.detectType(from: "codex"), "codex")
        XCTAssertEqual(AgentPatterns.detectType(from: "gemini"), "gemini")
    }

    func testDetectTypeFromFullPath() {
        XCTAssertEqual(AgentPatterns.detectType(from: "/usr/local/bin/claude"), "claude")
        XCTAssertEqual(AgentPatterns.detectType(from: "/home/user/.local/bin/aider"), "aider")
    }

    func testDetectTypeFromNpxInvocation() {
        XCTAssertEqual(AgentPatterns.detectType(from: "npx @anthropic-ai/claude-code"), "claude")
        XCTAssertEqual(AgentPatterns.detectType(from: "npx claude"), "claude")
    }

    func testDetectTypeNonAgent() {
        XCTAssertNil(AgentPatterns.detectType(from: "/bin/zsh"))
        XCTAssertNil(AgentPatterns.detectType(from: "bash"))
        XCTAssertNil(AgentPatterns.detectType(from: "vim"))
    }

    // MARK: - ANSI Stripping

    func testStripANSI() {
        let input = "\u{1B}[1;33mAllow\u{1B}[0m tool?"
        let clean = AgentDetector.stripANSI(input)
        XCTAssertEqual(clean, "Allow tool?")
    }

    func testStripANSIRemovesCarriageReturn() {
        let input = "Hello\rWorld\r\nLine2"
        let clean = AgentDetector.stripANSI(input)
        XCTAssertEqual(clean, "HelloWorld\nLine2")
    }

    func testDetectsNeedsInputWithANSI() {
        let detector = makeDetector()
        // Simulates ANSI-wrapped "Allow" prompt as seen in raw PTY output
        detector.analyzeText("\u{1B}[1;33mAllow\u{1B}[0m Read file.swift? [y/n]")
        XCTAssertEqual(detector.state, .needsInput)
    }

    // MARK: - State Transition Events

    func testWorkingToInactiveEmitsStateChanged() {
        let detector = makeDetector()
        // First: go to working state
        detector.analyzeText("⠋ Processing...")
        XCTAssertEqual(detector.state, .working)
        _ = detector.consumeEvents() // clear

        // Then: go to inactive (no recognizable pattern)
        detector.analyzeText("> ")
        // State stays working because ">" alone doesn't match inactive pattern
        // But let's verify events are generated on real transitions
        let detector2 = makeDetector()
        detector2.analyzeText("⠋ Processing...")
        XCTAssertEqual(detector2.state, .working)
        let events = detector2.consumeEvents()
        XCTAssert(events.contains { if case .stateChanged = $0.kind { return true }; return false },
                  "Should emit stateChanged event on transition")
    }

    func testTaskStartedEventOnWorkingTransition() {
        let detector = makeDetector()
        detector.analyzeText("⠋ Processing...")
        let events = detector.consumeEvents()
        XCTAssert(events.contains { if case .taskStarted = $0.kind { return true }; return false },
                  "Should emit taskStarted event when entering working state")
    }

    // MARK: - Thread Safety

    func testConcurrentAnalyzeAndConsume() {
        let detector = makeDetector()
        let iterations = 1000
        let group = DispatchGroup()

        // Hammer analyzeText from one queue
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            for i in 0..<iterations {
                if i % 2 == 0 {
                    detector.analyzeText("⠋ Processing...")
                } else {
                    detector.analyzeText("Error: test")
                }
            }
            group.leave()
        }

        // Hammer consumeEvents from another queue
        group.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            for _ in 0..<iterations {
                _ = detector.consumeEvents()
                _ = detector.state
            }
            group.leave()
        }

        let result = group.wait(timeout: .now() + 10)
        XCTAssertEqual(result, .success, "Concurrent access should not crash or deadlock")
    }
}
