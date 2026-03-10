import Foundation
import Observation

@Observable
public final class ProjectStore {
    public var projects: [Project] = []
    public var activeProjectId: UUID?
    public var focusedSessionId: UUID?

    private let configParser = ConfigParser()

    public init() {}

    /// The currently active project.
    public var activeProject: Project? {
        guard let id = activeProjectId else { return projects.first }
        return projects.first { $0.id == id }
    }

    // MARK: - CRUD

    /// Add a project.
    public func addProject(_ project: Project) {
        projects.append(project)
        if activeProjectId == nil {
            activeProjectId = project.id
        }
    }

    /// Remove a project by ID.
    public func removeProject(id: UUID) {
        projects.removeAll { $0.id == id }
        if activeProjectId == id {
            activeProjectId = projects.first?.id
        }
    }

    /// Set the active project.
    public func setActiveProject(id: UUID) {
        guard projects.contains(where: { $0.id == id }) else { return }
        activeProjectId = id
    }

    /// Set active project by index (1-based, for Cmd+1-9).
    public func setActiveProject(index: Int) {
        let idx = index - 1
        guard idx >= 0, idx < projects.count else { return }
        activeProjectId = projects[idx].id
    }

    // MARK: - Config Loading

    /// Load a project from a cosmodrome.yml file.
    public func loadProject(configPath: String) throws -> Project {
        let config = try configParser.parseProjectConfig(at: configPath)
        let rootPath = (configPath as NSString).deletingLastPathComponent
        let project = configParser.createProject(from: config, rootPath: rootPath)
        addProject(project)
        return project
    }

    // MARK: - Agent Queries

    /// All sessions across all projects that need attention.
    public var sessionsNeedingAttention: [(project: Project, session: Session)] {
        projects.flatMap { project in
            project.sessions
                .filter { $0.agentState == .needsInput || $0.agentState == .error }
                .map { (project: project, session: $0) }
        }
    }

    /// Find the next session needing input after the given session.
    public func nextSessionNeedingInput(after currentSessionId: UUID?) -> (project: Project, session: Session)? {
        let attention = sessionsNeedingAttention
        guard !attention.isEmpty else { return nil }

        if let currentId = currentSessionId,
           let currentIdx = attention.firstIndex(where: { $0.session.id == currentId }) {
            let nextIdx = (currentIdx + 1) % attention.count
            return attention[nextIdx]
        }

        return attention.first
    }
}
