# PRD: Cosmodrome

**Version:** 1.1  
**Date:** March 2026  
**Status:** Final

---

## The Problem

The developer workflow has fundamentally changed. Senior developers, tech leads, and CTOs now orchestrate 4-6 projects simultaneously, each with AI agents (Claude Code, Aider, Codex) running in parallel alongside dev servers, databases, and test runners.

Current tools fail this workflow in four ways:

**Context switching is constant.** With Ghostty + Aerospace (or any tiling WM), each project lives on a separate desktop. Switching between them means losing visual context of what's happening elsewhere. There's no satellite view.

**Agent state is invisible.** Is Claude Code thinking? Finished? Waiting for approval? Crashed? The only way to know is to physically navigate to that window. No notifications, no status indicators, no glanceable signals.

**Existing tools are inadequate.** tmux-based tools (Claude Squad, Agent Deck) have no GPU rendering and dated UX. Solo is a process manager but not a terminal. VS Code terminals are slow and constrained. Ghostty is excellent but has no concept of "project" or "agent state."

**Cognitive overhead compounds.** Remembering which window contains which project, which agent is doing what, which terminal has server logs — this mental load destroys productivity.

---

## The Vision

Cosmodrome is a native terminal emulator — as fast as Ghostty — with project-awareness and AI agent-awareness that doesn't exist anywhere else.

One window. All projects visible. Every agent's state at a glance. Jump to any session with a keystroke.

### Design Principles

1. **Ghostty-grade performance** — Metal GPU rendering, minimal latency, small memory footprint. Not Electron.
2. **Project-first** — The organizational unit is the project, not the tab. Each project groups its terminal sessions, processes, and agents.
3. **Agent-aware** — The terminal understands when a process is an AI agent and tracks its state: working, needs input, error.
4. **Glanceable** — One look tells you what's happening across all projects without entering any session.
5. **Keyboard-first** — Everything reachable via shortcuts. Mouse works too.
6. **Zero-config start** — Works immediately. Configuration is optional.

---

## Target User

**Primary: "The Orchestrator"** — Senior developer or tech lead working on 3-8 projects simultaneously, using Claude Code daily, running macOS, valuing performance above all. Currently frustrated by context switching between Ghostty/iTerm2 windows and desktops.

**Secondary: "The Team Lead"** — Manages a team using AI agents. Needs shared project configurations (`cosmodrome.yml` in repos) to standardize workflows.

---

## MVP Features (v0.1)

### Project Sidebar

Left sidebar listing all active projects. Each shows: name, color indicator, session count, aggregate agent state (green/yellow/red), attention badge for sessions needing input.

Click a project → shows its terminal sessions in the main area.

### Multi-Terminal Grid

Each project has N terminal sessions. Two layout modes:

- **Grid** — All sessions visible in auto-calculated grid (2x2, 3x2, etc.)
- **Focus** — One session fullscreen, toggle with `Cmd+Enter`

Each session displays: title, agent state indicator (if detected), current working directory.

### Agent State Detection

Automatic detection of AI agent processes and their state:

- **Working** — Agent is thinking, generating tokens, or executing tools (green indicator, no action needed)
- **Needs Input** — Agent is waiting for approval or user response (yellow indicator, requires attention)
- **Error** — Something failed (red indicator, investigate)

Detection works by identifying the foreground process name (claude, aider, codex) and matching output patterns. No agent cooperation required.

### Agent Status Bar

Persistent bar showing all agents across all projects. Each entry shows: agent name, state indicator, and **the model in use** (e.g., "opus", "sonnet", "gpt-5.4") detected from agent output. Click any entry to jump to that session.

### Activity Log

A lightweight, per-project timeline that answers: "what did my agents do while I wasn't looking?"

The log captures events passively from terminal output — no agent cooperation required:

- Files created, modified, or deleted (detected from tool-use output patterns)
- Commands executed by agents
- Errors encountered
- Tasks started and completed
- Model switches

The log is **not** a living spec and **not** an orchestration tool. It's a structured observer. You glance at it to catch up, not to direct work.

Accessible via a slide-out panel (`Cmd+L`) or in the sidebar per project.

### Completion Actions

When an agent transitions from `working` to `inactive` (task completed), Cosmodrome shows a non-intrusive suggestion bar:

- **"Open diff"** — show git changes since the agent started
- **"Run tests"** — launch test runner in a new session
- **"Start review"** — spawn a new agent session with a review prompt pre-filled
- **Dismiss** — do nothing

These are suggestions, never auto-triggered. The developer chooses. The terminal philosophy: facilitate, don't orchestrate.

### Keyboard Navigation

- `Cmd+1-9` → switch project
- `Cmd+Shift+1-9` → switch session within project
- `Cmd+Enter` → toggle focus mode
- `Cmd+Shift+N` → jump to next agent needing input
- `Cmd+L` → toggle activity log panel
- `Cmd+T` → new session
- `Cmd+Shift+T` → new project

### Project Configuration

`cosmodrome.yml` in project root, committable to version control:

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
  - name: "Database"
    command: "docker compose up postgres"
    auto_start: true
```

### Notifications

Native macOS notifications when an agent needs input, encounters an error, or completes a long task. Configurable per event type. Respects Focus/DND.

---

## Future Features (Post-MVP)

- Live session thumbnails with low-FPS preview rendering
- Activity log search and filtering (by agent, by file, by time range)
- Completion action customization (user-defined actions per project)
- Git worktree integration for agent isolation
- Smart session templates (auto-detect project stack)
- MCP server for programmatic agent-to-terminal interaction
- Session recording and replay
- Structured agent lifecycle hooks (Claude Code hooks API via Unix socket IPC)
- OSC 133 semantic prompt tracking (command completion with exit code + duration)
- Modal keybinding modes (vim-style command mode for navigation)
- Subagent tracking in activity log (nested events for spawned agents)
- External terminal orchestration (Ghostty AppleScript integration)
- Linux port (GTK4 + OpenGL)

---

## Competitive Landscape

| Capability             | Ghostty | tmux tools | Solo    | Intent           | **Cosmodrome**   |
| ---------------------- | ------- | ---------- | ------- | ---------------- | ---------------- |
| GPU rendering          | ✅      | ❌         | N/A     | ❌               | ✅               |
| Native OS              | ✅      | ❌         | Tauri   | ❌               | ✅               |
| Project organization   | ❌      | ❌         | ✅      | ✅               | ✅               |
| Agent state detection  | ❌      | basic      | ❌      | ✅               | ✅               |
| Agent activity log     | ❌      | ❌         | ❌      | ✅ (living spec) | ✅ (passive)     |
| Model detection        | ❌      | ❌         | ❌      | ✅               | ✅               |
| Completion actions     | ❌      | ❌         | ❌      | ✅ (verifier)    | ✅ (suggestions) |
| Multi-project overview | ❌      | ❌         | ✅      | per-workspace    | ✅               |
| Interactive terminal   | ✅      | via tmux   | limited | secondary        | ✅               |
| BYOA (any CLI agent)   | N/A     | ✅         | N/A     | partial          | ✅ (native)      |
| Memory footprint       | ~30MB   | ~15MB      | ~20MB   | heavy            | target ~40MB     |

---

## Performance Targets (Non-Negotiable)

- Input latency: < 5ms
- Startup to first frame: < 200ms
- Memory per session: < 10MB
- Framerate: 120fps on ProMotion
- CPU idle (no output): < 0.5%

---

## Risks

| Risk                                    | Mitigation                                                                                       |
| --------------------------------------- | ------------------------------------------------------------------------------------------------ |
| libghostty C API not ready in time      | Start with SwiftTerm (Swift VT parser). `TerminalBackend` protocol enables swap.                 |
| Agent detection inaccurate              | Start with Claude Code only. Pattern library grows with usage. Manual override always available. |
| Scope creep toward IDE                  | Mantra: "terminal, not editor." No file editing, no LSP, no file tree.                           |
| Performance degrades with many sessions | Single MTKView, kqueue multiplexer, lazy rendering. Budget enforced per frame.                   |

---

## Roadmap

**Phase 0 (4 weeks):** Single terminal session rendering. Prove architecture performance.  
**Phase 1 (8 weeks):** Multi-project, multi-session, agent detection. Alpha release.  
**Phase 2 (6 weeks):** Thumbnails, worktrees, additional agent support. Public beta.  
**Phase 3 (8 weeks):** MCP server, recording, Linux port. v1.0 release.
