import XCTest
@testable import Core

final class StuckDetectorTests: XCTestCase {

    private let testSessionId = UUID()

    private func makeEvent(_ kind: ActivityEvent.EventKind, ago: TimeInterval = 0) -> ActivityEvent {
        ActivityEvent(
            timestamp: Date().addingTimeInterval(-ago),
            sessionId: testSessionId,
            sessionName: "test",
            kind: kind
        )
    }

    // MARK: - No Stuck Detection

    func testNotStuckWhenInactive() {
        let events = [
            makeEvent(.stateChanged(from: .working, to: .error), ago: 30),
            makeEvent(.stateChanged(from: .error, to: .working), ago: 25),
            makeEvent(.stateChanged(from: .working, to: .error), ago: 20),
            makeEvent(.stateChanged(from: .error, to: .working), ago: 15),
            makeEvent(.stateChanged(from: .working, to: .error), ago: 10),
        ]
        let result = StuckDetector.detect(events: events, currentState: .inactive)
        XCTAssertNil(result, "Should not detect stuck when inactive")
    }

    func testNotStuckWithFewErrors() {
        let events = [
            makeEvent(.stateChanged(from: .working, to: .error), ago: 30),
            makeEvent(.stateChanged(from: .error, to: .working), ago: 25),
        ]
        let result = StuckDetector.detect(events: events, currentState: .working)
        XCTAssertNil(result, "Should not detect stuck with < 3 retries")
    }

    func testNotStuckWithNoEvents() {
        let result = StuckDetector.detect(events: [], currentState: .working)
        XCTAssertNil(result)
    }

    // MARK: - Stuck Detection

    func testDetectsStuckOnRetryCycle() {
        // Simulate 4 error→working→error cycles
        let events = [
            makeEvent(.error(message: "compile error"), ago: 120),
            makeEvent(.stateChanged(from: .inactive, to: .working), ago: 115),
            makeEvent(.stateChanged(from: .working, to: .error), ago: 100),
            makeEvent(.stateChanged(from: .error, to: .working), ago: 90),
            makeEvent(.stateChanged(from: .working, to: .error), ago: 80),
            makeEvent(.stateChanged(from: .error, to: .working), ago: 70),
            makeEvent(.stateChanged(from: .working, to: .error), ago: 60),
            makeEvent(.stateChanged(from: .error, to: .working), ago: 50),
            makeEvent(.stateChanged(from: .working, to: .error), ago: 40),
            makeEvent(.error(message: "compile error"), ago: 35),
        ]
        let result = StuckDetector.detect(events: events, currentState: .error)
        XCTAssertNotNil(result, "Should detect stuck loop")
        if let result {
            XCTAssertGreaterThanOrEqual(result.retryCount, 3)
        }
    }

    func testStuckPatternIdentification() {
        let events = [
            makeEvent(.error(message: "compile error in auth.ts"), ago: 60),
            makeEvent(.stateChanged(from: .working, to: .error), ago: 55),
            makeEvent(.stateChanged(from: .error, to: .working), ago: 50),
            makeEvent(.stateChanged(from: .working, to: .error), ago: 45),
            makeEvent(.stateChanged(from: .error, to: .working), ago: 40),
            makeEvent(.stateChanged(from: .working, to: .error), ago: 35),
            makeEvent(.stateChanged(from: .error, to: .working), ago: 30),
            makeEvent(.stateChanged(from: .working, to: .error), ago: 25),
            makeEvent(.error(message: "compile error in auth.ts"), ago: 20),
        ]
        let result = StuckDetector.detect(events: events, currentState: .error)
        if let result {
            XCTAssert(result.pattern?.contains("compile") == true,
                      "Should identify compile pattern: \(result.pattern ?? "nil")")
        }
    }

    // MARK: - Early Detection

    func testEarlyDetectionWithIdenticalErrors() {
        // 2 error→working→error cycles with the exact same error message
        let events = [
            makeEvent(.error(message: "type error in foo.ts"), ago: 60),
            makeEvent(.stateChanged(from: .inactive, to: .working), ago: 55),
            makeEvent(.stateChanged(from: .working, to: .error), ago: 50),
            makeEvent(.error(message: "type error in foo.ts"), ago: 48),
            makeEvent(.stateChanged(from: .error, to: .working), ago: 45),
            makeEvent(.stateChanged(from: .working, to: .error), ago: 40),
            makeEvent(.error(message: "type error in foo.ts"), ago: 38),
        ]
        let result = StuckDetector.detect(events: events, currentState: .error, enableEarlyDetection: true)
        XCTAssertNotNil(result, "Should detect stuck early at 2 cycles with identical errors")
        if let result {
            XCTAssertTrue(result.isEarlyDetection, "Should be flagged as early detection")
            XCTAssertEqual(result.retryCount, 2)
        }
    }

    func testNoEarlyDetectionWithDifferentErrors() {
        // 2 error→working→error cycles with different error messages
        let events = [
            makeEvent(.error(message: "type error in foo.ts"), ago: 60),
            makeEvent(.stateChanged(from: .inactive, to: .working), ago: 55),
            makeEvent(.stateChanged(from: .working, to: .error), ago: 50),
            makeEvent(.error(message: "syntax error in bar.ts"), ago: 48),
            makeEvent(.stateChanged(from: .error, to: .working), ago: 45),
            makeEvent(.stateChanged(from: .working, to: .error), ago: 40),
            makeEvent(.error(message: "missing import in baz.ts"), ago: 38),
        ]
        let result = StuckDetector.detect(events: events, currentState: .error, enableEarlyDetection: true)
        XCTAssertNil(result, "Should NOT detect stuck with different error messages at 2 cycles")
    }

    func testEarlyDetectionDisabledByDefault() {
        // 2 error→working→error cycles with identical errors but no enableEarlyDetection flag
        let events = [
            makeEvent(.error(message: "type error in foo.ts"), ago: 60),
            makeEvent(.stateChanged(from: .inactive, to: .working), ago: 55),
            makeEvent(.stateChanged(from: .working, to: .error), ago: 50),
            makeEvent(.error(message: "type error in foo.ts"), ago: 48),
            makeEvent(.stateChanged(from: .error, to: .working), ago: 45),
            makeEvent(.stateChanged(from: .working, to: .error), ago: 40),
            makeEvent(.error(message: "type error in foo.ts"), ago: 38),
        ]
        let result = StuckDetector.detect(events: events, currentState: .error)
        XCTAssertNil(result, "Should NOT detect stuck at 2 cycles when enableEarlyDetection is false (default)")
    }

    // MARK: - Event Grouping

    func testEventGroupingTaskBlock() {
        let events = [
            makeEvent(.taskStarted, ago: 100),
            makeEvent(.fileWrite(path: "a.ts", added: 5, removed: 0), ago: 80),
            makeEvent(.fileWrite(path: "b.ts", added: 10, removed: 2), ago: 60),
            makeEvent(.commandRun(command: "npm test"), ago: 40),
            makeEvent(.taskCompleted(duration: 100), ago: 10),
        ]
        let grouped = ActivityLog.groupEvents(events)
        XCTAssertEqual(grouped.count, 1, "Should group into single task block")
        if case .group(let group) = grouped.first {
            XCTAssertEqual(group.kind, .task)
            XCTAssert(group.header.contains("2 files"), "Should mention files: \(group.header)")
        } else {
            XCTFail("Expected a group")
        }
    }

    func testEventGroupingFileCluster() {
        // 4 file writes within 30 seconds
        let events = [
            makeEvent(.fileWrite(path: "src/a.ts", added: 1, removed: 0), ago: 30),
            makeEvent(.fileWrite(path: "src/b.ts", added: 2, removed: 0), ago: 25),
            makeEvent(.fileWrite(path: "src/c.ts", added: 3, removed: 0), ago: 20),
            makeEvent(.fileWrite(path: "src/d.ts", added: 4, removed: 0), ago: 15),
        ]
        let grouped = ActivityLog.groupEvents(events)
        XCTAssertEqual(grouped.count, 1, "Should group into file cluster")
        if case .group(let group) = grouped.first {
            XCTAssertEqual(group.kind, .fileCluster)
            XCTAssert(group.header.contains("4 files"), "Should mention count: \(group.header)")
        } else {
            XCTFail("Expected a group")
        }
    }

    func testEventGroupingStateFlicker() {
        let events = [
            makeEvent(.stateChanged(from: .inactive, to: .working), ago: 30),
            makeEvent(.stateChanged(from: .working, to: .error), ago: 25),
            makeEvent(.stateChanged(from: .error, to: .working), ago: 20),
            makeEvent(.stateChanged(from: .working, to: .inactive), ago: 15),
        ]
        let grouped = ActivityLog.groupEvents(events)
        XCTAssertEqual(grouped.count, 1, "Should group into state flicker")
        if case .group(let group) = grouped.first {
            XCTAssertEqual(group.kind, .stateFlicker)
        } else {
            XCTFail("Expected a group")
        }
    }

    func testMixedEventsPartialGrouping() {
        let events = [
            makeEvent(.commandRun(command: "git status"), ago: 100),
            makeEvent(.fileWrite(path: "a.ts", added: 1, removed: 0), ago: 80),
            makeEvent(.fileWrite(path: "b.ts", added: 2, removed: 0), ago: 75),
            makeEvent(.fileWrite(path: "c.ts", added: 3, removed: 0), ago: 70),
            makeEvent(.commandRun(command: "npm test"), ago: 50),
        ]
        let grouped = ActivityLog.groupEvents(events)
        // commandRun (single) + fileCluster (group) + commandRun (single)
        XCTAssertEqual(grouped.count, 3, "Should be 3 items: single + group + single")
    }
}
