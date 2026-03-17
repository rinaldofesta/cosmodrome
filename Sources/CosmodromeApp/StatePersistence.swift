import AppKit
import Core
import Foundation

/// Handles saving and restoring app state between launches.
enum StatePersistence {
    private static let configParser = ConfigParser()

    static var stateDir: String {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Cosmodrome").path
    }

    static var statePath: String {
        (stateDir as NSString).appendingPathComponent("state.yml")
    }

    static var scrollbackDir: String {
        (stateDir as NSString).appendingPathComponent("scrollback")
    }

    /// Save current app state including session definitions and scrollback.
    static func save(
        window: NSWindow?,
        projectStore: ProjectStore,
        sidebarWidth: CGFloat = 200,
        fontSize: CGFloat? = nil
    ) {
        // Ensure scrollback directory exists
        try? FileManager.default.createDirectory(
            atPath: scrollbackDir,
            withIntermediateDirectories: true
        )

        var projectEntries: [AppState.ProjectStateEntry] = []
        for project in projectStore.projects {
            var sessionEntries: [AppState.SessionStateEntry] = []
            for session in project.sessions {
                var scrollbackFile: String?

                // Save scrollback content for running sessions
                if let backend = session.backend {
                    let filename = "\(session.id.uuidString).txt"
                    let path = (scrollbackDir as NSString).appendingPathComponent(filename)
                    let content = extractScrollback(from: backend)
                    if !content.isEmpty {
                        try? content.write(toFile: path, atomically: true, encoding: .utf8)
                        scrollbackFile = filename
                    }
                }

                sessionEntries.append(AppState.SessionStateEntry(
                    id: session.id.uuidString,
                    name: session.name,
                    command: session.command,
                    arguments: session.arguments.isEmpty ? nil : session.arguments,
                    cwd: session.cwd,
                    isAgent: session.isAgent ? true : nil,
                    agentType: session.agentType,
                    scrollbackFile: scrollbackFile,
                    isOrphaned: session.isOrphaned ? true : nil,
                    source: session.source != .manual ? session.source : nil
                ))
            }

            projectEntries.append(AppState.ProjectStateEntry(
                id: project.id.uuidString,
                name: project.name,
                color: project.color,
                rootPath: project.rootPath,
                configPath: project.rootPath.map { ($0 as NSString).appendingPathComponent("cosmodrome.yml") },
                focusedSessionId: projectStore.focusedSessionId?.uuidString,
                sessions: sessionEntries.isEmpty ? nil : sessionEntries
            ))
        }

        let frame = window?.frame ?? NSRect(x: 100, y: 100, width: 1200, height: 800)
        let zoomed = window?.isZoomed ?? false
        let state = AppState(
            windowFrame: [
                Double(frame.origin.x),
                Double(frame.origin.y),
                Double(frame.width),
                Double(frame.height),
            ],
            windowZoomed: zoomed,
            fontSize: fontSize.map { Double($0) },
            sidebarWidth: Double(sidebarWidth),
            activeProjectId: projectStore.activeProjectId?.uuidString,
            projects: projectEntries
        )

        do {
            try configParser.saveAppState(state, to: statePath)
        } catch {
            FileHandle.standardError.write("[Cosmodrome] Failed to save app state: \(error)\n".data(using: .utf8)!)
        }
    }

    /// Load saved app state.
    static func load() -> AppState? {
        do {
            let state = try configParser.loadAppState(at: statePath)
            return state.projects.isEmpty ? nil : state
        } catch {
            return nil
        }
    }

    /// Restore projects and sessions from saved state.
    /// Returns restored projects and the active project ID.
    static func restoreProjects(from state: AppState) -> (projects: [Project], activeId: UUID?) {
        var projects: [Project] = []
        var activeId: UUID?

        if let aid = state.activeProjectId {
            activeId = UUID(uuidString: aid)
        }

        for entry in state.projects {
            guard let projectId = UUID(uuidString: entry.id) else { continue }

            let project = Project(
                id: projectId,
                name: entry.name ?? "Untitled",
                color: entry.color ?? "#4A90D9",
                rootPath: entry.rootPath
            )

            if let sessionEntries = entry.sessions {
                project.sessions = sessionEntries.compactMap { se in
                    // Drop orphaned sessions — they only existed to let a running
                    // process finish; after restart that process is gone.
                    if se.isOrphaned == true { return nil }
                    guard let sid = UUID(uuidString: se.id) else { return nil }
                    let s = Session(
                        id: sid,
                        name: se.name,
                        command: se.command,
                        arguments: se.arguments ?? [],
                        cwd: se.cwd,
                        isAgent: se.isAgent ?? false,
                        agentType: se.agentType
                    )
                    s.source = se.source ?? .manual
                    return s
                }
            }

            projects.append(project)
        }

        return (projects, activeId)
    }

    /// Read scrollback content for a session.
    static func loadScrollback(for sessionId: UUID) -> String? {
        let path = (scrollbackDir as NSString).appendingPathComponent("\(sessionId.uuidString).txt")
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Clean up scrollback files for sessions that no longer exist.
    static func cleanupScrollback(activeSessionIds: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: scrollbackDir) else { return }
        for file in files where file.hasSuffix(".txt") {
            let idStr = String(file.dropLast(4)) // remove .txt
            if let id = UUID(uuidString: idStr), !activeSessionIds.contains(id) {
                try? FileManager.default.removeItem(
                    atPath: (scrollbackDir as NSString).appendingPathComponent(file)
                )
            }
        }
    }

    // MARK: - Private

    /// Extract visible + scrollback text from a backend.
    private static func extractScrollback(from backend: TerminalBackend) -> String {
        backend.lock()
        defer { backend.unlock() }

        var lines: [String] = []
        let totalRows = backend.rows
        for row in 0..<totalRows {
            var line = ""
            for col in 0..<backend.cols {
                let cell = backend.cell(row: row, col: col)
                let cp = cell.codepoint
                if cp >= 32 && cp < 0x110000 {
                    if let scalar = Unicode.Scalar(cp) {
                        line.append(Character(scalar))
                    } else {
                        line.append(" ")
                    }
                } else {
                    line.append(" ")
                }
            }
            // Trim trailing spaces
            while line.hasSuffix(" ") { line.removeLast() }
            lines.append(line)
        }

        // Remove trailing empty lines
        while lines.last?.isEmpty == true { lines.removeLast() }

        return lines.joined(separator: "\n")
    }
}
