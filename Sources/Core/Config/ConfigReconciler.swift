import Foundation

/// Result of diffing a ProjectConfig against current sessions.
public struct ConfigDiff {
    public let added: [SessionConfig]
    public let removed: [Session]
    public let updated: [(session: Session, config: SessionConfig)]
    public let unchanged: [Session]
}

/// Pure-function reconciler that diffs a ProjectConfig against live sessions.
public struct ConfigReconciler {
    public init() {}

    /// Diff config sessions against current sessions by name.
    ///
    /// Matches sessions by name. Renaming a session in config is treated as
    /// remove + add (new UUID, scrollback lost). A future version could use
    /// a stable `id` field in SessionConfig to track identity across renames.
    ///
    /// - added: config sessions whose name doesn't match any current session
    /// - removed: current sessions with source == .config whose name isn't in config
    /// - updated: matched sessions that are NOT running (config will be applied)
    /// - unchanged: manual sessions, running matched sessions, and anything else
    public func diff(config: ProjectConfig, currentSessions: [Session]) -> ConfigDiff {
        // Dedup config sessions by name — if cosmodrome.yml has two sessions with the
        // same name, only the first is used. Names are the identity key for matching;
        // duplicates would cause unpredictable matching via first(where:).
        var seen = Set<String>()
        let uniqueConfigSessions = config.sessions.filter { seen.insert($0.name).inserted }

        let configNames = Set(uniqueConfigSessions.map(\.name))
        let currentNames = Set(currentSessions.map(\.name))

        let added = uniqueConfigSessions.filter { !currentNames.contains($0.name) }

        let removed = currentSessions.filter {
            $0.source == .config && !configNames.contains($0.name)
        }

        var updated: [(session: Session, config: SessionConfig)] = []
        var unchanged: [Session] = []

        for session in currentSessions {
            // Already handled as removed
            if session.source == .config && !configNames.contains(session.name) { continue }

            if let sc = uniqueConfigSessions.first(where: { $0.name == session.name }) {
                if session.isRunning {
                    unchanged.append(session)
                } else {
                    updated.append((session: session, config: sc))
                }
            } else {
                // Manual session or no matching config — unchanged
                unchanged.append(session)
            }
        }

        return ConfigDiff(added: added, removed: removed, updated: updated, unchanged: unchanged)
    }
}
