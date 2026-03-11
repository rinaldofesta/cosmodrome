# Technical Specification: Cosmodrome

**Version:** 1.1  
**Date:** March 2026

---

## 1. Terminal Backend

### 1.1 Protocol

```swift
/// Swappable VT parsing backend. Current: SwiftTerm. Future: libghostty-vt.
protocol TerminalBackend: AnyObject {
    /// Feed raw bytes from PTY.
    func process(_ bytes: UnsafeRawBufferPointer)

    /// Read cell at grid position.
    func cell(row: Int, col: Int) -> TerminalCell

    /// Current cursor position.
    func cursorPosition() -> (row: Int, col: Int)

    /// Resize the virtual terminal.
    func resize(cols: UInt16, rows: UInt16)

    /// Grid dimensions.
    var rows: Int { get }
    var cols: Int { get }

    /// Rows modified since last clearDirty(). Used for incremental rendering.
    var dirtyRows: IndexSet { get }
    func clearDirty()

    /// Scrollback line count.
    var scrollbackCount: Int { get }
}
```

### 1.2 Cell Data

```swift
struct TerminalCell {
    let codepoint: UInt32
    let wide: Bool
    let fg: TerminalColor
    let bg: TerminalColor
    let attrs: CellAttributes
}

struct CellAttributes: OptionSet {
    let rawValue: UInt16
    static let bold          = CellAttributes(rawValue: 1 << 0)
    static let italic        = CellAttributes(rawValue: 1 << 1)
    static let underline     = CellAttributes(rawValue: 1 << 2)
    static let strikethrough = CellAttributes(rawValue: 1 << 3)
    static let inverse       = CellAttributes(rawValue: 1 << 4)
}

enum TerminalColor {
    case indexed(UInt8)
    case rgb(r: UInt8, g: UInt8, b: UInt8)
    case `default`
}
```

### 1.3 SwiftTerm Implementation (Phase 0-1)

```swift
import SwiftTerm

final class SwiftTermBackend: TerminalBackend {
    private let terminal: Terminal
    private var _dirtyRows = IndexSet()

    init(cols: Int, rows: Int) {
        terminal = Terminal(delegate: nil, options: TerminalOptions(
            cols: cols, rows: rows,
            scrollback: 10_000
        ))
    }

    func process(_ bytes: UnsafeRawBufferPointer) {
        let data = Array(bytes)
        terminal.feed(byteArray: data)
        // Terminal marks dirty lines internally
        // We extract them after processing
        _dirtyRows = extractDirtyRows()
    }

    func cell(row: Int, col: Int) -> TerminalCell {
        let line = terminal.getLine(row: row)
        let ch = line[col]
        return TerminalCell(
            codepoint: UInt32(ch.code),
            wide: ch.width > 1,
            fg: mapColor(ch.fg),
            bg: mapColor(ch.bg),
            attrs: mapAttributes(ch.style)
        )
    }

    func resize(cols: UInt16, rows: UInt16) {
        terminal.resize(cols: Int(cols), rows: Int(rows))
    }

    // ... remaining protocol conformance
}
```

### 1.4 libghostty-vt Implementation (Phase 2+)

When the C API stabilizes, add `GhosttyBackend` implementing the same protocol:

```swift
final class GhosttyBackend: TerminalBackend {
    private let vtHandle: OpaquePointer  // ghostty_vt_t*

    init(cols: Int, rows: Int) {
        var config = ghostty_vt_config_t()
        config.cols = UInt16(cols)
        config.rows = UInt16(rows)
        config.scrollback_max = 10_000
        self.vtHandle = ghostty_vt_init(&config)
    }

    func process(_ bytes: UnsafeRawBufferPointer) {
        ghostty_vt_process(vtHandle, bytes.baseAddress, bytes.count, nil, nil)
    }

    // ... same protocol, different internals

    deinit { ghostty_vt_deinit(vtHandle) }
}
```

Build integration for libghostty-vt:

```bash
cd vendor/ghostty
zig build lib-vt -Dtarget=aarch64-macos -Doptimize=ReleaseFast
# produces: libghostty_vt.a + ghostty_vt.h
```

Linked via SPM `.systemLibrary` target. The swap is: change one line in the Session initializer from `SwiftTermBackend(...)` to `GhosttyBackend(...)`.

---

## 2. PTY Multiplexer

Single I/O thread, kqueue-based, handles all PTY file descriptors.

```swift
/// Multiplexes I/O for all PTY sessions on a single thread.
final class PTYMultiplexer {
    private let kqFD: Int32
    private let thread: Thread
    private var sessions: [Int32: SessionIO] = [:]  // masterFD → session info
    private let readBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 65536, alignment: 16)

    struct SessionIO {
        let id: UUID
        let backend: TerminalBackend
        let agentDetector: AgentDetector?  // nil for non-agent sessions
        let onDirty: () -> Void            // signal main thread
    }

    init() {
        self.kqFD = kqueue()
        self.thread = Thread(block: { [weak self] in self?.runLoop() })
        thread.qualityOfService = .userInteractive
        thread.name = "com.cosmodrome.io"
        thread.start()
    }

    /// Register a new PTY fd for multiplexing.
    func register(fd: Int32, session: SessionIO) {
        sessions[fd] = session

        var event = kevent(
            ident: UInt(fd),
            filter: Int16(EVFILT_READ),
            flags: UInt16(EV_ADD),
            fflags: 0, data: 0, udata: nil
        )
        kevent(kqFD, &event, 1, nil, 0, nil)
    }

    /// Unregister a PTY fd (process exited).
    func unregister(fd: Int32) {
        var event = kevent(
            ident: UInt(fd),
            filter: Int16(EVFILT_READ),
            flags: UInt16(EV_DELETE),
            fflags: 0, data: 0, udata: nil
        )
        kevent(kqFD, &event, 1, nil, 0, nil)
        sessions.removeValue(forKey: fd)
    }

    /// Main I/O loop. Sleeps when no data. Wakes on any PTY output.
    private func runLoop() {
        var events = [kevent](repeating: kevent(), count: 32)

        while !Thread.current.isCancelled {
            let n = kevent(kqFD, nil, 0, &events, 32, nil)  // blocks
            guard n > 0 else { continue }

            for i in 0..<Int(n) {
                let fd = Int32(events[i].ident)
                guard let session = sessions[fd] else { continue }

                let bytesRead = read(fd, readBuffer.baseAddress!, 65536)
                guard bytesRead > 0 else {
                    if bytesRead == 0 { handleEOF(fd: fd) }
                    continue
                }

                let slice = UnsafeRawBufferPointer(start: readBuffer.baseAddress!, count: bytesRead)

                // Feed to VT parser
                session.backend.process(slice)

                // Agent detection (inline, same thread, data already here)
                session.agentDetector?.analyze(lastOutput: slice)

                // Signal main thread to redraw this session
                session.onDirty()
            }
        }
    }

    private func handleEOF(fd: Int32) {
        // Process exited. Reap and notify.
        guard let session = sessions[fd] else { return }
        unregister(fd: fd)
        // Post to main thread: session.id process exited
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .processExited,
                object: nil,
                userInfo: ["sessionId": session.id]
            )
        }
    }
}
```

### 2.1 PTY Spawning

```swift
/// Spawn a child process in a new PTY. Returns the master fd.
func spawnPTY(
    command: String,
    arguments: [String],
    environment: [String: String],
    cwd: String,
    size: (cols: UInt16, rows: UInt16)
) throws -> (fd: Int32, pid: pid_t) {
    var winSize = winsize(ws_row: size.rows, ws_col: size.cols, ws_xpixel: 0, ws_ypixel: 0)
    var masterFD: Int32 = 0
    let pid = forkpty(&masterFD, nil, nil, &winSize)

    guard pid >= 0 else { throw PTYError.forkFailed(errno: errno) }

    if pid == 0 {
        // Child: set env, chdir, exec
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Cosmodrome"
        env.merge(environment) { _, new in new }
        for (k, v) in env { setenv(k, v, 1) }

        chdir(cwd)
        let args = ([command] + arguments).map { strdup($0) } + [nil]
        execvp(command, args)
        _exit(127)
    }

    return (fd: masterFD, pid: pid)
}
```

---

## 3. Metal Renderer

### 3.1 Glyph Atlas

```swift
final class GlyphAtlas {
    struct GlyphKey: Hashable {
        let codepoint: UInt32
        let fontVariant: UInt8    // 0=regular, 1=bold, 2=italic, 3=bolditalic
    }

    struct GlyphEntry {
        let textureIndex: Int
        let uv: SIMD4<Float>     // (u0, v0, u1, v1)
        let size: SIMD2<Float>   // pixel width, height
        let bearing: SIMD2<Float>
    }

    private var cache: [GlyphKey: GlyphEntry] = [:]
    private var textures: [MTLTexture] = []
    private let device: MTLDevice
    private let atlasSize: Int = 4096

    // Simple row packer
    private var packX: Int = 0
    private var packY: Int = 0
    private var rowHeight: Int = 0

    func lookup(_ key: GlyphKey) -> GlyphEntry {
        if let hit = cache[key] { return hit }
        return rasterize(key)
    }

    private func rasterize(_ key: GlyphKey) -> GlyphEntry {
        let font = fontManager.ctFont(variant: key.fontVariant)
        var glyph = CGGlyph(0)
        var codepoint = UniChar(key.codepoint)
        CTFontGetGlyphsForCharacters(font, &codepoint, &glyph, 1)

        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, &bounds, 1)

        let bitmap = rasterizeGlyph(font: font, glyph: glyph, bounds: bounds)
        let entry = packIntoAtlas(bitmap: bitmap, bounds: bounds)
        cache[key] = entry
        return entry
    }
}
```

### 3.2 Render Loop

```swift
final class TerminalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let glyphPipeline: MTLRenderPipelineState
    private let bgPipeline: MTLRenderPipelineState
    private let cursorPipeline: MTLRenderPipelineState
    private let atlas: GlyphAtlas
    private let fontManager: FontManager

    // Triple-buffered vertex data
    private var vertexBuffers: [MTLBuffer]  // 3 buffers, rotate per frame
    private var bufferIndex = 0

    private var visibleSessions: [(session: Session, viewport: MTLViewport, scissor: MTLScissorRect)] = []

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor else { return }

        let commandBuffer = commandQueue.makeCommandBuffer()!
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)!

        let buffer = vertexBuffers[bufferIndex]
        bufferIndex = (bufferIndex + 1) % 3

        var offset = 0

        for entry in visibleSessions {
            let session = entry.session
            guard let backend = session.backend else { continue }

            encoder.setScissorRect(entry.scissor)
            encoder.setViewport(entry.viewport)

            // Build vertex data for dirty rows only (or all if first render)
            let vertexCount = buildVertices(
                backend: backend,
                atlas: atlas,
                cellMetrics: fontManager.cellMetrics,
                into: buffer,
                at: offset
            )

            // Draw backgrounds
            encoder.setRenderPipelineState(bgPipeline)
            encoder.drawPrimitives(type: .triangle, vertexStart: offset, vertexCount: vertexCount.bg)

            // Draw glyphs
            encoder.setRenderPipelineState(glyphPipeline)
            encoder.setFragmentTexture(atlas.currentTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: offset + vertexCount.bg, vertexCount: vertexCount.glyph)

            // Draw cursor
            encoder.setRenderPipelineState(cursorPipeline)
            encoder.drawPrimitives(type: .triangle, vertexStart: offset + vertexCount.bg + vertexCount.glyph, vertexCount: 6)

            offset += vertexCount.total
            backend.clearDirty()
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
```

### 3.3 Metal Shaders

```metal
#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
    float4 color    [[attribute(2)]];
};

struct Fragment {
    float4 position [[position]];
    float2 texCoord;
    float4 color;
};

struct Uniforms {
    float4x4 projection;
    float time;
};

// Glyph rendering
vertex Fragment glyph_vert(Vertex in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    Fragment out;
    out.position = u.projection * float4(in.position, 0, 1);
    out.texCoord = in.texCoord;
    out.color = in.color;
    return out;
}

fragment float4 glyph_frag(Fragment in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    float alpha = atlas.sample(sampler(filter::linear), in.texCoord).a;
    return float4(in.color.rgb, in.color.a * alpha);
}

// Background rectangles (no texture, just solid color)
vertex Fragment bg_vert(Vertex in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    Fragment out;
    out.position = u.projection * float4(in.position, 0, 1);
    out.color = in.color;
    return out;
}

fragment float4 bg_frag(Fragment in [[stage_in]]) {
    return in.color;
}
```

### 3.4 Font Manager

```swift
final class FontManager {
    struct CellMetrics {
        let width: CGFloat
        let height: CGFloat
        let baseline: CGFloat
    }

    private var fonts: [CTFont]  // [regular, bold, italic, boldItalic]
    let cellMetrics: CellMetrics

    init(family: String = "JetBrains Mono", size: CGFloat = 14, lineHeight: CGFloat = 1.2) {
        let regular = CTFontCreateWithName(family as CFString, size, nil)
        let bold = CTFontCreateCopyWithSymbolicTraits(regular, size, nil, .boldTrait, .boldTrait)!
        let italic = CTFontCreateCopyWithSymbolicTraits(regular, size, nil, .italicTrait, .italicTrait)!
        let boldItalic = CTFontCreateCopyWithSymbolicTraits(regular, size, nil, [.boldTrait, .italicTrait], [.boldTrait, .italicTrait])!
        self.fonts = [regular, bold, italic, boldItalic]

        let ascent = CTFontGetAscent(regular)
        let descent = CTFontGetDescent(regular)
        let leading = CTFontGetLeading(regular)
        var advance = CGSize.zero
        var glyph = CTFontGetGlyphWithName(regular, "M" as CFString)
        CTFontGetAdvancesForGlyphs(regular, .default, &glyph, &advance, 1)

        self.cellMetrics = CellMetrics(
            width: ceil(advance.width),
            height: ceil((ascent + descent + leading) * lineHeight),
            baseline: ceil(ascent)
        )
    }

    func ctFont(variant: UInt8) -> CTFont { fonts[Int(variant)] }
}
```

---

## 4. Data Model

```swift
@Observable
final class Project: Identifiable, Codable {
    let id: UUID
    var name: String
    var color: String
    var rootPath: String?
    var sessions: [Session] = []

    var aggregateState: AgentState {
        let agents = sessions.filter { $0.isAgent }
        if agents.contains(where: { $0.agentState == .error }) { return .error }
        if agents.contains(where: { $0.agentState == .needsInput }) { return .needsInput }
        if agents.contains(where: { $0.agentState == .working }) { return .working }
        return .inactive
    }

    var attentionCount: Int {
        sessions.count(where: { $0.agentState == .needsInput || $0.agentState == .error })
    }
}

@Observable
final class Session: Identifiable, Codable {
    let id: UUID
    var name: String
    var command: String
    var arguments: [String] = []
    var cwd: String = "."
    var environment: [String: String] = [:]
    var autoStart: Bool = false
    var autoRestart: Bool = false
    var restartDelay: TimeInterval = 1.0
    var isAgent: Bool = false
    var agentType: String?  // "claude", "aider", "codex", "gemini"

    // Runtime (not persisted) — Observable for UI
    var agentState: AgentState = .inactive
    var agentModel: String?       // "Opus 4.6", "Sonnet 4.6", etc.
    var agentContext: String?      // "89%" or "45k/200k"
    var agentMode: String?         // "Plan", "Accept Edits", "Bypass"
    var agentEffort: String?       // "high", "medium", "low"
    var agentCost: String?         // "$0.34"
    var isRunning: Bool = false
    var exitedUnexpectedly: Bool = false
    var hasUnreadNotification: Bool = false
    var detectedPorts: [UInt16] = []

    // Runtime (not persisted) — Non-observable internals
    @ObservationIgnored var backend: TerminalBackend?
    @ObservationIgnored var ptyFD: Int32 = -1
    @ObservationIgnored var pid: pid_t = 0
    @ObservationIgnored var taskStartedAt: Date? = nil
    @ObservationIgnored var filesChangedInTask: [String] = []
    @ObservationIgnored let stats = SessionStats()  // Accumulated usage stats
}

enum AgentState: String, Codable {
    case inactive
    case working
    case needsInput
    case error
}
```

---

## 5. Agent Detection

```swift
/// Detects AI agent state from terminal output. Runs inline on I/O thread.
final class AgentDetector {
    private(set) var state: AgentState = .inactive
    private var lastChange = Date.distantPast
    private let debounce: TimeInterval = 0.3
    private let patterns: [AgentPattern]

    init(agentType: String) {
        self.patterns = AgentDetector.patterns(for: agentType)
    }

    /// Called on I/O thread when new output arrives.
    func analyze(lastOutput: UnsafeRawBufferPointer) {
        // Convert last output to string (only last 2KB for efficiency)
        let len = min(lastOutput.count, 2048)
        let start = lastOutput.count - len
        guard let text = String(
            bytes: lastOutput[start..<lastOutput.count],
            encoding: .utf8
        ) else { return }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let lastLines = lines.suffix(5)
        let lastLine = lines.last.map(String.init) ?? ""

        var detected: AgentState?

        // Check patterns in priority order
        for pattern in patterns.sorted(by: { $0.priority > $1.priority }) {
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

    // Pattern definitions per agent type
    static func patterns(for type: String) -> [AgentPattern] {
        switch type {
        case "claude":
            return [
                AgentPattern(state: .needsInput, regex: #"(?i)(allow|deny|approve|yes/no|\[y/n\]|Do you want)"#, lastLineOnly: false, priority: 30),
                AgentPattern(state: .error, regex: #"(?i)(error|failed|exception|panic)"#, lastLineOnly: false, priority: 20),
                AgentPattern(state: .working, regex: #"[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏●]"#, lastLineOnly: true, priority: 15),
                AgentPattern(state: .working, regex: #"(Read|Write|Execute|Bash|Search|Glob)\s"#, lastLineOnly: false, priority: 10),
            ]
        default:
            // Generic patterns for unknown agents
            return [
                AgentPattern(state: .needsInput, regex: #"(?i)(\[y/n\]|yes/no|confirm)"#, lastLineOnly: false, priority: 30),
                AgentPattern(state: .error, regex: #"(?i)(error|failed)"#, lastLineOnly: false, priority: 20),
            ]
        }
    }
}

struct AgentPattern {
    let state: AgentState
    let regex: String
    let lastLineOnly: Bool
    let priority: Int
}
```

---

## 6. Activity Log

```swift
/// A single event captured from agent output.
struct ActivityEvent {
    let timestamp: Date
    let sessionId: UUID
    let sessionName: String
    let kind: EventKind

    enum EventKind {
        case taskStarted
        case taskCompleted(duration: TimeInterval)
        case fileRead(path: String)
        case fileWrite(path: String, added: Int?, removed: Int?)
        case commandRun(command: String)
        case error(message: String)
        case modelChanged(model: String)
        case stateChanged(from: AgentState, to: AgentState)
    }
}

/// Per-project activity log. Append-only, in-memory, bounded.
final class ActivityLog {
    private(set) var events: [ActivityEvent] = []
    private let maxEvents = 10_000
    private let projectId: UUID

    /// Append an event. Called from I/O thread, must be fast.
    func append(_ event: ActivityEvent) {
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
    }

    /// Events for a specific session.
    func events(for sessionId: UUID) -> [ActivityEvent] {
        events.filter { $0.sessionId == sessionId }
    }

    /// Files changed across all sessions in this project.
    var filesChanged: [String] {
        events.compactMap {
            if case .fileWrite(let path, _, _) = $0.kind { return path }
            return nil
        }
    }

    /// Summary for the last N minutes.
    func summary(last minutes: Int) -> [ActivityEvent] {
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        return events.filter { $0.timestamp > cutoff }
    }
}
```

### 6.1 Event Extraction from Output

Events are extracted inline in the AgentDetector when output arrives:

```swift
extension AgentDetector {
    /// Extract structured events from agent output.
    /// Called on I/O thread alongside state detection.
    func extractEvents(from text: String, sessionId: UUID, sessionName: String) -> [ActivityEvent] {
        var events: [ActivityEvent] = []
        let now = Date()

        for line in text.split(separator: "\n") {
            let s = String(line)

            // File operations (Claude Code format)
            if let match = s.firstMatch(of: /(?:Read|Reading)\s+(.+)/) {
                events.append(ActivityEvent(
                    timestamp: now, sessionId: sessionId, sessionName: sessionName,
                    kind: .fileRead(path: String(match.1))
                ))
            }
            if let match = s.firstMatch(of: /(?:Write|Wrote|Created)\s+(.+?)(?:\s+\(([+-]\d+)\s+([+-]\d+)\))?$/) {
                events.append(ActivityEvent(
                    timestamp: now, sessionId: sessionId, sessionName: sessionName,
                    kind: .fileWrite(
                        path: String(match.1),
                        added: match.2.flatMap { Int(String($0)) },
                        removed: match.3.flatMap { Int(String($0)) }
                    )
                ))
            }
            // Command execution
            if let match = s.firstMatch(of: /(?:Bash|Execute|Running):\s*(.+)/) {
                events.append(ActivityEvent(
                    timestamp: now, sessionId: sessionId, sessionName: sessionName,
                    kind: .commandRun(command: String(match.1))
                ))
            }
        }

        return events
    }
}
```

### 6.2 Persistence

```swift
/// Flush activity log to disk periodically (every 60s) and on quit.
func persistActivityLog(_ log: ActivityLog, projectId: UUID) {
    let url = appSupportURL
        .appendingPathComponent("projects")
        .appendingPathComponent("\(projectId)-activity.yml")

    // Only persist last 1000 events (keep disk usage small)
    let recent = Array(log.events.suffix(1000))
    let data = try? YAMLEncoder().encode(recent)
    try? data?.write(to: url, atomically: true)
}
```

---

## 7. Model Detection

```swift
/// Detects which LLM model an agent is using from terminal output.
final class ModelDetector {
    private(set) var currentModel: String? = nil

    // Model patterns — checked against full output, cached aggressively
    private static let modelPatterns: [(regex: Regex<(Substring, Substring)>, model: String)] = [
        // Claude Code shows model in startup and /model command
        (try! Regex(#"(?:model|Model):\s*(claude-opus[^\s,)]*|opus)"#), "opus"),
        (try! Regex(#"(?:model|Model):\s*(claude-sonnet[^\s,)]*|sonnet)"#), "sonnet"),
        (try! Regex(#"(?:model|Model):\s*(claude-haiku[^\s,)]*|haiku)"#), "haiku"),
        // OpenAI models
        (try! Regex(#"(?:model|Model):\s*(gpt-[\d.]+[^\s,)]*)"#), "gpt"),
        // Gemini
        (try! Regex(#"(?:model|Model):\s*(gemini[^\s,)]*)"#), "gemini"),
    ]

    /// Scan output for model identifiers. Called sparingly (not every chunk).
    func scan(_ text: String) {
        for (pattern, _) in Self.modelPatterns {
            if let match = text.firstMatch(of: pattern) {
                let detected = String(match.1)
                if detected != currentModel {
                    currentModel = detected
                }
                return
            }
        }
    }
}
```

Model detection is **lazy** — it scans only the first 10KB of output when a session starts, and again when the user runs `/model` or similar commands. Not on every output chunk.

---

## 8. Completion Actions

```swift
/// Suggests next actions when an agent completes a task.
struct CompletionActions {

    struct Action {
        let label: String
        let icon: String       // SF Symbol name
        let command: () -> Void
    }

    /// Generate suggested actions based on what the agent did.
    static func suggest(
        session: Session,
        activityLog: ActivityLog,
        projectConfig: ProjectConfig?
    ) -> [Action] {
        var actions: [Action] = []

        let filesChanged = session.filesChangedInTask
        let duration = session.taskStartedAt.map { Date().timeIntervalSince($0) } ?? 0

        // Always offer: open diff (if files changed)
        if !filesChanged.isEmpty {
            actions.append(Action(
                label: "Open diff (\(filesChanged.count) files)",
                icon: "doc.text.magnifyingglass",
                command: { openDiffSession(files: filesChanged) }
            ))
        }

        // Offer: run tests (if project has a test command)
        if let testCmd = projectConfig?.testCommand {
            actions.append(Action(
                label: "Run tests",
                icon: "checkmark.circle",
                command: { spawnSession(command: testCmd) }
            ))
        }

        // Offer: start review agent (if task took > 60s and files changed)
        if duration > 60 && !filesChanged.isEmpty {
            let fileList = filesChanged.prefix(10).joined(separator: ", ")
            let prompt = "Review the changes in \(fileList) and check for bugs, edge cases, and style issues"
            actions.append(Action(
                label: "Start review agent",
                icon: "eye",
                command: { spawnAgentSession(prefill: prompt) }
            ))
        }

        return actions
    }
}
```

### 8.1 UI: Suggestion Bar

```swift
/// Transient bar shown at the bottom of a terminal session view.
/// Auto-dismisses after 30 seconds.
struct CompletionSuggestionBar: View {
    let actions: [CompletionActions.Action]
    let duration: TimeInterval
    let filesCount: Int
    @State private var visible = true

    var body: some View {
        if visible {
            HStack(spacing: 12) {
                Label(
                    "Task completed (\(formatDuration(duration)), \(filesCount) files)",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)

                Spacer()

                ForEach(actions.indices, id: \.self) { i in
                    Button(actions[i].label) { actions[i].command() }
                        .buttonStyle(.bordered)
                }

                Button("Dismiss", systemImage: "xmark") { visible = false }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    withAnimation { visible = false }
                }
            }
        }
    }
}
```

---

## 9. UI Architecture

### 6.1 Window Structure

```swift
class MainWindowController: NSWindowController {
    let splitView: NSSplitView
    let sidebar: NSHostingView<SidebarView>         // SwiftUI
    let contentView: TerminalContentView             // NSView containing MTKView
    let statusBar: NSHostingView<AgentStatusBar>     // SwiftUI
}

class TerminalContentView: NSView {
    let metalView: MTKView
    let renderer: TerminalRenderer
    let layoutEngine: LayoutEngine

    // Hit-testing: map mouse coordinates to session
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let session = layoutEngine.sessionAt(point: point) {
            focusSession(session)
        }
    }
}
```

### 6.2 Layout Engine

```swift
final class LayoutEngine {
    enum Mode { case grid, focus }

    var mode: Mode = .grid
    var focusedSessionId: UUID?

    /// Calculate viewport for each visible session.
    func layout(sessions: [Session], in bounds: CGRect) -> [(session: Session, frame: CGRect)] {
        switch mode {
        case .grid:
            let (cols, rows) = autoGrid(count: sessions.count)
            let cellW = bounds.width / CGFloat(cols)
            let cellH = bounds.height / CGFloat(rows)
            return sessions.enumerated().map { (i, session) in
                let col = i % cols
                let row = i / cols
                let frame = CGRect(
                    x: CGFloat(col) * cellW,
                    y: bounds.height - CGFloat(row + 1) * cellH,
                    width: cellW,
                    height: cellH
                )
                return (session, frame)
            }

        case .focus:
            guard let focusedId = focusedSessionId,
                  let session = sessions.first(where: { $0.id == focusedId }) else {
                return layout(sessions: sessions, in: bounds)  // fallback to grid
            }
            return [(session, bounds)]
        }
    }

    private func autoGrid(count: Int) -> (cols: Int, rows: Int) {
        switch count {
        case 1: return (1, 1)
        case 2: return (2, 1)
        case 3...4: return (2, 2)
        case 5...6: return (3, 2)
        case 7...9: return (3, 3)
        default: return (4, 3)
        }
    }

    func sessionAt(point: CGPoint) -> Session? {
        // Binary search through cached layout frames
        // ...
    }
}
```

---

## 10. Input Handling

```swift
final class KeybindingManager {
    struct Binding: Hashable {
        let key: UInt16           // keyCode
        let modifiers: NSEvent.ModifierFlags
    }

    enum Action {
        case projectByIndex(Int)
        case sessionByIndex(Int)
        case projectNext, projectPrevious
        case sessionNext, sessionPrevious
        case toggleFocus
        case toggleActivityLog
        case newSession, closeSession, newProject
        case jumpNextNeedsInput
    }

    private var bindings: [Binding: Action] = [:]

    init() {
        // Cmd+1-9: switch project
        for i in 1...9 {
            bindings[Binding(key: UInt16(18 + i - 1), modifiers: .command)] = .projectByIndex(i)
        }
        // Cmd+Enter: toggle focus
        bindings[Binding(key: 36, modifiers: .command)] = .toggleFocus
        // Cmd+T: new session
        bindings[Binding(key: 17, modifiers: .command)] = .newSession
        // Cmd+Shift+N: jump to next agent needing input
        bindings[Binding(key: 45, modifiers: [.command, .shift])] = .jumpNextNeedsInput
        // Cmd+L: toggle activity log panel
        bindings[Binding(key: 37, modifiers: [.command])] = .toggleActivityLog
        // ... etc
    }

    /// Returns the action if a keybinding matches, nil otherwise.
    /// If nil, the keystroke should be forwarded to the PTY.
    func match(event: NSEvent) -> Action? {
        let binding = Binding(key: event.keyCode, modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        return bindings[binding]
    }
}
```

For keystrokes not matched by bindings, encode and send to the focused session's PTY:

```swift
func forwardToTerminal(event: NSEvent, fd: Int32) {
    guard let chars = event.characters, let data = chars.data(using: .utf8) else { return }
    data.withUnsafeBytes { buffer in
        write(fd, buffer.baseAddress!, buffer.count)
    }
}
```

---

## 11. Configuration

### 8.1 Project Config (cosmodrome.yml)

```swift
struct ProjectConfig: Codable {
    var name: String
    var color: String?
    var sessions: [SessionConfig]
    var layout: String?  // "grid" or "focus"
}

struct SessionConfig: Codable {
    var name: String
    var command: String
    var args: [String]?
    var cwd: String?
    var env: [String: String]?
    var agent: Bool?
    var agentType: String?    // "claude", "aider", etc.
    var autoStart: Bool?
    var autoRestart: Bool?
    var restartDelay: Double?
}
```

### 8.2 User Config (~/.config/cosmodrome/config.yml)

```swift
struct UserConfig: Codable {
    var font: FontConfig?
    var theme: String?
    var window: WindowConfig?
    var notifications: NotificationConfig?

    struct FontConfig: Codable {
        var family: String?
        var size: Double?
        var lineHeight: Double?
    }

    struct WindowConfig: Codable {
        var opacity: Double?
        var restoreState: Bool?
    }

    struct NotificationConfig: Codable {
        var agentNeedsInput: Bool?
        var agentError: Bool?
        var processExited: Bool?
    }
}
```

### 8.3 App State (~/.../Cosmodrome/state.yml)

```swift
struct AppState: Codable {
    var windowFrame: [Double]  // [x, y, w, h]
    var sidebarWidth: Double
    var activeProjectId: String?
    var projects: [ProjectStateEntry]

    struct ProjectStateEntry: Codable {
        var id: String
        var configPath: String?
        var layout: String?
        var focusedSessionId: String?
    }
}
```

All three parsed with Yams. One format, one parser, one mental model.

---

## 12. Notifications

```swift
func notifyAgentState(project: Project, session: Session) {
    guard session.agentState == .needsInput || session.agentState == .error else { return }

    let content = UNMutableNotificationContent()
    content.title = "\(project.name) — \(session.name)"
    content.body = session.agentState == .needsInput ? "Waiting for input" : "Error encountered"
    content.interruptionLevel = .timeSensitive
    content.userInfo = ["projectId": project.id.uuidString, "sessionId": session.id.uuidString]

    UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: "\(session.id)", content: content, trigger: nil)
    )
}
```

That's it. No notification manager class. A function is enough.

---

## 13. Performance Budgets

| Metric                           | Target  | Measurement                   |
| -------------------------------- | ------- | ----------------------------- |
| Keystroke → screen               | < 5ms   | Instruments signpost          |
| Frame render (4 sessions)        | < 4ms   | Metal GPU profiler            |
| Memory per session               | < 10MB  | Allocations instrument        |
| Memory baseline (no sessions)    | < 25MB  | Activity Monitor              |
| Startup to first frame           | < 200ms | signpost main() → present     |
| CPU idle (8 sessions, no output) | < 0.5%  | Activity Monitor              |
| I/O thread wake-to-render        | < 1ms   | signpost kevent → draw signal |

---

## 14. Implementation Phases

### Phase 0: Single Terminal (Weeks 1-4)

```
Week 1-2:
  □ Xcode project + SPM setup
  □ SwiftTermBackend implementing TerminalBackend protocol
  □ PTY spawn (forkpty) + single-fd read loop
  □ Verify: spawn zsh, type, see output in SwiftTerm state

Week 3-4:
  □ Metal renderer: GlyphAtlas + FontManager + single-session render
  □ MTKView with terminal rendering
  □ Wire: keystroke → PTY write → VT parse → Metal render
  □ Benchmark against Ghostty. Target: < 2x Ghostty latency.

Gate: If latency is > 3x Ghostty, investigate before proceeding.
```

### Phase 1: Projects + Agents (Weeks 5-12)

```
Week 5-6:
  □ PTYMultiplexer (kqueue, replaces single-fd loop)
  □ Session model + multi-session rendering (viewport scissoring)
  □ LayoutEngine (grid + focus)
  □ Session switching via keyboard

Week 7-8:
  □ Project model + ProjectStore
  □ Sidebar (SwiftUI List in NSHostingView)
  □ cosmodrome.yml parsing
  □ Auto-start / auto-restart logic

Week 9-10:
  □ AgentDetector (process identification + pattern matching)
  □ ModelDetector (scan output for model identifiers)
  □ ActivityLog (event extraction + in-memory timeline)
  □ Agent state badges on sessions (with model name)
  □ AgentStatusBar overlay (state + model per agent)
  □ Activity Log panel (Cmd+L slide-out, per-project)
  □ macOS notifications for needsInput / error

Week 11-12:
  □ CompletionActions (suggestion bar on task complete)
  □ Full keybinding system
  □ User config parsing
  □ State persistence (save/restore on quit/launch)
  □ Activity log persistence (flush to disk)
  □ Cold-start sequencing
  □ Performance audit

Deliverable: Alpha to 20-50 testers.
```

### Phase 2: Polish + libghostty (Weeks 13-18)

```
  □ GhosttyBackend (if C API ready) — swap SwiftTerm
  □ Agent patterns for Aider, Codex, Gemini
  □ Activity log search and filtering (by agent, by file, by time range)
  □ Completion action customization (per-project test command, review prompt)
  □ Theme support (dark + light + custom)
  □ Session thumbnails (low-fps preview)
  □ Command palette
  □ Git worktree integration

Deliverable: Public beta.
```

### Phase 3: v1.0 (Weeks 19-26)

```
  □ MCP server
  □ Session recording (asciicast)
  □ Linux port
  □ Homebrew distribution
  □ Documentation

Deliverable: v1.0 release.
```

---

## Hook Server Specification

### Overview
The Hook Server enables structured agent lifecycle events via Unix domain socket IPC.

### Components
- **CosmodromeHook** (separate executable): Tiny binary invoked by Claude Code's hooks system. Reads JSON from stdin, forwards to Unix socket at `$COSMODROME_HOOK_SOCKET`.
- **HookServer** (in Core): Listens on `$TMPDIR/cosmodrome-<pid>.sock`. Accepts connections, parses JSON into `HookEvent`, dispatches to `ActivityLog`.

### HookEvent Schema
```json
{
  "hook_name": "PreToolUse" | "PostToolUse" | "Notification" | "Stop",
  "session_id": "uuid-string",
  "tool_name": "Bash" | "Read" | "Write" | "Agent" | ...,
  "tool_input": "string",
  "tool_output": "string",
  "notification": "string",
  "stop_reason": "string"
}
```

### Environment Variables
Injected into all spawned sessions by `SessionManager.startSession()`:
- `COSMODROME_HOOK_SOCKET` — path to the Unix socket
- `COSMODROME_SESSION_ID` — UUID of the session

### Behavior
When hook events are received, `AgentDetector.hasHookData` is set to `true`, suppressing regex-based state detection. Hook events are authoritative.

---

## OSC 133 Command Tracker Specification

### Overview
`CommandTracker` processes OSC 133 semantic prompt markers to track shell command lifecycle.

### Markers
| Code | Meaning | Action |
|------|---------|--------|
| `A` | Prompt displayed | Mark ready for input |
| `B[;cmd]` | Command started | Record start time, optional command text |
| `C` | Output begins | (informational) |
| `D[;exitcode]` | Command finished | Fire `onCommandCompleted` with duration + exit code |

### Integration
Registered via `SwiftTermBackend.init()` using `terminal.registerOscHandler(code: 133)`. Completion events are logged as `ActivityEvent.EventKind.commandCompleted`.

---

## Modal Key Tables Specification

### Modes
- **Normal** (default): Modifier-based bindings (Cmd+T, Cmd+Shift+], etc.). Unmatched keys forwarded to PTY.
- **Command**: Single-letter vim-style bindings. ALL keys suppressed from PTY.

### Command Mode Bindings
| Key | Action |
|-----|--------|
| `j` | Next session |
| `k` | Previous session |
| `h` | Previous project |
| `l` | Next project |
| `n` | New session |
| `x` | Close session |
| `f` | Toggle focus |
| `g` | Toggle fleet overview |
| `p` / `/` | Command palette |
| `Escape` | Return to normal mode |

### Normal Mode Additions
| Shortcut | Action |
|----------|--------|
| `Cmd+Shift+F` | Toggle fleet overview |

### Mode Toggle
`Ctrl+Space` toggles between normal and command mode. Works in both modes.

### Visual Indicator
`ModeIndicatorView`: pill overlay in bottom-right corner showing "CMD" (blue) or "NORMAL" (gray). Fades after 2 seconds of inactivity.
