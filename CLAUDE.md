# CLAUDE.md — Cosmodrome

## What is Cosmodrome

A native macOS terminal emulator for developers who run multiple AI agents (Claude Code, Aider, Codex) in parallel across multiple projects. One window, all projects visible, agent state at a glance.

Built with Swift + AppKit + Metal + libghostty-vt. Not Electron. Not Tauri. Not a wrapper around tmux.

## Project Philosophy

**We are a terminal.** Not an IDE, not an editor, not a file manager. We render terminal output, manage PTY processes, and detect AI agent state. That's it.

**Performance is non-negotiable.** Every frame under 4ms. Every keystroke under 5ms to screen. If a change makes it slower, revert it. Profile before and after. No exceptions.

**Simplicity over cleverness.** Two layout modes (grid/focus), not four. Three agent states the user cares about (working/needsInput/error), not seven. One config format (YAML), not two. One Metal view, not N.

**Observe, never orchestrate.** We watch what agents do and surface it to the developer. We never send input to agents, never auto-trigger actions, never control agent behavior. Read-only observation, always.

**Ship, then polish.** Phase 0 is a single terminal that renders. Phase 1 adds projects and agents. If it doesn't serve Phase 0-1, it doesn't belong in the codebase yet.

## Architecture Overview

Read `ARCHITECTURE.md` for the full picture. Key points:

- **Terminal backend:** `TerminalBackend` protocol. Current implementation: SwiftTerm (pure Swift, ships now). Future: libghostty-vt (when C API stabilizes).
- **Rendering:** Single `MTKView` for the entire content area. Viewport scissoring per session. Shared glyph atlas. One command buffer per frame.
- **I/O:** Single thread with `kqueue` multiplexing all PTY file descriptors. Agent detection runs inline on output arrival, not on a separate polling thread.
- **State:** `@Observable` objects. No event bus, no Combine, no NotificationCenter for domain events. Direct property mutation, Observation framework propagates to UI.
- **Threading:** 2 threads total — main (UI + Metal) and I/O (kqueue + VT parsing + agent detection). GCD for background work (config watching, notifications).

## Tech Stack

| Layer      | Technology                                                                   |
| ---------- | ---------------------------------------------------------------------------- |
| Language   | Swift 5.10+                                                                  |
| UI         | AppKit (main window, terminal views) + SwiftUI (sidebar, overlays, settings) |
| Rendering  | Metal (custom glyph renderer)                                                |
| Font       | CoreText                                                                     |
| VT Parsing | SwiftTerm (Phase 0-1), libghostty-vt (Phase 2+)                              |
| PTY        | POSIX forkpty + kqueue multiplexer                                           |
| Config     | YAML via Yams                                                                |
| Build      | Swift Package Manager + Xcode                                                |
| Min target | macOS 14 (Sonoma)                                                            |

## Project Structure

```
Cosmodrome/
├── CLAUDE.md                    # You are here
├── PRD.md                       # Product requirements
├── ARCHITECTURE.md              # Architecture decisions & diagrams
├── SPEC.md                      # Technical specification
├── Package.swift                # SPM manifest
├── Cosmodrome.xcodeproj/        # Xcode project (for .app bundle)
│
├── Sources/
│   ├── CosmodromeHook/          # Tiny binary invoked by Claude Code hooks
│   │   └── main.swift           # Reads JSON from stdin, sends to Unix socket
│   │
│   ├── CosmodromeApp/           # App entry point, window management
│   │   ├── AppDelegate.swift
│   │   ├── MainWindowController.swift
│   │   └── Info.plist
│   │
│   ├── Core/                    # Domain logic (no UI imports)
│   │   ├── Terminal/
│   │   │   ├── TerminalBackend.swift       # Protocol (swappable VT backend)
│   │   │   ├── SwiftTermBackend.swift      # Current implementation
│   │   │   └── CommandTracker.swift        # OSC 133 semantic prompt tracking
│   │   ├── PTY/
│   │   │   ├── PTYMultiplexer.swift        # kqueue-based I/O loop
│   │   │   └── PTYProcess.swift            # Single PTY handle
│   │   ├── Agent/
│   │   │   ├── AgentDetector.swift         # Pattern matching + state + stats tracking (NSLock protected)
│   │   │   ├── AgentPatterns.swift         # Per-agent pattern definitions
│   │   │   ├── ActivityLog.swift           # Structured timeline + event grouping
│   │   │   ├── BufferStateScanner.swift    # TUI buffer cell scanning for agent state
│   │   │   ├── ModelDetector.swift         # Detect which LLM model is in use
│   │   │   ├── SessionNarrative.swift      # Heuristic narrative engine (zero LLM)
│   │   │   ├── StuckDetector.swift         # Error-retry loop detection
│   │   │   ├── SessionStats.swift          # Per-session usage stats (cost, tasks, files)
│   │   │   └── CompletionActions.swift     # Context-aware completion suggestions
│   │   ├── Hooks/
│   │   │   ├── HookServer.swift           # Unix socket server for agent hooks
│   │   │   └── HookEvent.swift            # Structured hook event model
│   │   ├── Project/
│   │   │   ├── Project.swift               # @Observable model
│   │   │   ├── Session.swift               # @Observable model
│   │   │   └── ProjectStore.swift          # CRUD + persistence
│   │   └── Config/
│   │       ├── ConfigParser.swift          # YAML parsing
│   │       └── UserConfig.swift            # App-level config
│   │
│   ├── Renderer/                # Metal rendering
│   │   ├── TerminalRenderer.swift          # Main render loop
│   │   ├── GlyphAtlas.swift               # CoreText → Metal texture
│   │   ├── FontManager.swift              # Font loading + metrics
│   │   └── Shaders/
│   │       └── Terminal.metal             # Vertex + fragment shaders
│   │
│   └── UI/                      # Views and controllers
│       ├── Sidebar/
│       │   └── SidebarView.swift          # SwiftUI project list
│       ├── Content/
│       │   ├── ContentController.swift    # Manages terminal grid
│       │   ├── TerminalView.swift         # NSView hosting Metal
│       │   └── LayoutEngine.swift         # Grid/Focus modes
│       ├── StatusBar/
│       │   └── AgentStatusBar.swift       # SwiftUI overlay + fleet stat badges
│       ├── FleetOverviewView.swift        # Fleet-wide agent dashboard overlay
│       ├── SessionThumbnail.swift         # Session card with agent status row
│       └── Input/
│           ├── KeybindingManager.swift    # Shortcut dispatch (normal + command modes)
│           └── InputEncoder.swift         # Key → escape sequence
│
├── Tests/
│   ├── CoreTests/
│   │   ├── AgentDetectorTests.swift
│   │   ├── BufferStateScannerTests.swift
│   │   ├── CompletionActionsTests.swift
│   │   ├── ConfigParserTests.swift
│   │   ├── PTYMultiplexerTests.swift
│   │   ├── SessionNarrativeTests.swift
│   │   ├── StuckDetectorTests.swift
│   │   └── LayoutEngineTests.swift
│   └── RendererTests/
│       └── GlyphAtlasTests.swift
│
└── Resources/
    ├── Themes/
    │   ├── dark.yml
    │   └── light.yml
    └── DefaultConfig.yml
```

## Coding Conventions

**Swift style:**

- `final class` by default. Only remove `final` when subclassing is intentional.
- `@Observable` for any model that drives UI. No Combine publishers.
- `struct` for value types, `class` only when identity or reference semantics matter.
- Avoid protocol-oriented programming for its own sake. A protocol is justified only when there are 2+ implementations (like `TerminalBackend`).
- No force-unwrapping outside tests. Use `guard let` or provide defaults.
- Prefer `throws` over `Result`. Prefer `async/await` over callbacks for async work.
- Access control: `private` by default, `internal` when needed by other files in the module, `public` only in the `Core` module's API surface.

**Metal:**

- All shaders in `Sources/Renderer/Shaders/Terminal.metal`.
- Shared structs between Swift and Metal go in a bridging header.
- Triple-buffered vertex data (3 buffers in rotation, no stalls).
- Never allocate per-frame. Reuse buffers.

**Naming:**

- Files match the primary type they contain (`Project.swift` contains `class Project`).
- Test files mirror source structure (`AgentDetectorTests.swift` tests `AgentDetector.swift`).
- No abbreviations in type names. `TerminalRenderer`, not `TermRend`. Variables and locals can abbreviate within reason.

**Dependencies:**

- Absolute minimum. Currently: SwiftTerm, Yams. That's it.
- No dependency for something achievable in <100 lines of Swift.
- Every new dependency needs justification in the PR description.

## Performance Rules

- **Profile before optimizing.** Use Instruments (Metal System Trace, Time Profiler, Allocations). No guessing.
- **Dirty tracking everywhere.** Only re-render rows that changed. Only rebuild vertex data for dirty sessions.
- **Lazy everything.** Non-visible sessions: no rendering. Glyph atlas: rasterize on first use. Config: parse on first access.
- **No allocation in the render loop.** The per-frame path must be allocation-free. Pre-allocate buffers, reuse them.
- **kqueue, not polling.** The I/O thread sleeps when there's no data. Zero CPU when idle.

## Testing

- Unit tests for all `Core/` logic: agent detection patterns, config parsing, layout calculations, state transitions.
- Integration tests for PTY: spawn a process, verify output flows through the backend.
- Performance tests with `measure {}` blocks for render frame time and VT parsing throughput.
- No UI tests in Phase 0-1. Manual testing for UI. Add XCUITest in Phase 2 if needed.
- Run tests before every commit: `swift test`

## Development Workflow

```bash
# Build and run
open Cosmodrome.xcodeproj    # For full .app with Metal
# OR
swift build                   # For Core module only (no Metal)

# Run tests
swift test

# Profile
# Use Xcode Instruments → Metal System Trace for rendering
# Use Xcode Instruments → Time Profiler for CPU
```

## Key Design Decisions

These are settled. Don't revisit without a strong reason and data.

1. **Single MTKView, not one per session.** Viewport scissoring is cheaper than N independent render loops.
2. **kqueue multiplexer, not thread-per-PTY.** One I/O thread handles all sessions. Scales to 20+ sessions without thread explosion.
3. **Agent detection inline on I/O, not polling.** When PTY output arrives, we're already on the I/O thread with the data. Pattern match right there.
4. **SwiftTerm first, libghostty-vt later.** Unblocks all UI and project work. The `TerminalBackend` protocol makes the swap trivial.
5. **@Observable, not event bus.** Direct mutation + Observation framework. Debuggable, fast, no indirection.
6. **3 agent states (working/needsInput/error) + inactive.** User-centric, not implementation-centric.
7. **Grid and Focus, not four layout modes.** Ship two, validate with users, add more if needed.
8. **Activity Log, not living spec.** We passively observe what agents do (files changed, tools used, errors hit) and present a structured timeline per project. We don't tell agents what to do — we tell the developer what happened. This is the terminal philosophy: observe, don't orchestrate.
9. **Facilitate, don't automate.** When an agent finishes a task, we suggest next actions ("Run tests?", "Open diff?", "Start review agent?"). We never auto-trigger actions. The developer decides.
10. **Model detection is passive.** We detect which model an agent is using from its output and show it in the status bar. We don't control model selection — that's the agent's job.

## What NOT to Build

- File editor or file tree browser
- LSP integration or code intelligence
- Built-in git UI
- Plugin/extension system
- Remote/SSH session management
- Worktree management
- Agent control API (send_input, write to PTY)
- Linux port
- External terminal orchestration
- Workflow automation or auto-triggered actions
- Anything that makes us an IDE

## Current Phase

**v0.1.0 released.** All foundation phases complete. See CHANGELOG.md for details.
