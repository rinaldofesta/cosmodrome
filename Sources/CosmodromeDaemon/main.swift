import Core
import Foundation

/// Cosmodrome Daemon — headless intelligence engine for AI coding agent observability.
///
/// Runs without a terminal or UI. Collects events from Claude Code hooks,
/// persists to SQLite, and serves interpreted intelligence via a control socket.
///
/// Usage:
///   cosmodrome-daemon              # Start daemon (foreground)
///   cosmodrome-daemon --version    # Print version
///   cosmodrome-daemon --status     # Check if daemon is running

// MARK: - CLI Argument Handling

let args = CommandLine.arguments

if args.contains("--version") {
    print("cosmodrome-daemon 0.3.0")
    exit(0)
}

if args.contains("--status") {
    let socketPath = daemonSocketPath()
    if FileManager.default.fileExists(atPath: socketPath) {
        print("Daemon socket exists at: \(socketPath)")
        // Try connecting to verify it's alive
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("Status: socket exists but cannot open fd")
            exit(1)
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dst, src.baseAddress!, src.count)
                }
            }
        }
        let connected = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(fd)
        if connected == 0 {
            print("Status: running")
            exit(0)
        } else {
            print("Status: stale socket (daemon not running)")
            exit(1)
        }
    } else {
        print("Status: not running (no socket at \(socketPath))")
        exit(1)
    }
}

// MARK: - Daemon Setup

print("[cosmodrome-daemon] Starting...")

// 1. Initialize SQLite event store
let eventStore: EventStore
do {
    eventStore = try EventStore.defaultStore()
    print("[cosmodrome-daemon] Event store initialized")
} catch {
    FileHandle.standardError.write(Data("[cosmodrome-daemon] Failed to initialize event store: \(error)\n".utf8))
    exit(1)
}

// 2. Initialize intelligence modules
let patternLearner = PatternLearner(store: eventStore)
let costPredictor = CostPredictor(store: eventStore)
let workflowMiner = WorkflowMiner(store: eventStore)
let efficiencyTracker = EfficiencyTracker(store: eventStore)
let eventPersister = EventPersister(store: eventStore)
print("[cosmodrome-daemon] Intelligence modules initialized")

// 3. Track active sessions (from hook events)
var activeSessions: [UUID: DaemonSession] = [:]
let sessionLock = NSLock()

struct DaemonSession {
    let id: UUID
    let detector: AgentDetector
    var lastEventAt: Date = Date()
}

// 4. Start hook server (receives Claude Code hook events)
let hookServer = HookServer()
let hookSocketPath = hookServer.start()
print("[cosmodrome-daemon] Hook server listening at: \(hookSocketPath)")

hookServer.onEvent = { event in
    let sessionId = event.sessionId ?? UUID()

    sessionLock.lock()
    // Create session detector if needed
    if activeSessions[sessionId] == nil {
        let detector = AgentDetector(
            agentType: "claude",
            sessionId: sessionId,
            sessionName: "hook-\(sessionId.uuidString.prefix(8))"
        )
        activeSessions[sessionId] = DaemonSession(id: sessionId, detector: detector)

        // Register session in the store
        try? eventStore.recordSessionStart(
            sessionId: sessionId,
            projectId: "daemon",
            projectPath: nil,
            name: "hook-\(sessionId.uuidString.prefix(8))",
            agentType: "claude"
        )
    }
    activeSessions[sessionId]?.lastEventAt = Date()
    let session = activeSessions[sessionId]
    sessionLock.unlock()

    // Convert hook event to activity events
    if let detector = session?.detector {
        detector.ingestHookEvent(event)
        let events = detector.consumeEvents()
        if !events.isEmpty {
            eventPersister.buffer(events: events)
        }
    }
}

// 5. Start control server (serves CLI queries)
let controlServer = ControlServer()
let controlPath = daemonSocketPath()

controlServer.onCommand = { request -> ControlResponse in
    switch request.command {
    case "status":
        sessionLock.lock()
        let count = activeSessions.count
        sessionLock.unlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let status: [String: Any] = [
            "daemon": "running",
            "active_sessions": count,
            "hook_socket": hookSocketPath,
            "control_socket": controlPath,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: status),
           let str = String(data: data, encoding: .utf8) {
            return .success(str)
        }
        return .success("{\"daemon\": \"running\", \"active_sessions\": \(count)}")

    case "query-history":
        let projectPath = request.args?["project_path"]
        let limit = request.args?["limit"].flatMap(Int.init) ?? 50
        guard let records = try? eventStore.loadSessionHistory(projectPath: projectPath, limit: limit) else {
            return .failure("Failed to query history")
        }
        let items = records.map { r -> [String: Any] in
            var d: [String: Any] = [
                "id": r.id,
                "name": r.name,
                "started_at": r.startedAt.timeIntervalSince1970,
                "total_cost": r.totalCost,
                "total_tasks": r.totalTasks,
                "total_errors": r.totalErrors,
            ]
            if let agent = r.agentType { d["agent_type"] = agent }
            if let model = r.model { d["model"] = model }
            if let ended = r.endedAt { d["ended_at"] = ended.timeIntervalSince1970 }
            return d
        }
        if let data = try? JSONSerialization.data(withJSONObject: items),
           let str = String(data: data, encoding: .utf8) {
            return .success(str)
        }
        return .failure("JSON encoding error")

    case "query-patterns":
        let errorText = request.args?["error_text"] ?? ""
        let hash = PatternLearner.normalizeError(errorText)
        guard let record = try? eventStore.lookupErrorPattern(hash: hash) else {
            return .success("{\"found\": false}")
        }
        let result: [String: Any] = [
            "found": true,
            "pattern": record.text,
            "occurrences": record.occurrences,
            "stuck_probability": record.stuckProbability,
            "stuck_count": record.stuckCount,
            "resolved_count": record.resolvedCount,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result),
           let str = String(data: data, encoding: .utf8) {
            return .success(str)
        }
        return .failure("JSON encoding error")

    case "query-cost":
        let classification = request.args?["classification"] ?? "unknown"
        guard let cls = TaskClassification(rawValue: classification) else {
            return .failure("Invalid classification: \(classification)")
        }
        if let prediction = costPredictor.predict(classification: cls) {
            let result: [String: Any] = [
                "median": prediction.median,
                "p75": prediction.p75,
                "sample_size": prediction.sampleSize,
                "classification": prediction.classification,
                "range": prediction.rangeString,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: result),
               let str = String(data: data, encoding: .utf8) {
                return .success(str)
            }
        }
        return .success("{\"available\": false, \"reason\": \"insufficient data\"}")

    case "query-efficiency":
        let entries = efficiencyTracker.compare()
        let items = entries.map { e -> [String: Any] in
            [
                "agent_type": e.agentType,
                "classification": e.classification,
                "median_cost": e.medianCost,
                "median_duration": e.medianDuration,
                "task_count": e.taskCount,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: items),
           let str = String(data: data, encoding: .utf8) {
            return .success(str)
        }
        return .failure("JSON encoding error")

    case "query-workflows":
        let triggerKind = request.args?["trigger_kind"] ?? ""
        let triggerContext = request.args?["trigger_context"]
        let projectPath = request.args?["project_path"]
        guard let suggestions = try? eventStore.lookupWorkflowSuggestions(
            projectPath: projectPath,
            triggerKind: triggerKind,
            triggerContext: triggerContext
        ) else {
            return .success("[]")
        }
        let items = suggestions.map { s -> [String: Any] in
            [
                "follow_kind": s.followKind,
                "follow_context": s.followContext as Any,
                "count": s.count,
                "probability": s.probability,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: items),
           let str = String(data: data, encoding: .utf8) {
            return .success(str)
        }
        return .failure("JSON encoding error")

    default:
        return .failure("Unknown command: \(request.command)")
    }
}

controlServer.start(at: controlPath)
print("[cosmodrome-daemon] Control server listening at: \(controlPath)")

// 6. Handle SIGTERM/SIGINT for clean shutdown
let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigTermSource.setEventHandler {
    print("\n[cosmodrome-daemon] Received SIGTERM, shutting down...")
    eventPersister.flushSync()
    controlServer.stop()
    hookServer.stop()
    exit(0)
}
sigTermSource.resume()
signal(SIGTERM, SIG_IGN)

let sigIntSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigIntSource.setEventHandler {
    print("\n[cosmodrome-daemon] Received SIGINT, shutting down...")
    eventPersister.flushSync()
    controlServer.stop()
    hookServer.stop()
    exit(0)
}
sigIntSource.resume()
signal(SIGINT, SIG_IGN)

// 7. Cleanup timer (daily)
let cleanupTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
cleanupTimer.schedule(deadline: .now() + 3600, repeating: 86400)
cleanupTimer.setEventHandler {
    try? eventStore.cleanup()
}
cleanupTimer.resume()

print("[cosmodrome-daemon] Ready. Waiting for events...")

// 8. Run forever
dispatchMain()

// MARK: - Helpers

func daemonSocketPath() -> String {
    let tmpDir = NSTemporaryDirectory()
    let uid = getuid()
    return "\(tmpDir)cosmodrome-daemon-\(uid).sock"
}
