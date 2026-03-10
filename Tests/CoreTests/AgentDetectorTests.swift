import XCTest
@testable import Core

final class AgentDetectorTests: XCTestCase {

    // MARK: - Claude Code Patterns

    func testDetectsNeedsInput() {
        let detector = AgentDetector(agentType: "claude", debounce: 0)
        detector.analyzeText("Do you want to allow this tool?")
        XCTAssertEqual(detector.state, .needsInput)
    }

    func testDetectsYesNo() {
        let detector = AgentDetector(agentType: "claude", debounce: 0)
        detector.analyzeText("Continue? [y/n]")
        XCTAssertEqual(detector.state, .needsInput)
    }

    func testDetectsError() {
        let detector = AgentDetector(agentType: "claude", debounce: 0)
        detector.analyzeText("Error: something failed")
        XCTAssertEqual(detector.state, .error)
    }

    func testDetectsWorkingSpinner() {
        let detector = AgentDetector(agentType: "claude", debounce: 0)
        detector.analyzeText("⠋ Processing...")
        XCTAssertEqual(detector.state, .working)
    }

    func testDetectsWorkingTool() {
        let detector = AgentDetector(agentType: "claude", debounce: 0)
        detector.analyzeText("Read file.swift\nContent follows...")
        XCTAssertEqual(detector.state, .working)
    }

    func testNeedsInputPriority() {
        let detector = AgentDetector(agentType: "claude", debounce: 0)
        detector.analyzeText("Error occurred. Do you want to retry? [y/n]")
        XCTAssertEqual(detector.state, .needsInput)
    }

    func testErrorPriority() {
        let detector = AgentDetector(agentType: "claude", debounce: 0)
        // "failed" matches error, "Bash " matches working, but error has higher priority
        detector.analyzeText("Bash execution failed with error")
        XCTAssertEqual(detector.state, .error)
    }

    func testNoMatchKeepsState() {
        let detector = AgentDetector(agentType: "claude", debounce: 0)
        detector.analyzeText("Hello world")
        XCTAssertEqual(detector.state, .inactive)
    }

    func testReset() {
        let detector = AgentDetector(agentType: "claude", debounce: 0)
        detector.analyzeText("Error occurred")
        XCTAssertEqual(detector.state, .error)
        detector.reset()
        XCTAssertEqual(detector.state, .inactive)
    }

    // MARK: - Generic Patterns

    func testGenericNeedsInput() {
        let detector = AgentDetector(agentType: "unknown", debounce: 0)
        detector.analyzeText("Confirm action? [y/n]")
        XCTAssertEqual(detector.state, .needsInput)
    }

    func testGenericError() {
        let detector = AgentDetector(agentType: "unknown", debounce: 0)
        detector.analyzeText("Command failed")
        XCTAssertEqual(detector.state, .error)
    }

    // MARK: - Debounce

    func testDebounce() {
        let detector = AgentDetector(agentType: "claude", debounce: 10.0)
        detector.analyzeText("Error occurred")
        XCTAssertEqual(detector.state, .error)
        // Second change should be debounced (within 10s)
        detector.analyzeText("⠋ Working now")
        XCTAssertEqual(detector.state, .error) // Still error, debounced
    }

    // MARK: - UnsafeRawBufferPointer API

    func testAnalyzeRawBuffer() {
        let detector = AgentDetector(agentType: "claude", debounce: 0)
        let text = "Error: test failed"
        text.utf8.withContiguousStorageIfAvailable { buffer in
            let raw = UnsafeRawBufferPointer(buffer)
            detector.analyze(lastOutput: raw)
        }
        XCTAssertEqual(detector.state, .error)
    }
}
