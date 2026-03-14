# ROADMAP.md — Cosmodrome post-v0.1.0

**Strategic lens:** EIID (Enrichment → Inference → Interpretation → Delivery)
**Guiding principle:** Don't add screens. Improve the invisible layers within existing views.
**Date:** March 2026

---

## Current state (v0.1.0)

| EIID Layer     | Status        | Assessment                                                                                             |
| -------------- | ------------- | ------------------------------------------------------------------------------------------------------ |
| Enrichment     | **Strong**    | Competitive advantage. Zero-config PTY observation, hooks, BufferStateScanner, OSC. User changes nothing. |
| Inference      | **Primitive** | Regex/pattern matching works. No confidence scoring, no urgency, no loop/conflict detection.           |
| Interpretation | **Gap**       | Activity log shows raw state transitions. No narrative, no grouping, no "what should I do about this." |
| Delivery       | **Generic**   | macOS notifications exist but say "needs input" without context. No channel routing, no timing logic.  |

**Three views, no more:** Sidebar + Terminal + Activity Log/Fleet Overview. The roadmap improves quality inside these views, never adds new screens.

---

## v0.2 — "Understand, don't just see" (Interpretation layer)

> The single biggest value jump. Raw events become actionable narrative.

### Session Narrative

Each session produces a real-time summary that replaces raw state labels everywhere (thumbnails, fleet cards, status bar).

| Today                          | Target                                                                        |
| ------------------------------ | ----------------------------------------------------------------------------- |
| "working"                      | "Refactoring auth module — 8 files changed, 2 tests failing, 12 min elapsed" |
| "needsInput"                   | "Waiting for approval to delete test fixtures"                                |
| "error"                        | "Compile error in auth.ts — 3rd retry"                                        |
| "inactive"                     | "Completed auth refactor. 15 files, tests passing, 23 min, $4.20"            |

**Implementation:**
- New: `SessionNarrative` in `Core/Agent/` — consumes `ActivityLog` events + current state → produces human-readable summary string
- Modified: `SessionThumbnail` — shows narrative instead of state label
- Modified: `FleetOverviewView` — narrative per agent card
- Modified: `AgentStatusBarView` — narrative in tooltip/expanded view

### Activity Log Grouping

Related events collapse into logical units. The "Smart" filter becomes genuinely smart.

| Today                                             | Target                                        |
| ------------------------------------------------- | --------------------------------------------- |
| 15 separate `fileWrite` events                    | "Modified auth module (15 files)"             |
| 3 error → stateChanged → error events             | "3 failed compile fix attempts on auth.ts"    |
| taskStarted → 20 events → taskCompleted           | Collapsible task block with summary header    |

**Implementation:**
- Modified: `ActivityLog` — event grouping by file path cluster + time window
- Modified: `ActivityLogView` — grouped events with narrative headers, collapsible task blocks

### Stuck Detection

If an agent is in an error→retry loop for >N minutes, the UI says "stuck" not "working". This is interpretation: it adds the judgment *"this needs your attention"* to the raw data *"error"*.

**Implementation:**
- Modified: `AgentDetector` or new lightweight `StuckDetector` — counts recent error transitions from `ActivityLog`
- Modified: `SessionThumbnail` + `FleetOverviewView` — "stuck" badge with duration

### Richer Completion Actions

When a task finishes, `CompletionActions` shows full context instead of bare buttons.

| Today                       | Target                                                                    |
| --------------------------- | ------------------------------------------------------------------------- |
| "Open diff" / "Run tests"  | "Completed: auth refactor. 15 files, tests passing. 23 min, $4.20."      |
|                             | → Open diff · Run tests · Start review agent                             |

**Implementation:**
- Modified: `CompletionActions` — receives context from `SessionNarrative`

### What doesn't change
- No new screens or views
- No agent control or orchestration
- No LLM calls — narrative is built from heuristics and domain logic (zero cost, zero latency, works offline)

---

## v0.3 — "What matters, how much" (Inference depth)

> Inference today answers "what changed." This phase adds "for whom" and "with what urgency."

### Confidence Scoring

Every state detection carries a confidence level. `BufferStateScanner` already does this for Claude Code (high/medium/none) — extend to all agents. Low confidence = softer UI treatment.

**Implementation:**
- New: `ConfidenceLevel` enum in Core
- Modified: `AgentDetector` — outputs confidence with every state change
- Modified: UI — low-confidence states rendered with reduced visual weight

### Urgency Classification

Combines state + duration + context into an urgency level that drives both UI styling and delivery routing (v0.4).

| State + Context                        | Urgency      |
| -------------------------------------- | ------------ |
| `needsInput` for <2 min               | Low          |
| `needsInput` for 2-5 min              | Medium       |
| `needsInput` for >5 min               | High         |
| `error` after 3+ retries              | Critical     |
| `working` normally                     | None         |
| `stuck` (from v0.2)                   | High         |

**Implementation:**
- New: `UrgencyLevel` enum (none/low/medium/high/critical)
- New: urgency computation in `AgentDetector` or `SessionNarrative`
- Modified: UI — urgency-driven colors, pulse animation, sort order in fleet view

### Loop Detection

Detects agents stuck in retry loops (same error pattern repeating). Surfaces as "looping" indicator — more informative than "working" when the agent is spinning for 10 minutes.

**Implementation:**
- New: `LoopDetector` in `Core/Agent/` — tracks last N errors per session, detects repetition patterns
- Modified: `SessionNarrative` — incorporates loop state into narrative ("stuck in compile loop, 3 identical errors")

### Cross-Agent File Conflict

Detects when 2+ agents in the same project are modifying the same files. Visual warning, never blocking.

*"Claude Code (api-v2) and Aider (auth) are both touching src/auth/middleware.ts."*

**Implementation:**
- New: `ConflictDetector` in `Core/Agent/` — cross-session file path tracking from `ActivityLog`
- Modified: `SessionThumbnail` + `FleetOverviewView` — conflict warning badge

### Cost Velocity

Not just total cost but burn rate. "$2.50/min on opus" is more actionable than "$47 total".

**Implementation:**
- Modified: `SessionStats` — burn rate calculation (cost delta / time delta over sliding window)
- Modified: `AgentStatusBarView` + `FleetOverviewView` — sparkline shows velocity, not just accumulation

---

## v0.4 — "Right message, right channel, right time" (Delivery refinement)

> Today's delivery: macOS notification saying "needs input". Target: the right information, where it matters, when it matters.

### Context Extraction

When an agent enters `needsInput`, read the terminal buffer to extract *what* it's asking. "Claude Code needs approval to delete test fixtures" not "needs input".

**Implementation:**
- Modified: `BufferStateScanner` — extract prompt/question text from buffer when state = needsInput
- Modified: `SessionNarrative` — includes prompt context in narrative

### Channel Routing

Based on urgency level (from v0.3):

| Urgency    | Channel                                    |
| ---------- | ------------------------------------------ |
| Critical   | macOS notification + sound                 |
| High       | macOS notification (silent)                |
| Medium     | Sidebar badge + status bar highlight       |
| Low        | Status bar only                            |
| None       | Nothing                                    |

**Implementation:**
- New: `NotificationRouter` in Core — decides channel + timing based on urgency
- Modified: `AgentNotifications` — uses router instead of direct notification dispatch

### Debouncing

Don't fire on every state transition. Wait for stable state (e.g., 5 seconds in `needsInput` before notifying). Prevents notification spam from rapid state flickers.

**Implementation:**
- Modified: `NotificationRouter` — debounce timer per session, configurable threshold

### Session Digest

When all agents in a project go idle, show a summary entry in the activity log: *"Session complete: 4 tasks, 12 files modified, $23 spent, 1 intervention required."* Not a new screen — a special entry in the existing activity log.

**Implementation:**
- Modified: `ActivityLog` — digest event type
- Modified: `ActivityLogView` — digest entries rendered as collapsible summary section

---

## v0.5 — "Deeper signals" (Enrichment expansion)

> Enrichment is already the strongest layer. This phase widens and deepens it.

### Structured Data Priority

When hooks provide structured data (Claude Code), use it as primary source over regex. Structured data = better inference = better narrative. Regex remains as fallback for agents without hooks.

**Implementation:**
- Modified: `AgentDetector` — hook events override regex when available, with explicit priority

### Cross-Session Task Linking

Detect when sessions in the same project are working on related tasks (same files, same code area). Show in fleet view: "2 agents working on auth module."

**Implementation:**
- New: task linking logic in `ConflictDetector` (extends v0.3 conflict detection with cooperative framing)
- Modified: `FleetOverviewView` — grouped task indicators

### Community Agent Patterns

Lower the barrier to support new agents as they emerge. Contributable pattern format with built-in test harness.

**Implementation:**
- Pattern definition format (YAML or Swift) with example output + expected state
- Test harness that validates patterns against sample output

---

## Dependency graph

```
v0.2 (Interpretation)  ← highest priority, unblocks everything
  │
  ├── SessionNarrative is the foundation
  │   ├── Activity log grouping feeds into narrative
  │   ├── Stuck detection feeds into narrative
  │   └── Completion context consumes narrative
  │
v0.3 (Inference depth)  ← builds on v0.2
  │
  ├── Urgency + confidence enrich the narrative
  ├── Loop detection feeds stuck detection
  │
v0.4 (Delivery)  ← requires v0.3 for smart routing
  │
  ├── Channel routing uses urgency levels
  ├── Context extraction uses buffer scanning
  │
v0.5 (Enrichment)  ← independent, can parallelize with v0.3/v0.4
```

**Start with `SessionNarrative`** — it's the single piece of code that changes the experience most.

---

## What's NOT on this roadmap

| Excluded                  | Why                                                                                       |
| ------------------------- | ----------------------------------------------------------------------------------------- |
| New screens/views         | EIID: 3 views, not 30. Improve invisible layers.                                         |
| Agent control/input       | "Observe, never orchestrate" is the philosophy. Non-negotiable.                           |
| LLM-powered summaries     | Heuristics first. Zero cost, zero latency, works offline. LLM is a future add-on, not a dependency. |
| Plugin/extension system   | Solve interpretation first, then open extensibility.                                      |
| IDE features              | No file editor, LSP, git UI, file tree. We are a terminal.                                |
| Linux port                | Focus on macOS excellence. Revisit when the core experience is right.                     |

---

## How to track progress

Each version gets a branch. Each feature within a version gets a commit or small PR. Update the status column below as work progresses.

### v0.2 Checklist

- [x] `SessionNarrative` — core narrative engine
- [x] Activity log event grouping
- [x] Stuck detection
- [x] Richer completion actions with context
- [x] Integrate narrative into SessionThumbnail
- [x] Integrate narrative into FleetOverviewView
- [x] Integrate narrative into AgentStatusBarView
- [x] Tests for SessionNarrative (10 tests)
- [x] Tests for event grouping (4 tests in StuckDetectorTests)
- [x] Tests for stuck detection (5 tests)
- [x] Tests for CompletionActions (12 tests)
- [x] Bug fixes: mode badge, task completion notification, case-insensitive ctx, status timeout, CWD resolution, thread safety

### v0.3 Checklist

- [ ] `ConfidenceLevel` enum + integration
- [ ] `UrgencyLevel` enum + computation
- [ ] `LoopDetector`
- [ ] `ConflictDetector`
- [ ] Cost velocity in SessionStats
- [ ] Urgency-driven UI styling
- [ ] Tests for all new detectors

### v0.4 Checklist

- [ ] Context extraction from terminal buffer
- [ ] `NotificationRouter` with channel routing
- [ ] Notification debouncing
- [ ] Session digest entries in activity log
- [ ] Tests for routing logic

### v0.5 Checklist

- [ ] Structured hook data priority in AgentDetector
- [ ] Cross-session task linking
- [ ] Community pattern format + test harness
