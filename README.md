# Cosmodrome

**A native macOS terminal emulator for developers running multiple AI agents in parallel.**

One window. All projects visible. Agent state at a glance.

[![Release](https://img.shields.io/github/v/release/rinaldofesta/cosmodrome)](https://github.com/rinaldofesta/cosmodrome/releases/latest)
[![Build](https://github.com/rinaldofesta/cosmodrome/actions/workflows/ci.yml/badge.svg)](https://github.com/rinaldofesta/cosmodrome/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple)](https://developer.apple.com/macos/)

<p align="center">
  <img src="Resources/AppIcon_1024.png" alt="Cosmodrome" width="256" />
</p>

Cosmodrome is built for developers who routinely run Claude Code, Aider, Codex, or Gemini across multiple projects. Instead of juggling terminal tabs and windows, Cosmodrome organizes terminals by project with a shared GPU-rendered view, detects what each AI agent is doing in real time, and surfaces the information that matters: which agents need your input, which are working, and which hit errors.

Built with Swift, AppKit, and Metal. No Electron. No Tauri. No tmux wrapper.

---

## Features

### Activity Log -- "What happened while I was away"

The hero feature. A full-screen overlay (`Cmd+L`) showing a structured timeline of everything your agents did: files changed, commands run, errors encountered, cost per task. Sessions are grouped and collapsible, sorted by most recent activity. Filter by time window (last hour, today, all), by event type (files, commands, errors), or by session.

Come back from lunch, open the Activity Log, and see exactly what 5 agents accomplished while you were gone.

### Fleet Overview

Full-screen dashboard (`Cmd+Shift+F`) showing all agents across all projects. Agent cards sorted by priority (needs input first, then errors, then working, then idle). Filter by state. Aggregate stats: total cost, tasks completed, files changed.

### GPU-Accelerated Rendering

A single Metal `MTKView` renders all visible terminal sessions via viewport scissoring. Shared glyph atlas, triple-buffered vertex data, no per-frame allocations. Sub-4ms frame times.

### Project-First Organization

Group terminals by project, not by tab order. Each project defines its sessions in a `cosmodrome.yml` file: dev servers, databases, AI agents -- all launched and managed together.

### AI Agent State Detection

Cosmodrome automatically detects Claude Code, Aider, Codex, and Gemini sessions and reports their state:

| State | Indicator | Meaning |
|-------|-----------|---------|
| Working | Green | Agent is thinking, streaming, or executing tools |
| Needs Input | Yellow | Agent is waiting for approval or a response |
| Error | Red | Something failed |
| Inactive | -- | Idle or not an agent session |

### Cost Tracking

Per-session and per-task cost tracking with fleet-wide aggregation. See how much each agent is spending, average cost per task, and total fleet cost. Cost history with sparkline visualization.

### Claude Code Hooks Integration

Deep integration with Claude Code via structured hooks. Cosmodrome receives real-time JSON events for every tool use (file reads, writes, commands, subagent spawns) with structured data extraction: file paths, exit codes, cost deltas. Hook events are authoritative -- when available, they supersede regex-based state detection.

### Model Detection

Detects which LLM model each agent is using (Opus, Sonnet, GPT-4, etc.) and displays it in the status bar.

### Session Narrative

Raw state labels are replaced with contextual descriptions everywhere in the UI. "Working" becomes "Editing auth module -- 8 files, 2m". "Error" becomes "Stuck: compile error (5x, 3m)". "Inactive" becomes "Done. 15 files, tests passing, 23 min, $4.20." Built from heuristics -- zero LLM calls, zero latency, works offline.

### Stuck Detection

When an agent is stuck in an error-retry loop (3+ cycles), Cosmodrome surfaces it as "stuck" with retry count and duration instead of showing a misleading "working" state. The developer knows immediately that intervention is needed.

### Completion Actions

When an agent finishes a task, Cosmodrome shows a rich summary ("Editing auth module. 15 files, tests passing, 5m, $4.20.") and suggests context-aware next steps -- "Open diff", "Re-run tests (were failing)", "Start review agent" -- without ever auto-triggering them.

### Session Recording

Record terminal sessions in asciicast v2 format for playback and sharing.

### MCP Server

JSON-RPC 2.0 server over stdio for programmatic observation: list projects, query agent states, read terminal content, get fleet stats, get activity log.

### CLI Control Plane

`cosmoctl` provides command-line access to a running Cosmodrome instance via Unix socket.

### Additional Features

- **Command palette** (`Cmd+P`) for quick access to all actions
- **Modal keybindings** with vim-style command mode (`Ctrl+Space`)
- **Theme system** with dark, light, and custom YAML themes
- **OSC 133 semantic prompt tracking** for shell integration
- **Session persistence** with scrollback restoration across restarts
- **Native macOS notifications** for agent state changes
- **Grid and Focus layout modes** -- grid for overview, focus for deep work
- **Font zoom** (`Cmd+=`/`Cmd+-`) with persistence

### Philosophy

**Observe, never orchestrate.** Cosmodrome watches what your agents do and tells you what happened. It never sends input to agents, never auto-triggers actions, and never controls agent behavior. The developer is always in the loop.

---

## Requirements

- macOS 14 (Sonoma) or later
- A GPU that supports Metal (all Macs since 2012)

For building from source:
- Swift 5.10+ toolchain (Xcode or Command Line Tools)
- Xcode (for running tests and building DMG)

---

## Installation

### DMG (recommended)

Download the latest `.dmg` from [GitHub Releases](https://github.com/rinaldofesta/cosmodrome/releases), open it, and drag Cosmodrome to Applications.

### Homebrew Cask

```bash
brew install --cask cosmodrome
```

### Build from Source

```bash
git clone https://github.com/rinaldofesta/cosmodrome.git
cd cosmodrome

# Build release + create .app bundle
bash scripts/bundle.sh

# Install
cp -r build/Cosmodrome.app /Applications/
```

### Build DMG from Source

```bash
# Ad-hoc signed (local dev):
bash scripts/build-dmg.sh

# Developer ID signed (for distribution):
bash scripts/build-dmg.sh --sign "Developer ID Application: Your Name (TEAMID)"

# Output: build/Cosmodrome.dmg
```

### Run Without Installing

```bash
swift build
.build/debug/CosmodromeApp
```

---

## Usage

### Launch

Open Cosmodrome from `/Applications`, Spotlight, or the command line:

```bash
# With MCP server enabled (for AI agent integration)
/Applications/Cosmodrome.app/Contents/MacOS/Cosmodrome --mcp
```

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+T` | New session |
| `Cmd+W` | Close session |
| `Cmd+1-9` | Switch project |
| `Cmd+Enter` | Toggle focus mode |
| `Cmd+P` | Command palette |
| `Cmd+L` | Activity log |
| `Cmd+Shift+F` | Fleet overview |
| `Cmd+Shift+N` | Jump to next agent needing input |
| `Cmd+]` / `Cmd+[` | Next / previous project |
| `Cmd+Shift+]` / `Cmd+Shift+[` | Next / previous session |
| `Cmd+=` / `Cmd+-` | Zoom in / out |
| `Cmd+0` | Reset font size |
| `Ctrl+Space` | Toggle command mode |

**Command mode** (vim-style, after `Ctrl+Space`):

| Key | Action |
|-----|--------|
| `j` / `k` | Next / previous session |
| `h` / `l` | Previous / next project |
| `n` | New session |
| `x` | Close session |
| `f` | Toggle focus mode |
| `p` or `/` | Open command palette |
| `a` | Activity log |
| `g` | Fleet overview |
| `Escape` | Exit command mode |

### CLI Control

```bash
# Symlink cosmoctl for convenience
ln -s /Applications/Cosmodrome.app/Contents/MacOS/cosmoctl /usr/local/bin/cosmoctl

# Query running instance
cosmoctl status
cosmoctl list-projects
cosmoctl list-sessions
cosmoctl focus <session-id>
cosmoctl content <session-id> --lines 50

# Fleet and activity
cosmoctl fleet-stats
cosmoctl activity --since 60 --category files
cosmoctl activity --session <session-id>
```

### MCP Tools

When launched with `--mcp`, Cosmodrome exposes these tools via JSON-RPC 2.0 over stdio:

| Tool | Description |
|------|-------------|
| `list_projects` | List all projects with agent states |
| `list_sessions` | List sessions for a project |
| `get_session_content` | Get visible terminal content |
| `get_agent_states` | All agent states across all projects |
| `focus_session` | Switch focus to a session |
| `start_recording` / `stop_recording` | Asciicast session recording |
| `get_fleet_stats` | Fleet-wide statistics |
| `get_activity_log` | Activity timeline with filters |

---

## Claude Code Hooks Setup

To enable deep integration with Claude Code, add Cosmodrome's hook to your Claude Code configuration:

**`~/.claude/settings.json`:**

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "type": "command",
        "command": "/Applications/Cosmodrome.app/Contents/MacOS/CosmodromeHook"
      }
    ],
    "PostToolUse": [
      {
        "type": "command",
        "command": "/Applications/Cosmodrome.app/Contents/MacOS/CosmodromeHook"
      }
    ],
    "Notification": [
      {
        "type": "command",
        "command": "/Applications/Cosmodrome.app/Contents/MacOS/CosmodromeHook"
      }
    ],
    "Stop": [
      {
        "type": "command",
        "command": "/Applications/Cosmodrome.app/Contents/MacOS/CosmodromeHook"
      }
    ]
  }
}
```

With hooks enabled, Cosmodrome receives structured JSON events for every tool use, providing:
- Authoritative agent state detection (no regex guessing)
- File paths, commands, and exit codes from tool use
- Cost tracking from notification events
- Subagent spawn/completion tracking

---

## Configuration

### Project Configuration

Create a `cosmodrome.yml` in your project root:

```yaml
name: "My Project"
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

  - name: "Shell"
    command: "zsh"

layout: grid
```

### User Configuration

Global settings live in `~/.config/cosmodrome/config.yml`:

```yaml
font:
  family: "SF Mono"
  size: 13

theme: dark

notifications:
  agent_needs_input: true
  agent_error: true
  agent_complete: false

scrollback_lines: 10000
```

### State Persistence

Application state (window position, open projects, session state, scrollback) is saved automatically to:

```
~/Library/Application Support/Cosmodrome/
```

---

## Architecture

Cosmodrome uses a minimal threading model: one main thread (UI + Metal rendering) and one I/O thread (kqueue-based PTY multiplexer + VT parsing + agent detection). No thread-per-session, no event bus, no Combine.

Key decisions:

- **Single MTKView** for all sessions (viewport scissoring, not N render loops)
- **kqueue multiplexer** for all PTY I/O (scales to 50+ sessions on one thread)
- **Agent detection inline on I/O** (pattern match when data arrives, no polling)
- **@Observable** for state propagation (direct mutation, no indirection)
- **SwiftTerm** for VT parsing now, **libghostty-vt** when its C API stabilizes
- **Hook events authoritative** when available, regex fallback otherwise

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full picture.

---

## Performance

| Metric | Target |
|--------|--------|
| Input latency | < 5ms keystroke to screen |
| Frame render | < 4ms per frame |
| Memory per session | < 10MB |
| Startup to interactive | < 200ms |
| CPU when idle | < 0.5% |

---

## Project Structure

```
Sources/
  Core/              Domain logic (no UI imports)
    Terminal/           TerminalBackend protocol + SwiftTerm implementation
    PTY/                kqueue multiplexer + PTY process management
    Agent/              State detection, model detection, activity log, session stats
    Hooks/              Unix socket server for structured agent events
    Project/            Project + Session models, persistence
    Config/             YAML parsing, user configuration
    Control/            Unix socket control server for CLI
    MCP/                Model Context Protocol server (JSON-RPC 2.0)

  CosmodromeApp/     App entry point, window management
    UI/                 Sidebar, content area, status bar, command palette,
                        fleet overview, activity log, keybindings

  CosmodromeHook/    Tiny binary for Claude Code hooks integration
  CosmodromeCLI/     CLI control tool (cosmoctl)

scripts/
  bundle.sh            Build .app bundle from SPM
  build-dmg.sh         Build + sign + package as DMG
  release.sh           Tag + build + prepare GitHub release
```

---

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a pull request.

Key guidelines:
- Profile before optimizing. Use Instruments, not guesswork.
- No new dependencies without justification. Currently: SwiftTerm, Yams. That's it.
- `final class` by default. `@Observable` for models. No force-unwrapping outside tests.
- Run `swift build` before submitting.

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

---

## Acknowledgments

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) -- terminal emulator library by Miguel de Icaza
- [Yams](https://github.com/jpsim/Yams) -- YAML parser for Swift
- [Ghostty](https://ghostty.org) -- inspiration for the VT backend architecture
