# Cosmodrome — UI/UX Audit & Improvement Plan

## Overview

This document is a comprehensive audit of Cosmodrome's current UI/UX with specific, actionable improvements. It's designed to be split across multiple Claude Code agents working in parallel on separate areas.

**Design principles for all changes:**
1. Information density without clutter — every pixel communicates state
2. Active vs inactive must be obvious at a glance — no squinting
3. The terminal is the star — chrome should recede, content should shine
4. Dark mode is the only mode — optimize for it, don't compromise
5. macOS native feel — respect platform conventions, feel at home next to Xcode and Instruments
6. Accessibility — minimum contrast ratios, keyboard navigability, VoiceOver support

---

## Agent 1: Sidebar & Session Cards

**Files likely involved:** Sidebar views, session card views, project list views

### Current Problems

1. **Active session is barely distinguishable from inactive ones.** The selected card has a subtle border change that's almost invisible. When you have 3+ sessions, you can't instantly tell which one is selected.

2. **State indicator dots are too small.** The colored dots (red for error, yellow for needs input, green for working) are ~6px and compete with surrounding text. State is the most important information and it's the smallest element.

3. **Too much text in each card.** Each card shows: name, agent name ("Claude"), state badge ("error"), percentage ("58% high"), permission mode ("Bypass"), and a number. This is 6 pieces of information in a ~80px tall card. Some of this can be consolidated or deprioritized.

4. **"Bypass" label doesn't communicate clearly.** New users won't know this means Claude Code's permission mode. It takes up valuable space without earning it.

5. **The project header "Cosmodrome 3 • (red badge) +" is dense.** The count, the dot, and the badge are too close together.

### Specific Changes

#### Active Session Highlighting

```
BEFORE: Subtle 1px border change on selected card
AFTER:  Three-layer differentiation:
  1. Left border accent: 3px solid bar in the state color (green/yellow/red)
     — this is the fastest visual signal
  2. Background tint: very subtle fill using the state color at 8-10% opacity
     — reinforces the left border without being loud
  3. Inactive cards dim: reduce opacity of non-selected cards to 0.6-0.7
     — the active card stands out by contrast, not just by its own styling
```

The combination of "active card is brighter + has colored left bar" and "inactive cards are dimmed" creates an unmistakable visual hierarchy.

#### State Indicators

```
BEFORE: Small colored dot (~6px) next to session name
AFTER:  The left border bar IS the state indicator (see above)
  - Green left bar = working
  - Yellow/amber left bar = needs input
  - Red left bar = error
  - Gray left bar (or no bar) = idle

  Additionally, keep a smaller dot in the status line for redundancy,
  but the primary signal is the left border.
```

#### Card Content Hierarchy

Restructure each card to have clear visual hierarchy:

```
┌─────────────────────────────────┐
│ ● active                    1   │  ← Name (bold) + session count (dimmed)
│   Claude · Opus 4.6 · 58%      │  ← Agent + model + context (secondary color, smaller)
│   ▲ error                       │  ← State badge (colored, prominent)
└─────────────────────────────────┘

Remove "Bypass" from the card. Move permission mode to:
  - The session detail view (when you focus the session)
  - Or a tooltip on hover
  - It's not glanceable information

Consolidate "58% high" into just the percentage.
"high" is the effort level — show it in the detail/tooltip, not the card.
```

#### Card Spacing

- Increase internal padding from current ~8px to 12px
- Increase gap between cards from ~4px to 8px
- Cards should breathe. Dense ≠ cramped.

#### Project Header

```
BEFORE: Cosmodrome  3 • 🔴 +
AFTER:  Cosmodrome                    3 sessions
        With a summary line below: 1 working · 1 needs input · 1 error
        The + button stays, but moves to the right edge with more padding
```

### Accessibility

- All state colors must pass WCAG AA contrast ratio against the card background
- State should never be communicated by color alone — the state text label ("error", "needs input") must always be present
- Cards must be keyboard-navigable: arrow keys to move between cards, Enter to focus
- VoiceOver should announce: "Session active, Claude Code, Opus 4.6, error state, 58% context"

---

## Agent 2: Bottom Status Bar & Tab Strip

**Files likely involved:** Status bar view, tab bar view, bottom chrome

### Current Problems

1. **Active tab is not clearly differentiated.** The current tab has a very subtle highlight. With 3 tabs at the bottom ("Cosmodrome/active error", "Cosmodrome/code review input", "Cosmodrome/bug fixing error"), they all look nearly identical.

2. **State dots in tabs are tiny.** Same problem as sidebar — the colored dots are too small to scan quickly.

3. **Tab names are long and clip.** "Cosmodrome/active error" is verbose. The project name repeats in every tab, wasting space.

4. **Right-side counters ("1 / 2 · 3 sessions") are low contrast.** Hard to read at a glance.

5. **Font size control ("← 17pt →") feels out of place** in the status bar — it's a configuration, not status.

### Specific Changes

#### Tab Differentiation

```
BEFORE: Subtle background change on active tab
AFTER:
  Active tab:
  - Background: elevated surface color (--surface-2 or similar, notably lighter than inactive)
  - Top border: 2px solid in state color
  - Text: full opacity white
  - State dot: 8px, state color

  Inactive tabs:
  - Background: transparent or base surface
  - No top border
  - Text: 50-60% opacity
  - State dot: 6px, state color at 70% opacity
```

#### Tab Content

```
BEFORE: ● Cosmodrome/active error
AFTER:  ● active                      — drop the project name prefix
        (project is already shown in sidebar, repeating it wastes space)

        If multiple projects are open, use a minimal prefix:
        ● Cosmo/active  (abbreviated project name)
```

#### Status Bar Right Section

```
BEFORE: ← 17pt → +  (font size controls mixed with status)
AFTER:
  Left section:  tabs (as above)
  Right section:  2 ● 1 ▲    3 sessions
                  (green dot count, red triangle count, total)

  Move font size controls to:
  - Command palette (Cmd+P → "Font size")
  - Or keyboard shortcuts only (Cmd+/Cmd-)
  - Not in the persistent status bar
```

#### Summary Indicators

The right side should show a fleet overview at all times:

```
● 2  ◐ 1  ▲ 1     — 2 working, 1 needs input, 1 error
```

Using distinct shapes (filled circle, half circle, triangle) in addition to colors ensures accessibility. Users can scan the bottom bar to know fleet status without looking at the sidebar.

### Accessibility

- Tab strip must be keyboard-navigable: Cmd+[ and Cmd+] (already planned)
- Active tab must have `accessibilityTraits: .isSelected`
- Status indicators use both color AND shape (circle, triangle) for color-blind users

---

## Agent 3: Terminal Rendering & Focus Mode

**Files likely involved:** Metal renderer, MTKView, viewport scissoring, terminal content area

### Current Problems

1. **Grid view sessions have no visual boundary.** When multiple sessions are visible in grid, it's hard to tell where one session ends and another begins.

2. **The focused session in grid isn't obvious enough.** Same active/inactive problem as sidebar and tabs.

3. **Terminal content area has no breathing room.** Text starts very close to the left edge. A small inset would improve readability.

4. **The divider between sidebar and terminal is a hard line.** Could be softer.

### Specific Changes

#### Grid View Session Borders

```
BEFORE: Sessions sit edge-to-edge with no visible separation
AFTER:
  Each session cell gets:
  - 1px border in --border-subtle (very dim, just enough to see the boundary)
  - 4px gap between cells (grid gap)
  - Rounded corners: 6px radius on the terminal content area
  - The focused cell gets: brighter border (--border-active) + subtle glow/shadow
```

#### Focus Indication in Grid

```
BEFORE: Minimal visual difference between focused and unfocused sessions
AFTER:
  Focused session:
  - Border: 1px solid with state color at 40% opacity
  - Very subtle outer glow: 0 0 8px state-color at 15% opacity
    (this is Metal rendering, so it's a simple bloom pass, not CSS)
  - Full brightness terminal content

  Unfocused sessions:
  - Border: 1px solid --border-subtle
  - Terminal content at 85% brightness (slight dim)
  - This dim is enough to notice, not enough to make content unreadable
```

#### Terminal Content Inset

```
BEFORE: Text starts at x=0 from the terminal edge
AFTER:  Add 8px left padding to terminal content
  - This gives the text room to breathe
  - Matches how iTerm2, Ghostty, and other modern terminals handle it
  - Configurable in config.yml: terminal.padding: 8
```

#### Sidebar Divider

```
BEFORE: Hard 1px line between sidebar and terminal
AFTER:
  Option A: 1px line at 15% opacity (barely visible, implied boundary)
  Option B: No line at all — sidebar has a different background shade,
            the contrast creates the boundary naturally

  Prefer Option B. Less chrome = more content.
```

#### Session Header in Terminal Area

Above each terminal session (visible in grid view and focus view), add a minimal info bar:

```
┌──────────────────────────────────────────────────┐
│ ● active  Claude · Opus 4.6  ctx: 58%    3m 12s │  ← session header
├──────────────────────────────────────────────────┤
│ $ claude                                         │
│ > Working on bug fix...                          │  ← terminal content
│                                                  │
```

This header:
- Shows the same info as the sidebar card but in context
- Updates in real-time (especially with JSONL watcher)
- Height: 24px, minimal
- Background: slightly different shade than terminal (--surface-1)
- Can be hidden with a config option for users who want max terminal space

### Metal Rendering Improvements

#### Glyph Rendering Quality

- Ensure subpixel antialiasing is enabled for text rendering
- Test glyph atlas at different font sizes — common issue is blurry glyphs when atlas is generated at one size and rendered at another
- Verify that the shared glyph atlas handles different fonts gracefully (SF Mono + any user-configured font)

#### Smooth Scrolling

- Current: investigate if scrolling is frame-locked to display refresh
- Ensure scroll events produce smooth, interpolated movement
- Add momentum scrolling (trackpad gesture continuation after finger lift)
- This may relate to the phantom scroll bug — fix that first, then polish

#### Cursor Rendering

- Cursor blink should be smooth (opacity fade), not binary (on/off)
- Cursor in focused session: full brightness, blinking
- Cursor in unfocused session: dim, not blinking (static block at 30% opacity)

---

## Agent 4: Activity Log Redesign

**Files likely involved:** Activity log view, event model, filtering logic

### Current Problems

1. **The log is a wall of state transitions.** "error → needsInput", "needsInput → error" repeated dozens of times. This is raw machine data, not human-readable information.

2. **No visual grouping.** Events from different sessions mix together chronologically with only a header to separate them. Hard to scan.

3. **Meaningful events are buried.** "Task completed", "Read 1", "Find keyboard shortcut setup" are the useful events, but they're drowning in transition noise.

4. **The summary bar at top is good but underutilized.** "2 tasks completed · 1 files changed · 0 errors · 3 sessions" is exactly right. More of this, less of the raw log.

### Specific Changes

#### Default View: Smart Summary (not "All")

```
BEFORE: Default tab is "All 43" showing every event
AFTER:  Default view is "Summary" — a filtered, grouped view:

  code review · needs input · Claude                    40 events
  ├─ ✓ Task completed                           16:57
  ├─ 📁 Wrote: sources/ActivityLogView.swift    16:57
  ├─ ⚠️ Waiting for your input                  16:58
  └─ 12 state transitions (collapsed)

  active · error · Claude                               2 events
  └─ Started                                     16:57

  Timeline:
  ├─ 16:51  🔍 Find keyboard shortcut setup
  ├─ 16:54  📖 Read 1 file
  ├─ 16:56  ▶️ Started working
  ├─ 16:56  ✓ Task completed (0s)
  ├─ 16:57  ▶️ Started working
  ├─ 16:57  ✓ Task completed (0s)
  └─ 16:58  📁 Wrote: sources/
```

Key changes:
- State transitions are **collapsed by default** — show count, expandable
- Only meaningful events shown: file ops, commands, completions, errors
- Each event has an icon for fast scanning
- Sessions are collapsible groups

#### State Transition Collapsing

```
BEFORE:
  16:58  error → needsInput
  16:58  needsInput → error
  16:58  error → needsInput
  16:58  needsInput → error
  (... 12 more)

AFTER:
  16:57-16:58  ↻ 16 state transitions (error ↔ needsInput)
               [expand to see all]

  This is a detection issue too — rapid oscillation between
  error and needsInput probably means the detection patterns
  are fighting each other. Flag this for investigation.
```

#### Event Icons & Colors

Consistent icon system for scanability:

```
▶️  Started working          (green, dimmed)
✓   Task completed           (green, bright)
📖  Read file                (blue, dimmed)
📁  Wrote/created file       (blue, bright)
⚡  Ran command              (purple)
⚠️  Waiting for input        (yellow)
❌  Error                    (red)
🔍  Search/find              (gray)
↻   State transitions        (gray, collapsed)
```

#### Time Display

```
BEFORE: 16:58 on every single line (repetitive)
AFTER:
  Group by minute, show time once:

  16:58
    ✓ Task completed
    📁 sources/
    ↻ 4 state transitions

  16:57
    ▶️ Started working
    ✓ Task completed
    📖 Read 1 file
```

#### "What happened while I was away" Banner

When the user hasn't interacted for >5 minutes and comes back:

```
┌─────────────────────────────────────────────────┐
│ While you were away (12 minutes):               │
│ ✓ 2 tasks completed  📁 1 file changed          │
│ ⚠️ 1 agent needs your input                     │
│                              [Dismiss] [Details] │
└─────────────────────────────────────────────────┘
```

This appears at the top of the activity log (or as a notification). It's the single most valuable piece of UI in Cosmodrome — the answer to "what happened?"

### Accessibility

- All event types distinguishable without color (icons provide shape distinction)
- Collapsed sections announce their count to VoiceOver
- Keyboard navigation: arrow keys through events, Enter to expand collapsed groups

---

## Agent 5: Command Palette & Notifications

**Files likely involved:** Command palette view, notification system, macOS notification integration

### Command Palette

The command palette (screenshot 3) is already clean. Minor improvements:

#### State Indicators in Results

```
BEFORE: Focus active [error]          — text only
AFTER:  🔴 Focus active               — colored dot + cleaner label
        🟡 Focus code review
        🔴 Focus bug fixing
```

Remove the bracketed state text. The dot communicates it faster.

#### Search Improvements

- Fuzzy matching: "act err" should find "Focus active [error]"
- Recent commands section: show last 3-5 used commands at the top before search results
- Category headers: "Sessions", "Projects", "Settings", "Actions" to group results

#### Keyboard Shortcut Display

```
BEFORE: New Shell Session    Cmd+T       — shortcut right-aligned
AFTER:  Same, but ensure consistent column alignment
        All shortcuts should align at the same x position
        Use monospace for shortcut display (already likely SF Mono)
```

### Notification System

#### macOS Notifications with Context

```
BEFORE: Generic "Agent needs input" notification
AFTER:
  Title: "code review needs input"
  Body: "Claude is asking: Apply changes to auth.ts?"
  — include what the agent is actually asking, not just that it's asking

  This requires parsing the agent's last output line when state
  changes to needsInput. With JSONL watching, this data is available.
```

#### In-App Notification Badges

```
Sidebar session cards already show state. Add:
- Unread indicator: small blue dot on sessions that changed state
  since you last looked at them
- Clear on focus: when you click/focus a session, its unread indicator clears
- This is the same pattern as unread messages in Slack/Discord
```

#### Notification Preferences

In settings or config.yml:

```yaml
notifications:
  needs_input: true      # notify when agent needs input
  error: true            # notify on errors
  completed: false       # notify on task completion (off by default, can be noisy)
  sound: false           # play sound with notification

  # Smart notification: only notify if you haven't interacted
  # with Cosmodrome for more than N seconds
  idle_threshold: 30
```

The `idle_threshold` prevents notification spam when you're actively working in Cosmodrome. Only notify when you're likely away or in another app.

---

## Agent 6: Color System & Typography Audit

**Files likely involved:** Theme definitions, color constants, font configuration

### Color System

Define a strict, documented color palette:

#### Backgrounds (darkest to lightest)

```
--bg-base:       #1A1A1C    Base window background
--bg-surface-1:  #222224    Sidebar, panels
--bg-surface-2:  #2A2A2D    Cards, elevated elements
--bg-surface-3:  #333336    Hover states, active elements
--bg-terminal:   #1A1A1C    Terminal background (matches base)
```

#### Text

```
--text-primary:    #E8E8E8    Primary text (not pure white — too harsh)
--text-secondary:  #999999    Secondary text, labels
--text-tertiary:   #666666    Hints, timestamps, dimmed info
--text-inverse:    #1A1A1C    Text on colored backgrounds
```

#### State Colors (the most important colors in the app)

```
--state-working:      #34C759    Green — alive, not neon
--state-working-dim:  #34C75933  Green at 20% — for background tints
--state-input:        #FFD60A    Amber — warm, urgent
--state-input-dim:    #FFD60A33  Amber at 20%
--state-error:        #FF453A    Red — clear, not aggressive
--state-error-dim:    #FF453A33  Red at 20%
--state-idle:         #666666    Gray — neutral, recedes
```

These are Apple's system colors adapted for dark mode. They feel native.

#### Brand Accent

```
--brand:          #5DCAA5    Teal — for links, highlights, brand elements
--brand-dim:      #5DCAA533  Teal at 20%
```

#### Borders

```
--border-subtle:   #FFFFFF0F    White at 6% — barely visible boundaries
--border-default:  #FFFFFF1A    White at 10% — standard borders
--border-active:   #FFFFFF33    White at 20% — focused/active elements
```

### Typography

```
Terminal:
  Font: SF Mono (default), user-configurable
  Size: 13px (default), user-configurable
  Line height: 1.2

UI Chrome:
  Font: SF Pro Text (system font)

  Sizes:
    --font-xs:   11px    Timestamps, tertiary info
    --font-sm:   12px    Secondary labels, card details
    --font-base: 13px    Primary UI text, card titles
    --font-lg:   14px    Section headers, project names

  Weights:
    Regular (400):  Body text, secondary info
    Medium (500):   Card titles, active labels, headers

  Never use Bold (700) in the UI. Medium is enough for hierarchy.
  The terminal content is already visually dense — the chrome
  should be lighter in weight to recede.
```

### Contrast Verification

Every text/background combination must pass WCAG AA (4.5:1 ratio minimum):

```
--text-primary on --bg-base:       #E8E8E8 on #1A1A1C  = 13.2:1 ✓
--text-secondary on --bg-base:     #999999 on #1A1A1C  = 6.3:1  ✓
--text-tertiary on --bg-base:      #666666 on #1A1A1C  = 3.7:1  ✗ (AA fail)
  → Bump to #737373 for 4.5:1                                    ✓

--state-working on --bg-surface-2: #34C759 on #2A2A2D  = 6.8:1  ✓
--state-input on --bg-surface-2:   #FFD60A on #2A2A2D  = 10.1:1 ✓
--state-error on --bg-surface-2:   #FF453A on #2A2A2D  = 5.2:1  ✓
```

Run a full contrast audit on every combination used in the app.

---

## Parallel Execution Plan

Each agent works on their area independently. Here's the dependency map:

```
Agent 6 (Colors & Typography) → should go FIRST
  ↓ defines the color system all other agents use

Agent 1 (Sidebar) ──────┐
Agent 2 (Status Bar) ───┤ can run in PARALLEL after Agent 6
Agent 3 (Terminal) ─────┤
Agent 4 (Activity Log) ─┤
Agent 5 (Cmd Palette) ──┘
```

**Agent 6 starts first** to establish the color palette and typography constants. Once those are committed, the other 5 agents can work simultaneously without stepping on each other — they're modifying different view files.

### Shared Rules for All Agents

1. Use the color variables defined by Agent 6. Never hardcode hex values in views.
2. All spacing uses multiples of 4px: 4, 8, 12, 16, 20, 24, 32.
3. All border-radius uses: 4px (small elements), 6px (cards), 8px (panels), 12px (modals).
4. Animation duration: 150ms for micro-interactions, 250ms for transitions. Easing: ease-out.
5. No new fonts or weights beyond what's defined in the typography system.
6. Test every change in both grid view and focus view.
7. Test with 1 session, 3 sessions, and 10+ sessions.
8. Ensure no regression in frame rendering time (<4ms target).
