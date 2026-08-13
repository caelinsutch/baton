# Baton — agent-to-human task handoff for macOS

Working name: **Baton**. The agent passes the baton to you, then takes it back.
Alternatives: Checkpoint, Standby, Relay, Nudge, Interrupt.

## 1. The problem

You run many coding agents across many git worktrees. An agent reaches a point
where it needs you:

- "Review this diff before I commit."
- "Open <http://localhost:5173> and confirm the modal closes."
- "I can migrate with A or B. Which one?"
- "This deletes 400 lines. Approve?"

Today the agent blocks in a terminal tab you are not looking at. You lose track
of which worktree waits on which decision. Agents also guess instead of asking,
because asking costs them nothing but gets no answer.

Baton makes the ask cheap for the agent and cheap for you.

## 2. Core loop

1. The agent calls an MCP tool: `submit_task`.
2. Baton stores the task and sends a notification.
3. You act. You read the diff, open the link, run the check.
4. You mark the task done, or you send it back with a note.
5. The agent reads the result and continues.

## 3. Architecture

### 3.1 The store is the source of truth

Do not make the app a required broker. Use a SQLite database on disk in WAL
mode:

```text
~/Library/Application Support/dev.baton/tasks.db
```

Both the app and the MCP binary open the same database. This means:

- The agent can submit a task when the app is not running.
- The app can crash without losing the queue.
- No socket protocol to design or version.
- Blocking waits become a 250 ms poll on one row. Simple and reliable.

The MCP binary also sends a wake ping over a Unix domain socket. The app polls
every 2 seconds as a fallback. Use SQLite `BEGIN IMMEDIATE` for writes to avoid
`SQLITE_BUSY` between processes.

### 3.2 Two transports for MCP

Ship one Swift package with two products:

| Product | Type | Use |
| --- | --- | --- |
| `Baton.app` | SwiftUI app bundle | UI, notifications, HUD |
| `baton-mcp` | CLI binary | MCP server over stdio |

The CLI is the primary path. Every agent harness supports stdio MCP. Each agent
spawns its own `baton-mcp` process. The processes share the database.

Also expose MCP Streamable HTTP on `127.0.0.1` from inside the app. This lets a
harness connect by URL with no binary to install. Bind to loopback only and
require a bearer token stored in the Keychain.

```text
Agent A ──▶ baton-mcp (stdio) ──┐
Agent B ──▶ baton-mcp (stdio) ──┼──▶ tasks.db (SQLite WAL) ◀── Baton.app
Agent C ──▶ HTTP 127.0.0.1 ─────┘                                  │
                                                                    ▼
                                                    Notifications, HUD, palette
```

### 3.3 Blocking vs non-blocking

This is the most important design choice. Do not make one tool that blocks
forever. Harnesses kill a tool call after a timeout, and a blocked agent burns
wall-clock time.

Split it:

- `submit_task` returns a task id at once. Never blocks.
- `await_task(id, timeout_s)` blocks up to `timeout_s`, default 120, max 900.
  It returns the response, or `status: "pending"` so the agent can loop or end
  its turn.
- `get_task(id)` is a cheap non-blocking read.

The agent chooses its own patience. A short-lived agent submits and ends its
turn. A long-running agent awaits.

For pi, a completed task can wake the originating session. Store the pi session
id on the task, then post a wake event on response. This is the ideal path: the
agent stops polling and Baton pushes.

## 4. Data model

```swift
struct Task {
  var id: String                 // ULID, sortable by time
  var createdAt, updatedAt: Date
  var respondedAt: Date?
  var status: Status             // pending, active, snoozed, done, sentBack,
                                 // expired, cancelled
  var kind: Kind                 // reviewDiff, openURL, approve, choose,
                                 // verify, input, generic
  var priority: Priority         // low, normal, high, urgent
  var title: String              // <= 60 chars, fits a notification
  var body: String?              // markdown detail

  var agent: AgentRef            // name, harness, model, sessionId, pid
  var repo: RepoRef?             // root, worktreePath, branch, headSha, isDirty

  var links: [Link]              // label, url, openIn: browser|editor|terminal
  var diff: DiffRef?             // baseRef, headRef, patch path, file stats
  var choices: [Choice]          // id, label, detail
  var checklist: [ChecklistItem] // id, text, required
  var attachments: [URL]         // screenshots, logs

  var response: Response?        // decision, text, choiceId, checked items,
                                 // per-line comments
  var timeoutAt: Date?
  var onTimeout: TimeoutPolicy   // wait, proceed, abort
  var dedupeKey: String?         // a retrying agent must not create 5 tasks
}
```

Two fields carry most of the value.

**`repo`** is the fix for the worktree problem. The panel groups tasks by
worktree and shows the branch, the head sha, and whether the tree is dirty. One
click opens that worktree in your editor, your terminal, or GitHub Desktop. You
never ask "which checkout was this?" again.

**`dedupeKey`** stops duplicate asks. If a key matches an open task, return the
existing id instead of creating a new task.

## 5. MCP tool surface

Keep the surface small. Agents use few tools well and many tools badly.

```text
submit_task(title, kind, body?, priority?, links?, diff?, choices?,
            checklist?, repo?, dedupeKey?, timeoutSeconds?, onTimeout?)
  -> { id, status, deduped }

await_task(id, timeoutSeconds=120)
  -> { id, status, response? }

get_task(id) -> { id, status, response? }

list_tasks(sessionId?, status?) -> [ taskSummary ]

cancel_task(id, reason)   // the agent no longer needs the answer
```

Convenience wrappers reduce prompt effort and improve call quality:

```text
request_review(worktree, baseRef, headRef, notes?)   // kind = reviewDiff
ask_choice(question, choices)                        // kind = choose
request_check(url, whatToVerify)                     // kind = verify
```

Ship an `AGENTS.md` snippet and a pi skill that teaches when to call these.
Without that instruction the agent never asks. State the rule plainly: ask
before a destructive change, ask when two paths are equally valid, ask when a
result needs a human eye on a rendered page.

## 6. The interface

Liquid Glass belongs on the chrome, not on dense text. Glass behind a code diff
hurts legibility. Use `glassEffect` on toolbars, the HUD, buttons, and the
notification-like rows. Use an opaque surface for diff content.

### 6.1 Menu bar item

`MenuBarExtra` with a count badge. The popover lists open tasks grouped by
worktree. This is the always-available, low-friction surface.

### 6.2 Command palette panel

A global hotkey opens a floating panel. Use `NSPanel`, not a SwiftUI `Window`,
because you need `.nonactivatingPanel` so the panel does not steal focus from
your editor.

```swift
panel.styleMask = [.titled, .fullSizeContentView, .nonactivatingPanel]
panel.level = .floating
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
panel.isFloatingPanel = true
```

This is the main work surface. Render the diff inline with syntax highlight.
Do not make the user leave the app to see the change. Inline review is the
highest-value feature in the whole product.

Keyboard first. Never require the mouse.

| Key | Action |
| --- | --- |
| `j` / `k` | move in the queue |
| `⏎` | open the task |
| `a` | approve and mark done |
| `r` | send back, opens a note field |
| `s` | snooze 15 minutes |
| `o` | open the primary link |
| `⌘⏎` | mark done |
| `⌘⇧⏎` | send back |
| `⌘A` then `a` | approve a whole worktree group |

### 6.3 The HUD overlay

You asked for this and it matters most. When you start a task, Baton pins a
small always-on-top glass pill. You then go to Chrome or Xcode to do the work.
The pill stays visible.

The pill shows:

- the task title, truncated
- the checklist, if the task has one
- two buttons: **Done** and **Send back**
- a collapse control that shrinks it to a dot

```swift
.glassEffect(.regular.interactive(), in: .capsule)
```

Rules for the HUD:

- Never take focus. Use a nonactivating panel.
- Float above full-screen apps with `.fullScreenAuxiliary`.
- Drag to move. Snap to a screen edge. Remember the position per display.
- Auto-hide during screen sharing and full-screen video.
- Global hotkeys work while the HUD shows, so `⌘⇧⏎` sends back from anywhere.

### 6.4 Notifications

Use `UNUserNotificationCenter` with action buttons: Approve, Open, Snooze,
View. Approving from the notification is the fastest path in the product.

Map priority to interruption level:

| Priority | Level | Behavior |
| --- | --- | --- |
| low | `.passive` | no sound, queues silently |
| normal | `.active` | standard banner |
| high | `.active` + sound | banner and sound |
| urgent | `.timeSensitive` | breaks through Focus |

Coalesce. Three tasks from one worktree in 30 seconds produce one notification:
"3 reviews waiting in `feature/auth`". Notification fatigue kills this class of
tool faster than any bug.

### 6.5 Later surfaces

- A widget and a Control Center control that show the pending count.
- An iOS companion with APNs, so you approve from your phone. A Live Activity
  shows the queue on the Lock Screen.
- Shortcuts and AppleScript actions, so other tools can submit tasks.

## 7. Send-back is the real feature

"Mark done" is easy. "Send back" carries the information.

A send-back returns structured feedback, not just text:

```json
{
  "decision": "sentBack",
  "text": "The modal closes but the focus ring lands on the wrong button.",
  "comments": [
    { "file": "src/Modal.tsx", "line": 42, "text": "restore focus to trigger" }
  ],
  "checklist": [
    { "id": "closes", "checked": true },
    { "id": "focus", "checked": false }
  ]
}
```

Per-line comments come from clicking a line in the inline diff. The agent gets
file and line precision, so it does not need to re-read the whole file. This is
what makes the round trip fast.

## 8. Risks and hard parts

**Harness tool timeouts.** A blocking call must default short and degrade to
`pending`. Document the poll loop in the tool description itself, because that
description is the only prompt many agents read.

**The agent never asks.** The tool is useless without instruction. Ship the
prompt snippet with the app and add a one-click "install into AGENTS.md".

**Notification permission and signing.** `UNUserNotificationCenter` needs a
real app bundle with a stable bundle id. An ad-hoc signed build gets flaky
delivery. `.timeSensitive` needs the Time Sensitive entitlement. Plan for a
Developer ID signed and notarized build early, not at the end.

**The app is not running.** The SQLite-first design covers submits. Still add a
LaunchAgent through `SMAppService.loginItem`, and let `baton-mcp` run
`open -g -a Baton` when it writes a task and finds no running app.

**Glass legibility.** Test the diff view against a bright wallpaper and a busy
window behind it. Fall back to an opaque material for text-heavy regions.

**HUD in the way.** A floating pill that covers a button you need is worse than
no pill. Make it small, movable, edge-snapped, and collapsible to a dot.

**A looping agent.** Rate limit per session, for example 20 tasks per minute,
then reject with a clear error. Cap body and patch size.

**Security.** Bind HTTP to loopback and require a token. Validate link schemes
against an allow list of `http`, `https`, `file`, `vscode`, `cursor`, and
`x-github`. Never auto-open a link. Never execute anything from a payload.
Block remote images in rendered markdown.

**Abandoned tasks.** If the agent session dies, the task is waste. Record the
agent pid, check liveness, and label the task "agent gone" so you do not review
a diff nobody waits on.

## 9. Stack

- SwiftUI, macOS 26 or later, so Liquid Glass is unconditional.
- `MenuBarExtra` for the menu bar. `NSPanel` for the palette and the HUD.
- GRDB, or a thin SQLite3 wrapper, for the store.
- The official Swift MCP SDK for the server. Verify the package before you
  commit to it. A hand-rolled JSON-RPC over stdio is about 300 lines and has no
  dependency risk, so it is a fair fallback.
- `KeyboardShortcuts` for the global hotkey, or Carbon `RegisterEventHotKey`.
- `swift-argument-parser` for the CLI.

One package, three targets: `BatonCore` (model plus store), `BatonMCP` (CLI),
`BatonApp` (UI).

## 10. Phases

**P0 — the useful core.** SQLite store. `baton-mcp` with `submit_task`,
`await_task`, `get_task`. Menu bar app with a glass list. Notifications with
Approve and Send back. This alone earns its keep.

**P1 — the daily driver.** HUD overlay. Global hotkey palette. Inline diff view.
Worktree grouping. Keyboard navigation. Snooze.

**P2 — depth.** Per-line diff comments. Batch approve. Checklists. Screenshot
attachments. Widget and Control Center. HTTP transport.

**P3 — reach.** iOS companion with APNs and a Live Activity. Shortcuts and
AppleScript. Task routing between agents.

## 11. First test to run

Build P0. Then open five worktrees, tell each agent to request a review before
it commits, and work the queue for one afternoon. Measure two numbers:

1. Median seconds from submit to response.
2. Count of send-backs that the agent fixed on the first retry.

If the second number is low, the send-back payload lacks detail. Fix the
payload, not the UI.
