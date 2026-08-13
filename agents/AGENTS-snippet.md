# Baton agent instructions

Copy this into your project `AGENTS.md`, `CLAUDE.md`, or system prompt.

Without an instruction like this, an agent never calls the tool. It guesses
instead, because guessing is free and asking looks expensive.

---

## Asking the human

You can reach the human who runs you through the `baton` MCP tools. Use them.

**Ask when:**

- A change is destructive or hard to undo. A migration, a force push, a mass
  delete, a dependency bump across many packages.
- Two paths are equally valid and the choice is taste, policy, or product. Do
  not silently pick one and hide the trade-off in a comment.
- A result needs human eyes. A rendered page, an animation, a layout on a real
  screen, a colour.
- You finished work in a worktree and want a review before you commit.
- You are blocked on something only a person can give you: a credential, an
  account, a decision from outside the repository.

**Do not ask when:**

- You can find the answer by reading the code, running the tests, or reading the
  documentation. Do that first.
- The question is one you should answer with your own judgement, and the cost of
  being wrong is a small, reversible edit.
- You already asked and got an answer. Read `response.text` again.

## Which tool

| Situation | Tool |
| --- | --- |
| You can pause and wait for the answer | `ask_human` |
| You are about to end your turn | `submit_task` |
| You have a task id and want to wait now | `await_task` |
| You want to check without blocking | `get_task` |
| You restarted and lost the id | `list_tasks` with your `sessionId` |
| You found the answer yourself | `cancel_task` |

## How to write a good task

1. **One question per task.** Two questions in one card get one answer.
2. **Put the question in the title.** The title appears in a notification, so it
   has to work on its own. "Which cache backend?" beats "Question about caching".
3. **Always pass `worktree`.** Baton reads the branch and the head commit from
   it. With several agents running, the human cannot tell your task from another
   one's without it. Pass `baseRef` too when you changed code, and Baton adds a
   file and line count.
4. **Pass a `checklist` for anything visual.** Each item is one short sentence
   the human can tick. A failed item comes back to you by name, which tells you
   exactly what broke. This is the difference between "it looks wrong" and "the
   focus ring does not return to the trigger".
5. **Pass `links` for anything to open.** A preview URL, a pull request, a file.
6. **Give `choices` real detail.** One line on what each option costs. The human
   should not have to reconstruct your reasoning.
7. **Use a `dedupeKey`** when you might retry. Baton returns the existing task
   instead of asking twice.
8. **Keep `priority` at `normal`.** Use `urgent` only when the answer blocks
   everything; it breaks through Do Not Disturb, and spending that costs trust.
9. **Pass a stable `sessionId`** on every call, so you can find your own answers
   after a restart.

## Handling the reply

- `status: "pending"` after a wait is **not a failure**. The task is still open.
  Either call `await_task` again with the same id, or end your turn and check
  later with `get_task`. Never submit the task again.
- `status: "sentBack"` means the human wants changes. Read `response.text` and
  `response.failedChecks`. Fix those, then submit a **new** task.
- `status: "expired"` with `onTimeout: "proceed"` means use your own judgement.
  Say in your output which assumption you made.
- `status: "cancelled"` means no answer is coming.
- Every reply carries a `nextStep` line. Follow it.

## Examples

Ask for a review before committing:

```json
{
  "name": "ask_human",
  "arguments": {
    "question": "Review the auth refactor before I commit?",
    "details": "I moved session handling out of `middleware.ts` into `lib/session.ts`. Tests pass. I did not change the cookie name.",
    "kind": "reviewChange",
    "worktree": "/Users/me/code/app-auth-refactor",
    "baseRef": "main",
    "sessionId": "sess-8821",
    "agentName": "pi",
    "waitSeconds": 180
  }
}
```

Ask for a visual check:

```json
{
  "name": "submit_task",
  "arguments": {
    "title": "Does the modal close cleanly?",
    "kind": "verify",
    "worktree": "/Users/me/code/app-modal-fix",
    "links": [{ "label": "Preview", "url": "http://localhost:5173/settings" }],
    "checklist": [
      "The modal closes on Escape",
      "Focus returns to the button that opened it",
      "No layout shift behind the overlay"
    ],
    "sessionId": "sess-8821"
  }
}
```

Ask for a decision:

```json
{
  "name": "ask_human",
  "arguments": {
    "question": "Which cache should the session store use?",
    "kind": "choose",
    "choices": [
      { "label": "Redis", "detail": "Survives a restart. Adds a service to run locally." },
      { "label": "In-memory LRU", "detail": "No new service. Logs everyone out on deploy." }
    ],
    "worktree": "/Users/me/code/app-sessions",
    "sessionId": "sess-8821",
    "waitSeconds": 240
  }
}
```
