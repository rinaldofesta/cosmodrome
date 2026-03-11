import Foundation

/// Detects AI agent state from terminal output. Runs inline on I/O thread.
/// Also handles model detection and activity event extraction.
public final class AgentDetector {
    public private(set) var state: AgentState = .inactive
    private var previousState: AgentState = .inactive
    private var lastChange = Date.distantPast
    private let debounce: TimeInterval
    private let patterns: [AgentPattern]

    // Model detection (lazy — first 10KB + /model commands)
    public let modelDetector = ModelDetector()

    // When true, hook events have been received — suppress regex state detection
    private var hasHookData = false
    private var lastHookEvent = Date.distantPast
    private let hookTimeout: TimeInterval = 30

    // Subagent tracking
    private var activeSubagent: String?
    private var subagentStartedAt: Date?

    // Event extraction context
    private let sessionId: UUID
    private let sessionName: String
    private var _pendingEvents: [ActivityEvent] = []

    public init(agentType: String, sessionId: UUID, sessionName: String, debounce: TimeInterval = 0.3) {
        self.patterns = AgentPatterns.patterns(for: agentType)
        self.debounce = debounce
        self.sessionId = sessionId
        self.sessionName = sessionName
    }

    /// Initialize with custom patterns (useful for testing).
    public init(patterns: [AgentPattern], debounce: TimeInterval = 0.3) {
        self.patterns = patterns
        self.debounce = debounce
        self.sessionId = UUID()
        self.sessionName = "test"
    }

    /// Called on I/O thread when new output arrives.
    /// Performs state detection, model detection, and event extraction in one pass.
    public func analyze(lastOutput: UnsafeRawBufferPointer) {
        // Convert last output to string (only last 2KB for efficiency)
        let len = min(lastOutput.count, 2048)
        let start = lastOutput.count - len
        let slice = UnsafeRawBufferPointer(rebasing: lastOutput[start...])
        guard let text = String(bytes: slice, encoding: .utf8) else { return }

        analyzeText(text)
    }

    /// Analyze text directly (for testing and non-PTY usage).
    public func analyzeText(_ text: String) {
        // Strip ANSI escape sequences so regex patterns match clean text.
        // Raw PTY output contains codes like \e[1;33mAllow\e[0m that break patterns.
        let cleanText = Self.stripANSI(text)

        // 1. State detection
        detectState(cleanText)

        // 2. Model detection (lazy)
        let forceModel = ModelDetector.containsModelCommand(cleanText)
        modelDetector.scan(cleanText, force: forceModel)

        // 3. Activity event extraction
        extractEvents(from: cleanText)

        // 4. State transition events
        if state != previousState {
            let now = Date()

            _pendingEvents.append(ActivityEvent(
                timestamp: now, sessionId: sessionId, sessionName: sessionName,
                kind: .stateChanged(from: previousState, to: state)
            ))

            if state == .working && previousState != .working {
                _pendingEvents.append(ActivityEvent(
                    timestamp: now, sessionId: sessionId, sessionName: sessionName,
                    kind: .taskStarted
                ))
            }

            if let model = modelDetector.currentModel {
                if previousState == .inactive || forceModelEventNeeded(model) {
                    _pendingEvents.append(ActivityEvent(
                        timestamp: now, sessionId: sessionId, sessionName: sessionName,
                        kind: .modelChanged(model: model)
                    ))
                }
            }

            previousState = state
        }
    }

    /// Consume all pending events. Called from the onOutput callback after analyze().
    public func consumeEvents() -> [ActivityEvent] {
        let events = _pendingEvents
        _pendingEvents = []
        return events
    }

    /// Whether the last analyze() caused a transition from .working to non-working.
    public var didCompleteTask: Bool {
        previousState != .working && state != .working
    }

    /// The state before the most recent change.
    public var lastPreviousState: AgentState {
        previousState
    }

    /// Ingest a structured hook event (from CosmodromeHook via HookServer).
    /// Hook events are authoritative — once received, they suppress regex state detection.
    public func ingestHookEvent(_ event: HookEvent) {
        hasHookData = true

        lastHookEvent = Date()

        // Map hook events to agent state
        switch event.hookName {
        case "PreToolUse":
            state = .working
            lastChange = Date()
        case "Stop":
            state = .inactive
            lastChange = Date()
        default:
            break
        }

        // Convert to activity event if possible
        if let kind = event.toEventKind() {
            _pendingEvents.append(ActivityEvent(
                timestamp: event.timestamp,
                sessionId: sessionId,
                sessionName: sessionName,
                kind: kind
            ))
        }
    }

    /// Reset the detector state.
    public func reset() {
        state = .inactive
        previousState = .inactive
        lastChange = Date.distantPast
        hasHookData = false
        activeSubagent = nil
        subagentStartedAt = nil
        _pendingEvents = []
        modelDetector.reset()
    }

    // MARK: - Private: State Detection

    private func detectState(_ text: String) {
        // Determine if hooks are active (received within timeout)
        let hookActive: Bool
        if hasHookData {
            if Date().timeIntervalSince(lastHookEvent) > hookTimeout {
                hasHookData = false
                hookActive = false
            } else {
                hookActive = true
            }
        } else {
            hookActive = false
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let lastLines = lines.suffix(5)
        let lastLine = lines.last.map(String.init) ?? ""

        var detected: AgentState?

        // Check patterns in priority order (highest first)
        for pattern in patterns.sorted(by: { $0.priority > $1.priority }) {
            // When hooks are active, only run patterns for states hooks can't detect.
            // Hooks handle .working and .inactive authoritatively, but have no event
            // for .needsInput or .error — regex must still detect those.
            if hookActive && pattern.state != .needsInput && pattern.state != .error {
                continue
            }
            let searchText = pattern.lastLineOnly ? lastLine : lastLines.joined(separator: "\n")
            if searchText.range(of: pattern.regex, options: .regularExpression) != nil {
                detected = pattern.state
                break
            }
        }

        guard let newState = detected, newState != state else { return }

        let now = Date()
        guard now.timeIntervalSince(lastChange) >= debounce else { return }

        state = newState
        lastChange = now
    }

    // MARK: - Private: Event Extraction

    private func extractEvents(from text: String) {
        let now = Date()

        for line in text.split(separator: "\n") {
            let s = String(line)

            // File read: "Read src/foo.ts" or "Reading src/foo.ts"
            if s.range(of: #"(?:Read|Reading)\s+\S+"#, options: .regularExpression) != nil {
                if let path = extractPath(from: s, prefixes: ["Read ", "Reading "]) {
                    _pendingEvents.append(ActivityEvent(
                        timestamp: now, sessionId: sessionId, sessionName: sessionName,
                        kind: .fileRead(path: path)
                    ))
                }
            }
            // File write: "Write src/foo.ts" or "Wrote src/foo.ts" or "Created src/foo.ts"
            else if s.range(of: #"(?:Write|Wrote|Created)\s+\S+"#, options: .regularExpression) != nil {
                if let path = extractPath(from: s, prefixes: ["Write ", "Wrote ", "Created "]) {
                    let (added, removed) = extractDiffCounts(from: s)
                    _pendingEvents.append(ActivityEvent(
                        timestamp: now, sessionId: sessionId, sessionName: sessionName,
                        kind: .fileWrite(path: path, added: added, removed: removed)
                    ))
                }
            }
            // Command: "Bash: npm test" or "Execute: make build" or "Running: cargo test"
            else if s.range(of: #"(?:Bash|Execute|Running):\s*.+"#, options: .regularExpression) != nil {
                if let cmd = extractCommand(from: s) {
                    _pendingEvents.append(ActivityEvent(
                        timestamp: now, sessionId: sessionId, sessionName: sessionName,
                        kind: .commandRun(command: cmd)
                    ))
                }
            }
            // Subagent started: 'Agent "description"' or 'Spawning agent: name'
            else if s.range(of: #"Agent\s+\""#, options: .regularExpression) != nil {
                if let name = extractSubagentName(from: s) {
                    activeSubagent = name
                    subagentStartedAt = now
                    _pendingEvents.append(ActivityEvent(
                        timestamp: now, sessionId: sessionId, sessionName: sessionName,
                        kind: .subagentStarted(name: name, description: s)
                    ))
                }
            }
            // Subagent completed: agent result returned
            else if activeSubagent != nil && s.range(of: #"Agent\s+completed|agent\s+returned|subagent.*done"#, options: .regularExpression) != nil {
                let name = activeSubagent ?? "agent"
                let duration = subagentStartedAt.map { now.timeIntervalSince($0) } ?? 0
                _pendingEvents.append(ActivityEvent(
                    timestamp: now, sessionId: sessionId, sessionName: sessionName,
                    kind: .subagentCompleted(name: name, duration: duration)
                ))
                activeSubagent = nil
                subagentStartedAt = nil
            }
        }
    }

    private func extractPath(from line: String, prefixes: [String]) -> String? {
        for prefix in prefixes {
            guard let range = line.range(of: prefix) else { continue }
            let rest = String(line[range.upperBound...])
            // Take first whitespace-delimited token as the path
            let path = rest.split(separator: " ").first.map(String.init)
            return path
        }
        return nil
    }

    private func extractDiffCounts(from line: String) -> (added: Int?, removed: Int?) {
        // Look for patterns like "(+45 -12)" or "(new file)"
        guard let parenRange = line.range(of: #"\([+-]\d+\s+[+-]\d+\)"#, options: .regularExpression) else {
            return (nil, nil)
        }
        let paren = String(line[parenRange])
        let nums = paren.split(whereSeparator: { "()+ ".contains($0) })
        let added = nums.count >= 1 ? Int(nums[0]) : nil
        let removed = nums.count >= 2 ? Int(String(nums[1]).replacingOccurrences(of: "-", with: "")) : nil
        return (added, removed)
    }

    private func extractCommand(from line: String) -> String? {
        for prefix in ["Bash: ", "Execute: ", "Running: "] {
            if let range = line.range(of: prefix) {
                let cmd = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                return cmd.isEmpty ? nil : cmd
            }
        }
        return nil
    }

    private func extractSubagentName(from line: String) -> String? {
        // Match: Agent "description here"
        if let range = line.range(of: #"Agent\s+\"([^\"]+)\""#, options: .regularExpression) {
            let match = String(line[range])
            // Extract the quoted part
            if let quoteStart = match.firstIndex(of: "\""),
               let quoteEnd = match[match.index(after: quoteStart)...].firstIndex(of: "\"") {
                return String(match[match.index(after: quoteStart)..<quoteEnd])
            }
        }
        // Match: Spawning agent: name
        if let range = line.range(of: "Spawning agent: ") {
            let name = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    private var lastModelEvent: String?

    private func forceModelEventNeeded(_ model: String) -> Bool {
        if model != lastModelEvent {
            lastModelEvent = model
            return true
        }
        return false
    }

    /// Strip ANSI escape sequences (CSI, OSC, charset designators) from text.
    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\x1B\[[0-9;]*[a-zA-Z]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)|\x1B[()][012AB]|\x1B[>=]"#,
            with: "",
            options: .regularExpression
        )
    }
}
