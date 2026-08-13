import BatonCore
import Foundation

/// The tool surface.
///
/// These descriptions are the only prompt many agents read, so they say when to
/// call a tool, not just what it does. The prose is hoisted into named constants
/// to keep the schema literals small enough for the type checker and short enough
/// to read.
enum ToolCatalog {
    static let serverInstructions = """
    Baton hands a task to the human who runs you, then gives you their answer.

    Call it when you need a person, not when you need information you can find \
    yourself. Good reasons to call: a change is destructive or hard to undo; two \
    paths are equally valid and the choice is a matter of taste or policy; a \
    result needs a human eye on a rendered page; you finished work in a worktree \
    and want a review before you commit.

    Prefer `ask_human` when you can wait for the answer. Prefer `submit_task` \
    when you are about to end your turn. Always pass `worktree` so the human \
    knows which checkout you mean. Ask one clear question per task.
    """

    static let all: [Tool] = [
        askHuman,
        submitTask,
        awaitTask,
        getTask,
        listTasks,
        cancelTask,
    ]

    static func tool(named name: String) -> Tool? {
        all.first { $0.name == name }
    }

    // MARK: - Field descriptions

    private enum Doc {
        static let links = """
        Links the human should open. Allowed schemes: http, https, file, and \
        editor schemes such as vscode or cursor.
        """

        static let checklist = """
        Concrete things the human should confirm. Each item is one short \
        sentence. The human ticks them, and you get the result back, so a failed \
        item tells you exactly what broke.
        """

        static let choices = """
        The options to pick from. Give 2 to 5. Each may be a plain string or an \
        object with a label and a detail.
        """

        static let worktree = """
        Absolute path of the git worktree this task belongs to. Baton reads the \
        branch and the head commit from it. Pass this whenever the task touches a \
        repository.
        """

        static let baseRef = """
        Git ref to compare from, for example 'main'. Baton then shows a file and \
        line count.
        """

        static let headRef = "Git ref to compare to. Defaults to the working tree."

        static let agentName = "Your name, so the human can tell your tasks from another agent's."

        static let sessionId = """
        Your session id. Pass the same value every time so you can list your own \
        tasks later.
        """

        static let priority = """
        Defaults to normal. Use 'urgent' only when the answer blocks everything \
        and the interruption is justified; it breaks through Do Not Disturb.
        """

        static let question = "The question, as one short sentence. This is the title the human sees first."

        static let details = """
        Markdown context: what you did, what you are unsure about, what each \
        option costs. Keep it under 20 lines.
        """

        static let kind = """
        approve for yes or no, choose with options, verify for a check on a page, \
        input for free text, reviewChange for a code review.
        """

        static let waitSeconds = """
        How long to block. Defaults to 120. Maximum 900. Keep it under your own \
        tool timeout.
        """

        static let dedupeKey = """
        A stable key for this question. If you retry, Baton returns the existing \
        task instead of asking twice.
        """

        static let title = "One short sentence. It appears in a notification, so make it readable alone."

        static let body = "Markdown detail. Keep it under 20 lines."

        static let timeoutSeconds = "Expire the task after this long. Omit to keep it open until the human acts."

        static let onTimeout = """
        wait keeps the task open forever. proceed lets you use your own judgement \
        after the deadline. abort tells you to stop.
        """

        static let statusFilter = "Defaults to open, which covers pending, active, and snoozed."

        static let taskId = "The task id from submit_task or ask_human."

        static let cancelReason = "One line on why it no longer matters."
    }

    // MARK: - Schema fragments

    /// A string property with a description. Most fields are exactly this.
    private static func text(_ description: String) -> JSONValue {
        .object(["type": "string", "description": .string(description)])
    }

    private static func number(_ description: String) -> JSONValue {
        .object(["type": "number", "description": .string(description)])
    }

    private static func choice(_ options: [String], _ description: String) -> JSONValue {
        .object([
            "type": "string",
            "enum": .array(options.map { .string($0) }),
            "description": .string(description),
        ])
    }

    private static let kindOptions = [
        "reviewChange", "openURL", "approve", "choose", "verify", "input", "generic",
    ]

    private static let priorityOptions = ["low", "normal", "high", "urgent"]

    private static let linksSchema: JSONValue = .object([
        "type": "array",
        "description": .string(Doc.links),
        "items": .object([
            "type": "object",
            "properties": .object([
                "label": text("Short button label, for example 'Open preview'."),
                "url": .object(["type": "string"]),
                "openIn": choice(
                    ["browser", "editor", "terminal", "finder"],
                    "Where to open it. Defaults to browser."
                ),
            ]),
            "required": .array(["label", "url"]),
        ]),
    ])

    private static let checklistSchema: JSONValue = .object([
        "type": "array",
        "description": .string(Doc.checklist),
        "items": .object(["type": "string"]),
    ])

    private static let choicesSchema: JSONValue = .object([
        "type": "array",
        "description": .string(Doc.choices),
        "items": .object([
            "anyOf": .array([
                .object(["type": "string"]),
                .object([
                    "type": "object",
                    "properties": .object([
                        "label": .object(["type": "string"]),
                        "detail": text("One line on the trade-off."),
                    ]),
                    "required": .array(["label"]),
                ]),
            ]),
        ]),
    ])

    /// Fields every submitting tool shares.
    private static let contextProperties: [String: JSONValue] = [
        "worktree": text(Doc.worktree),
        "baseRef": text(Doc.baseRef),
        "headRef": text(Doc.headRef),
        "agentName": text(Doc.agentName),
        "sessionId": text(Doc.sessionId),
        "priority": choice(priorityOptions, Doc.priority),
    ]

    private static func schema(
        properties: [String: JSONValue],
        required: [String],
        includeContext: Bool = false
    ) -> JSONValue {
        var merged = properties
        if includeContext {
            merged.merge(contextProperties) { existing, _ in existing }
        }
        return .object([
            "type": "object",
            "properties": .object(merged),
            "required": .array(required.map { .string($0) }),
        ])
    }

    // MARK: - Tools

    static let askHuman = Tool(
        name: "ask_human",
        title: "Ask the human and wait",
        description: """
        Submits a task and waits for the answer in one call. Use this when you \
        can pause: an approval, a choice between options, or a check you need \
        confirmed before you continue.

        The call returns when the human answers, or when `waitSeconds` runs out. \
        A timeout is not a failure: the task stays open, and you get \
        `status: "pending"` with the task id. Either call `await_task` again with \
        that id, or end your turn and pick the answer up later with `get_task`.

        Ask one question. Make the title readable on its own, because it appears \
        in a notification.
        """,
        schema: schema(
            properties: [
                "question": text(Doc.question),
                "details": text(Doc.details),
                "kind": choice(kindOptions, Doc.kind),
                "choices": choicesSchema,
                "checklist": checklistSchema,
                "links": linksSchema,
                "waitSeconds": number(Doc.waitSeconds),
                "dedupeKey": text(Doc.dedupeKey),
            ],
            required: ["question"],
            includeContext: true
        )
    )

    static let submitTask = Tool(
        name: "submit_task",
        title: "Submit a task without waiting",
        description: """
        Queues a task for the human and returns at once. Use this when you are \
        about to end your turn, or when you can keep working while the human \
        catches up.

        Returns the task id. Read the answer later with `get_task`, or block on \
        it with `await_task`.
        """,
        schema: schema(
            properties: [
                "title": text(Doc.title),
                "body": text(Doc.body),
                "kind": choice(kindOptions, Doc.kind),
                "choices": choicesSchema,
                "checklist": checklistSchema,
                "links": linksSchema,
                "dedupeKey": text(Doc.dedupeKey),
                "timeoutSeconds": number(Doc.timeoutSeconds),
                "onTimeout": choice(["wait", "proceed", "abort"], Doc.onTimeout),
            ],
            required: ["title"],
            includeContext: true
        )
    )

    static let awaitTask = Tool(
        name: "await_task",
        title: "Wait for an answer",
        description: """
        Blocks until the human resolves the task, or until `waitSeconds` runs \
        out. A timeout returns `status: "pending"`, which means keep waiting or \
        come back later. It does not mean the task failed.
        """,
        schema: schema(
            properties: [
                "id": text(Doc.taskId),
                "waitSeconds": number("Defaults to 120. Maximum 900."),
            ],
            required: ["id"]
        )
    )

    static let getTask = Tool(
        name: "get_task",
        title: "Read a task",
        description: "Reads one task and its answer if the human already replied. Never blocks.",
        schema: schema(
            properties: ["id": text(Doc.taskId)],
            required: ["id"]
        )
    )

    static let listTasks = Tool(
        name: "list_tasks",
        title: "List tasks",
        description: """
        Lists tasks, newest last. Pass your `sessionId` to see only your own. Use \
        this after a restart to find answers you missed.
        """,
        schema: schema(
            properties: [
                "sessionId": text(Doc.sessionId),
                "status": choice(
                    [
                        "open", "pending", "active", "snoozed",
                        "done", "sentBack", "expired", "cancelled", "any",
                    ],
                    Doc.statusFilter
                ),
                "limit": number("Defaults to 50."),
            ],
            required: []
        )
    )

    static let cancelTask = Tool(
        name: "cancel_task",
        title: "Cancel a task",
        description: """
        Withdraws a task you no longer need answered, for example because you \
        found the answer yourself. Call this instead of leaving the task open. A \
        stale task wastes the human's attention.
        """,
        schema: schema(
            properties: [
                "id": text(Doc.taskId),
                "reason": text(Doc.cancelReason),
            ],
            required: ["id"]
        )
    )
}

struct Tool {
    let name: String
    let title: String
    let description: String
    let schema: JSONValue

    var descriptor: JSONValue {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": schema,
        ])
    }
}
