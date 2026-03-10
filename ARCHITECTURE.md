# Architecture: Cosmodrome

**Version:** 1.1  
**Date:** March 2026

---

## System Overview

Cosmodrome is a native macOS terminal emulator. It embeds multiple GPU-accelerated terminal instances organized by project, with real-time AI agent state detection.

```
┌─────────────────────────────────────────────────────────────────┐
│                     Cosmodrome.app (Swift)                       │
│                                                                  │
│  ┌─── UI ──────────────────────────────────────────────────────┐│
│  │ Sidebar (SwiftUI)  │  Content (MTKView)  │ StatusBar (SwUI) ││
│  │                    │  ┌───────┬───────┐  │                  ││
│  │ Project A  ●       │  │ Sess1 │ Sess2 │  │ 🟢 A/cc opus work ││
│  │ Project B  ○       │  │       │       │  │ 🟡 B/cc snnt input││
│  │ Project C  ●       │  ├───────┼───────┤  │                  ││
│  │                    │  │ Sess3 │ Sess4 │  │                  ││
│  │                    │  └───────┴───────┘  │                  ││
│  └────────────────────────────────────────────────────────────┘│
│                                                                  │
│  ┌─── Core ────────────────────────────────────────────────────┐│
│  │ ProjectStore │ TerminalBackend (protocol) │ AgentDetector  ││
│  │              │ ActivityLog · ModelDetector · CompletionActions│
│  └──────────────────────────────────────────────────────────────┘│
│                                                                  │
│  ┌─── I/O ─────────────────────────────────────────────────────┐│
│  │              PTYMultiplexer (kqueue)                          ││
│  │  fd1 ──► VT parse ──► dirty rows ──► render signal           ││
│  │  fd2 ──► VT parse ──► agent detect ──► state update          ││
│  │  fd3 ──► VT parse ──► dirty rows ──► render signal           ││
│  └──────────────────────────────────────────────────────────────┘│
│                                                                  │
│  ┌─── Platform ────────────────────────────────────────────────┐│
│  │  Metal  ·  CoreText  ·  kqueue  ·  forkpty  ·  UNNotification│
│  └──────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

---

## Key Decisions

### 1. TerminalBackend Protocol — Not Locked to One VT Parser

libghostty-vt is the ideal VT parser (SIMD-optimized, battle-tested by Ghostty), but its C API is in alpha. We define a thin protocol and start with SwiftTerm (pure Swift, available now). When libghostty-vt's C API stabilizes, we swap the implementation. Zero impact on the rest of the codebase.

```swift
protocol TerminalBackend {
    func process(_ bytes: UnsafeRawBufferPointer)
    func cell(row: Int, col: Int) -> TerminalCell
    func resize(cols: UInt16, rows: UInt16)
    func cursorPosition() -> (row: Int, col: Int)
    var rows: Int { get }
    var cols: Int { get }
    var dirtyRows: IndexSet { get }
    func clearDirty()
}
```

This is the only protocol in the project that exists purely for swappability. Every other abstraction is a concrete type.

### 2. Single MTKView — Not One Per Session

All visible terminal sessions render in a single Metal view via viewport scissoring. One render pass, one command buffer, one `present()` per frame.

```
Single MTKView covers entire content area
┌──────────────────────────────────┐
│ ┌──────────┐  ┌──────────┐      │
│ │ viewport │  │ viewport │      │  One render pass:
│ │ Session A│  │ Session B│      │    for each visible session:
│ │ scissor  │  │ scissor  │      │      set scissor rect
│ └──────────┘  └──────────┘      │      set viewport
│ ┌──────────┐  ┌──────────┐      │      draw backgrounds
│ │ viewport │  │ viewport │      │      draw glyphs
│ │ Session C│  │ Session D│      │      draw cursor
│ └──────────┘  └──────────┘      │
└──────────────────────────────────┘
```

Why not N MTKViews: each creates its own CAMetalLayer, CADisplayLink, and command buffer. With 8 sessions, that's 8x pipeline setup and 8x `present()` calls. Single view eliminates all of that.

Trade-off: hit-testing for mouse input requires mapping coordinates to sessions. This is trivial geometry.

### 3. kqueue Multiplexer — Not Thread-Per-PTY

A single I/O thread multiplexes all PTY file descriptors using macOS `kqueue`. When no PTY has data, the thread sleeps (zero CPU). When data arrives, `kevent()` returns only the ready FDs.

```
One I/O Thread
    │
    ▼
 kevent() blocks until data on any PTY fd
    │
    ├── fd 3 ready → read → VT parse → dirty rows → agent detect → notify main
    ├── fd 5 ready → read → VT parse → dirty rows → notify main
    └── fd 7 ready → read → VT parse → dirty rows → agent detect → notify main
```

Why not thread-per-PTY: with 8 sessions, that's 8 threads × 512KB stack = 4MB just for stacks, plus context switching overhead and synchronization complexity. The kqueue approach scales to 50+ sessions on a single thread.

Agent detection runs inline: when PTY output arrives for an agent session, pattern matching runs immediately on the I/O thread with the data already in hand. No separate polling thread, no extra latency.

### 4. @Observable — Not Event Bus

State flows through `@Observable` model objects. When `session.agentState` changes, the UI updates automatically via the Observation framework. No event bus, no Combine, no NotificationCenter for domain events.

```swift
// Setting state is the only thing needed. Observation handles the rest.
session.agentState = .needsInput
// → Sidebar badge updates
// → Status bar updates
// → Notification fires (if configured)
```

Why not an event bus: in a single-process desktop app, components have direct access to shared state. An event bus adds indirection that makes debugging harder ("who emitted this? who consumed it?") without providing distribution benefits.

### 5. Three Agent States — Not Seven

The user cares about three questions: Is the agent working? Does it need me? Did something break?

```
AgentState:
  .inactive   — Not an agent, or idle (no indicator)
  .working    — Thinking, executing tools, streaming (green)
  .needsInput — Waiting for approval/response (yellow, triggers notification)
  .error      — Something failed (red, triggers notification)
```

The pattern matcher maps output directly to these states. No formal state machine, no transition table. The pattern matcher is the single source of truth.

---

## Threading Model

```
Main Thread
├── AppKit event loop
├── Metal rendering (MTKViewDelegate.draw)
├── UI updates via @Observable
└── Notification scheduling

I/O Thread (single, kqueue)
├── kevent() — blocks until PTY data arrives
├── read() — reads from ready FDs
├── VT parse — feeds bytes to TerminalBackend
├── Agent detect — pattern match on agent sessions
└── Signals main thread for redraw

GCD (background, as needed)
├── Config file watching (FSEvents)
├── cosmodrome.yml parsing
└── State persistence (periodic save)
```

Total threads at runtime: **2 dedicated + GCD pool**. Not N+3.

Hook Server (GCD utility queue)
├── Unix domain socket listener ($TMPDIR/cosmodrome-<pid>.sock)
├── Accepts connections from CosmodromeHook binary
├── Parses JSON → HookEvent
└── Dispatches to main thread for ActivityLog

---

## Rendering Pipeline

```
Per frame (triggered by I/O thread signaling dirty sessions):

Terminal State → Dirty Check → Glyph Lookup → Vertex Buffer → GPU

    Glyph Atlas (shared across all sessions)
    ┌──────────────────────────────────┐
    │ CoreText rasterizes on first use │
    │ Cached in Metal texture (4K×4K)  │
    │ One variant per glyph (no sub-px)│
    └──────────────────────────────────┘

    Render Pass (single, all sessions)
    ┌──────────────────────────────────┐
    │ 1. Background rects (instanced)  │
    │ 2. Glyph quads (instanced)       │
    │ 3. Cursor                        │
    │ 4. Decorations (underline, etc.) │
    └──────────────────────────────────┘
```

Key optimizations:

- Only dirty rows regenerate vertex data
- Non-visible sessions skip rendering entirely
- Glyph atlas shared across all sessions (single set of textures)
- Triple-buffered vertex data (no GPU stalls)
- No per-frame allocation

---

## Data Model

```swift
Project (1) ──── (N) Session
   │                    │
   │ name, color        │ name, command, args, cwd
   │ rootPath           │ autoStart, autoRestart
   │ configPath         │ isAgent, agentType
   │ activityLog ◄──────│
   │                    │ (runtime, not persisted)
   │ (computed)          │ agentState: AgentState
   │ aggregateState     │ agentModel: String?  ("opus", "sonnet", "gpt-5.4")
   │ attentionCount     │ backend: TerminalBackend
   │                    │ ptyFD: Int32
```

Both Project and Session are `@Observable`. Changing any property automatically updates bound UI. The `agentModel` is detected from output and shown in the status bar next to the agent state indicator.

---

## Agent Detection Pipeline

```
PTY output arrives on I/O thread
    │
    ▼
Is this session's foreground process an agent?
(check via ioctl TIOCGPGRP + sysctl → process name)
    │
    ├── No → skip, just mark dirty rows
    │
    └── Yes → Three parallel extractions from the same output:
              │
              ├── 1. STATE DETECTION
              │   Pattern match last N lines
              │   ├── Spinner chars, streaming → .working
              │   ├── "allow/deny", "[y/n]" → .needsInput
              │   ├── "error", "failed" → .error
              │   └── None matched → keep current state
              │
              ├── 2. MODEL DETECTION
              │   Scan for model identifiers in output
              │   ├── "claude-opus-4-6", "opus" → model: opus
              │   ├── "claude-sonnet-4-6", "sonnet" → model: sonnet
              │   ├── "gpt-5.4" → model: gpt-5.4
              │   └── Cache last detected model (changes rarely)
              │
              ├── 3. ACTIVITY LOGGING
              │   Extract structured events from output
              │   ├── "Read file: src/..." → FileRead event
              │   ├── "Write file: src/..." → FileWrite event
              │   ├── "Bash: npm test" → CommandRun event
              │   ├── "error: ..." → ErrorEvent
              │   └── Append to project's ActivityLog
              │
              ▼
         Debounce (300ms) → update session.agentState
         Check: did state change to .inactive from .working?
              │
              └── Yes → Trigger CompletionActions suggestions
                        (show "Open diff" / "Run tests" / "Start review" bar)
```

All three extractions run inline on the I/O thread from the same output bytes. No extra passes, no extra threads. The ActivityLog append is a simple array push — no disk I/O in the hot path (persisted lazily on a GCD background queue).

Patterns are hardcoded per agent type (Claude Code first, Aider/Codex added when needed). No plugin system, no config-driven patterns until validated with real usage.

## Activity Log

The Activity Log is a per-project, append-only timeline of agent events. It answers one question: **"What happened while I wasn't watching?"**

```
Project: API v2
────────────────────────────────────────────
14:32  claude-1 (opus)  Started working
14:32  claude-1         Read src/auth/middleware.ts
14:33  claude-1         Read src/auth/types.ts
14:33  claude-1         Write src/auth/jwt.ts (new file)
14:34  claude-1         Write src/auth/middleware.ts (+45 -12)
14:34  claude-1         Bash: npm run test:auth
14:35  claude-1         ⚠ Test failed: 2 failures
14:35  claude-1         Write src/auth/jwt.ts (+8 -3)
14:36  claude-1         Bash: npm run test:auth
14:36  claude-1         ✓ All tests passed
14:36  claude-1 (opus)  Task completed (4m 12s)
                        → [Open diff] [Run tests] [Start review]
```

Key design choices:

- **Passive observation only.** We parse agent output for file operations and commands. We never inject anything into the PTY or communicate with the agent.
- **Per-project, not per-session.** All agent sessions within a project feed into a single timeline, giving a unified view.
- **In-memory first.** The log lives in RAM as a `[ActivityEvent]` array. Flushed to disk periodically (every 60s) and on quit. No SQLite, no database.
- **Bounded.** Max 10,000 events per project. Oldest events are evicted when the limit is hit.

## Completion Actions

When an agent finishes a task (state transitions from `.working` to `.inactive`), Cosmodrome shows a transient suggestion bar at the bottom of that session's terminal view:

```
┌──────────────────────────────────────────────────────────────┐
│ ✓ Task completed (4m 12s, 3 files changed)                   │
│   [Open diff]  [Run tests]  [Start review agent]  [Dismiss]  │
└──────────────────────────────────────────────────────────────┘
```

Actions:

- **Open diff** — runs `git diff` in a new session, scoped to files the agent touched
- **Run tests** — launches the project's test command in a new session
- **Start review agent** — opens a new Claude Code session pre-filled with: "Review the changes in [list of files] and check for bugs, edge cases, and style issues"
- **Dismiss** — hides the bar, does nothing

The bar auto-dismisses after 30 seconds if untouched. Never blocks input. Never auto-executes. The developer always chooses.

This is not a verifier pattern (like Intent). We don't validate against a spec. We facilitate the developer's natural next step after an agent finishes work.

---

## Cold-Start Sequence

When Cosmodrome launches with saved projects:

1. Render window + sidebar + empty grids immediately (< 100ms)
2. Start sessions for the active (visible) project first
3. Start sessions for other projects, staggered (200ms apart)
4. Agent sessions (Claude Code) launch last (heaviest)
5. Non-auto-start sessions remain stopped until user action

Goal: window is interactive within 200ms. All sessions running within 3-5 seconds.

---

## File Format: cosmodrome.yml

Single config format for everything. Parsed with Yams.

```yaml
name: "API v2"
color: "#4A90D9"

sessions:
  - name: "Claude Code"
    command: "claude"
    agent: true
    auto_start: true

  - name: "Dev Server"
    command: "npm run dev"
    auto_start: true
    auto_restart: true
    restart_delay: 2

  - name: "Database"
    command: "docker compose up postgres"
    auto_start: true

layout: grid
```

App state (`~/Library/Application Support/Cosmodrome/state.yml`) uses the same YAML format for window position, open projects, and session state.

---

## Hook Server (Structured Agent Events)

Claude Code (and other agents) can emit structured lifecycle events via hooks.
Cosmodrome receives these through a Unix domain socket IPC mechanism:

```
CosmodromeHook binary          Cosmodrome App
(invoked by Claude Code)       (HookServer on GCD queue)
        │                              │
        ├── reads stdin (JSON)         │
        ├── reads $COSMODROME_HOOK_SOCKET
        ├── connects to Unix socket ──→├── accepts connection
        ├── sends JSON ──────────────→├── reads JSON
        └── exits                      ├── parses → HookEvent
                                       ├── maps → ActivityEvent
                                       └── appends to ActivityLog
```

When hook data is received, the `AgentDetector` suppresses regex-based state
detection in favor of the structured events (hooks are more reliable).

Environment variables injected into spawned sessions:
- `COSMODROME_HOOK_SOCKET` — path to the Unix socket
- `COSMODROME_SESSION_ID` — UUID of the session

---

## OSC 133 Semantic Prompts

Shells that support OSC 133 emit escape sequences marking prompt/command boundaries:

| Marker | Meaning | What we do |
|--------|---------|------------|
| `A` | Prompt shown | Mark session as "ready for input" |
| `B` | Command started | Record start time |
| `C` | Output starts | (informational) |
| `D;exitcode` | Command finished | Log `commandCompleted` event with duration and exit code |

Handled by `CommandTracker` (registered as an OSC handler in `SwiftTermBackend`).

---

## Modal Keybindings

Two modes: **Normal** (default) and **Command**.

- **Normal mode:** Modifier-based shortcuts (Cmd+T, Cmd+Shift+], etc.). All other keys forwarded to PTY.
- **Command mode:** Single-letter vim-style navigation (j/k = session, h/l = project, n = new, x = close, f = focus, p = palette). Keys NOT forwarded to PTY.
- Toggle: `Ctrl+Space`. Exit command mode: `Escape`.

---

## What We Don't Build

| Explicitly excluded                       | Why                                                                        |
| ----------------------------------------- | -------------------------------------------------------------------------- |
| Agent orchestration / coordinator pattern | We observe agents, we don't direct them. The developer is the coordinator. |
| Living specs / spec-driven development    | We have an activity log (passive observer), not a spec (active director).  |
| Automatic verifier / auto-review          | We suggest "start review agent?" — we never auto-trigger it.               |
| Model selection / model switching         | We detect and display the model. The agent controls its own model.         |
| Event bus / message broker                | @Observable is sufficient for a single-process app                         |
| Formal state machine for agents           | Pattern matcher is the source of truth                                     |
| Health check HTTP pings                   | Terminal shows process alive/dead, not app health                          |
| Memory pressure monitor                   | 8 sessions × 10MB = 80MB. macOS has 16-64GB. Not needed.                   |
| Sub-pixel glyph rendering                 | Retina displays make it imperceptible. Apple deprecated it.                |
| Plugin system                             | Until v1.0 at earliest                                                     |
