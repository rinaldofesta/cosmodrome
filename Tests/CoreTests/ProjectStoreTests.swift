import XCTest
@testable import Core

final class ProjectStoreTests: XCTestCase {
    func testAddProject() {
        let store = ProjectStore()
        let project = Project(name: "Test")
        store.addProject(project)

        XCTAssertEqual(store.projects.count, 1)
        XCTAssertEqual(store.activeProjectId, project.id)
    }

    func testActiveProjectDefault() {
        let store = ProjectStore()
        let p1 = Project(name: "First")
        let p2 = Project(name: "Second")
        store.addProject(p1)
        store.addProject(p2)

        XCTAssertEqual(store.activeProject?.id, p1.id)
    }

    func testSetActiveProjectByIndex() {
        let store = ProjectStore()
        let p1 = Project(name: "First")
        let p2 = Project(name: "Second")
        store.addProject(p1)
        store.addProject(p2)

        store.setActiveProject(index: 2)
        XCTAssertEqual(store.activeProjectId, p2.id)
    }

    func testSetActiveProjectInvalidIndex() {
        let store = ProjectStore()
        let p1 = Project(name: "First")
        store.addProject(p1)

        store.setActiveProject(index: 5) // out of bounds
        XCTAssertEqual(store.activeProjectId, p1.id) // unchanged
    }

    func testRemoveProject() {
        let store = ProjectStore()
        let p1 = Project(name: "First")
        let p2 = Project(name: "Second")
        store.addProject(p1)
        store.addProject(p2)

        store.setActiveProject(id: p1.id)
        store.removeProject(id: p1.id)

        XCTAssertEqual(store.projects.count, 1)
        XCTAssertEqual(store.activeProjectId, p2.id)
    }

    func testSessionsNeedingAttention() {
        let store = ProjectStore()
        let s1 = Session(name: "Claude", command: "claude", isAgent: true)
        s1.agentState = .needsInput
        let s2 = Session(name: "Shell", command: "zsh")
        let project = Project(name: "Test", sessions: [s1, s2])
        store.addProject(project)

        let attention = store.sessionsNeedingAttention
        XCTAssertEqual(attention.count, 1)
        XCTAssertEqual(attention[0].session.id, s1.id)
    }

    func testNextSessionNeedingInput() {
        let store = ProjectStore()
        let s1 = Session(name: "Agent1", command: "claude", isAgent: true)
        s1.agentState = .needsInput
        let s2 = Session(name: "Agent2", command: "claude", isAgent: true)
        s2.agentState = .error
        let project = Project(name: "Test", sessions: [s1, s2])
        store.addProject(project)

        let next = store.nextSessionNeedingInput(after: s1.id)
        XCTAssertEqual(next?.session.id, s2.id)
    }

    func testAggregateState() {
        let project = Project(name: "Test")
        XCTAssertEqual(project.aggregateState, .inactive)

        let s1 = Session(name: "Agent", command: "claude", isAgent: true)
        s1.agentState = .working
        project.sessions = [s1]
        XCTAssertEqual(project.aggregateState, .working)

        s1.agentState = .needsInput
        XCTAssertEqual(project.aggregateState, .needsInput)

        let s2 = Session(name: "Agent2", command: "claude", isAgent: true)
        s2.agentState = .error
        project.sessions.append(s2)
        XCTAssertEqual(project.aggregateState, .error) // error takes priority
    }
}
