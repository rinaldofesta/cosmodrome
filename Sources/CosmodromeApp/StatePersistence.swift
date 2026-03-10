import AppKit
import Core
import Foundation

/// Handles saving and restoring app state between launches.
enum StatePersistence {
    private static let configParser = ConfigParser()

    static var statePath: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Cosmodrome")
        return appSupport.appendingPathComponent("state.yml").path
    }

    /// Save current app state.
    static func save(
        window: NSWindow?,
        projectStore: ProjectStore,
        sidebarWidth: CGFloat = 200
    ) {
        var projectEntries: [AppState.ProjectStateEntry] = []
        for project in projectStore.projects {
            projectEntries.append(AppState.ProjectStateEntry(
                id: project.id.uuidString,
                configPath: project.rootPath.map { ($0 as NSString).appendingPathComponent("cosmodrome.yml") },
                layout: nil,
                focusedSessionId: nil
            ))
        }

        let frame = window?.frame ?? NSRect(x: 100, y: 100, width: 1200, height: 800)
        let state = AppState(
            windowFrame: [
                Double(frame.origin.x),
                Double(frame.origin.y),
                Double(frame.width),
                Double(frame.height),
            ],
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
}
