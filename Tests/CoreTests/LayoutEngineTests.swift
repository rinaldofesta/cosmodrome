import XCTest
@testable import Core

final class LayoutEngineTests: XCTestCase {
    let engine = LayoutEngine()

    // MARK: - Auto Grid

    func testAutoGrid1() {
        XCTAssertEqual(engine.autoGrid(count: 1).cols, 1)
        XCTAssertEqual(engine.autoGrid(count: 1).rows, 1)
    }

    func testAutoGrid2() {
        XCTAssertEqual(engine.autoGrid(count: 2).cols, 2)
        XCTAssertEqual(engine.autoGrid(count: 2).rows, 1)
    }

    func testAutoGrid4() {
        XCTAssertEqual(engine.autoGrid(count: 4).cols, 2)
        XCTAssertEqual(engine.autoGrid(count: 4).rows, 2)
    }

    func testAutoGrid6() {
        XCTAssertEqual(engine.autoGrid(count: 6).cols, 3)
        XCTAssertEqual(engine.autoGrid(count: 6).rows, 2)
    }

    func testAutoGrid9() {
        XCTAssertEqual(engine.autoGrid(count: 9).cols, 3)
        XCTAssertEqual(engine.autoGrid(count: 9).rows, 3)
    }

    // MARK: - Grid Layout

    func testGridLayoutSingle() {
        let ids = [UUID()]
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let entries = engine.layout(sessionIds: ids, in: bounds)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].frame.width, 800)
        XCTAssertEqual(entries[0].frame.height, 600)
    }

    func testGridLayoutTwo() {
        let ids = [UUID(), UUID()]
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let entries = engine.layout(sessionIds: ids, in: bounds)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].frame.width, 400, accuracy: 0.1)
        XCTAssertEqual(entries[1].frame.width, 400, accuracy: 0.1)
    }

    func testGridLayoutEmpty() {
        let entries = engine.layout(sessionIds: [], in: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - Focus Layout

    func testFocusLayout() {
        let ids = [UUID(), UUID(), UUID()]
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

        engine.mode = .focus
        engine.focusedSessionId = ids[1]

        let entries = engine.layout(sessionIds: ids, in: bounds)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].sessionId, ids[1])
        XCTAssertEqual(entries[0].frame, bounds)
    }

    func testFocusFallsBackToGrid() {
        let ids = [UUID(), UUID()]
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

        engine.mode = .focus
        engine.focusedSessionId = UUID() // non-existent

        let entries = engine.layout(sessionIds: ids, in: bounds)
        XCTAssertEqual(entries.count, 2) // Falls back to grid
    }

    // MARK: - Toggle

    func testToggleFocus() {
        let id = UUID()
        XCTAssertEqual(engine.mode, .grid)

        engine.toggleFocus(sessionId: id)
        XCTAssertEqual(engine.mode, .focus)
        XCTAssertEqual(engine.focusedSessionId, id)

        engine.toggleFocus(sessionId: id)
        XCTAssertEqual(engine.mode, .grid)
    }

    // MARK: - Hit Testing

    func testSessionAtPoint() {
        let ids = [UUID(), UUID()]
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let entries = engine.layout(sessionIds: ids, in: bounds)

        // Point in first session (left half)
        let hit1 = engine.sessionAt(point: CGPoint(x: 100, y: 300), entries: entries)
        XCTAssertEqual(hit1, ids[0])

        // Point in second session (right half)
        let hit2 = engine.sessionAt(point: CGPoint(x: 600, y: 300), entries: entries)
        XCTAssertEqual(hit2, ids[1])
    }
}
