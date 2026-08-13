import Foundation

/// Named `BatonTask` on purpose. `Task` collides with Swift concurrency.
public struct BatonTask: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var createdAt: Date
    public var updatedAt: Date
    public var respondedAt: Date?

    public var status: Status
    public var kind: Kind
    public var priority: Priority

    /// Short. The notch and the notification both show this.
    public var title: String
    /// Markdown detail. Optional.
    public var body: String?

    public var agent: AgentRef
    public var repo: RepoRef?

    public var links: [Link]
    public var choices: [Choice]
    public var checklist: [ChecklistItem]
    public var changeSummary: ChangeSummary?

    public var response: Response?

    public var timeoutAt: Date?
    public var onTimeout: TimeoutPolicy
    public var dedupeKey: String?
    /// Set when the app hides the task until a later time.
    public var snoozedUntil: Date?

    public init(
        id: String = ULID.generate(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        respondedAt: Date? = nil,
        status: Status = .pending,
        kind: Kind = .generic,
        priority: Priority = .normal,
        title: String,
        body: String? = nil,
        agent: AgentRef = AgentRef(),
        repo: RepoRef? = nil,
        links: [Link] = [],
        choices: [Choice] = [],
        checklist: [ChecklistItem] = [],
        changeSummary: ChangeSummary? = nil,
        response: Response? = nil,
        timeoutAt: Date? = nil,
        onTimeout: TimeoutPolicy = .wait,
        dedupeKey: String? = nil,
        snoozedUntil: Date? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.respondedAt = respondedAt
        self.status = status
        self.kind = kind
        self.priority = priority
        self.title = title
        self.body = body
        self.agent = agent
        self.repo = repo
        self.links = links
        self.choices = choices
        self.checklist = checklist
        self.changeSummary = changeSummary
        self.response = response
        self.timeoutAt = timeoutAt
        self.onTimeout = onTimeout
        self.dedupeKey = dedupeKey
        self.snoozedUntil = snoozedUntil
    }
}

extension BatonTask {
    /// True while the task still waits on a human.
    public var isOpen: Bool { status.isOpen }

    /// True when the task is open and not snoozed past now.
    public func isVisible(at now: Date = Date()) -> Bool {
        guard status.isOpen else { return false }
        if let until = snoozedUntil, until > now { return false }
        return true
    }

    public var primaryLink: Link? { links.first }

    /// Short label for the notch. Falls back to the branch, then the folder.
    public var contextLabel: String? {
        if let branch = repo?.branch, !branch.isEmpty { return branch }
        if let path = repo?.worktreePath, !path.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return agent.name
    }
}

// MARK: - Enums

extension BatonTask {
    public enum Status: String, Codable, Sendable, CaseIterable {
        /// Waiting for a human to pick it up.
        case pending
        /// A human started it. The notch shows the working HUD.
        case active
        /// Hidden until `snoozedUntil`.
        case snoozed
        /// The human approved or answered.
        case done
        /// The human returned it with feedback.
        case sentBack
        /// The deadline passed with no answer.
        case expired
        /// The agent no longer needs the answer.
        case cancelled

        public var isOpen: Bool {
            switch self {
            case .pending, .active, .snoozed: return true
            case .done, .sentBack, .expired, .cancelled: return false
            }
        }

        public var isResolved: Bool { !isOpen }
    }

    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Look over a change in a worktree.
        case reviewChange
        /// Open a link and look at it.
        case openURL
        /// Say yes or no.
        case approve
        /// Pick one of several options.
        case choose
        /// Run a check and report what happened.
        case verify
        /// Type an answer.
        case input
        /// Anything else.
        case generic

        public var symbolName: String {
            switch self {
            case .reviewChange: return "arrow.triangle.branch"
            case .openURL: return "safari"
            case .approve: return "checkmark.seal"
            case .choose: return "arrow.triangle.branch"
            case .verify: return "eye"
            case .input: return "text.cursor"
            case .generic: return "bell"
            }
        }

        /// The label on the confirm button.
        public var confirmVerb: String {
            switch self {
            case .approve: return "Approve"
            case .choose: return "Send choice"
            case .input: return "Send answer"
            default: return "Done"
            }
        }
    }

    public enum Priority: String, Codable, Sendable, CaseIterable, Comparable {
        case low, normal, high, urgent

        public var order: Int {
            switch self {
            case .low: return 0
            case .normal: return 1
            case .high: return 2
            case .urgent: return 3
            }
        }

        public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.order < rhs.order }
    }

    /// What the agent should do when nobody answers in time.
    public enum TimeoutPolicy: String, Codable, Sendable {
        /// Keep waiting. The task never expires on its own.
        case wait
        /// Expire the task and let the agent use its own judgement.
        case proceed
        /// Expire the task and tell the agent to stop.
        case abort
    }
}

// MARK: - Nested value types

extension BatonTask {
    public struct AgentRef: Codable, Hashable, Sendable {
        public var name: String
        public var harness: String?
        public var model: String?
        public var sessionId: String?
        public var pid: Int32?

        public init(
            name: String = "agent",
            harness: String? = nil,
            model: String? = nil,
            sessionId: String? = nil,
            pid: Int32? = nil
        ) {
            self.name = name
            self.harness = harness
            self.model = model
            self.sessionId = sessionId
            self.pid = pid
        }

        /// False once the submitting process is gone. Reviewing that task is waste.
        public var isAlive: Bool {
            guard let pid, pid > 0 else { return true }
            return kill(pid, 0) == 0 || errno == EPERM
        }
    }

    public struct RepoRef: Codable, Hashable, Sendable {
        public var root: String?
        public var worktreePath: String
        public var branch: String?
        public var headSha: String?
        public var isDirty: Bool?

        public init(
            root: String? = nil,
            worktreePath: String,
            branch: String? = nil,
            headSha: String? = nil,
            isDirty: Bool? = nil
        ) {
            self.root = root
            self.worktreePath = worktreePath
            self.branch = branch
            self.headSha = headSha
            self.isDirty = isDirty
        }

        public var folderName: String {
            URL(fileURLWithPath: worktreePath).lastPathComponent
        }

        public var shortSha: String? {
            guard let headSha, headSha.count >= 7 else { return headSha }
            return String(headSha.prefix(7))
        }
    }

    public struct Link: Codable, Hashable, Sendable, Identifiable {
        public enum Target: String, Codable, Sendable {
            case browser, editor, terminal, finder
        }

        public var id: String
        public var label: String
        public var url: String
        public var openIn: Target

        public init(id: String = ULID.generate(), label: String, url: String, openIn: Target = .browser) {
            self.id = id
            self.label = label
            self.url = url
            self.openIn = openIn
        }
    }

    public struct Choice: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var detail: String?

        public init(id: String = ULID.generate(), label: String, detail: String? = nil) {
            self.id = id
            self.label = label
            self.detail = detail
        }
    }

    public struct ChecklistItem: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var text: String
        public var required: Bool
        public var checked: Bool

        public init(id: String = ULID.generate(), text: String, required: Bool = true, checked: Bool = false) {
            self.id = id
            self.text = text
            self.required = required
            self.checked = checked
        }
    }

    /// A change summary instead of a full diff. The card stays small and the
    /// human opens the worktree in an editor for the detail.
    public struct ChangeSummary: Codable, Hashable, Sendable {
        public var baseRef: String?
        public var headRef: String?
        public var filesChanged: Int
        public var insertions: Int
        public var deletions: Int
        public var files: [String]

        public init(
            baseRef: String? = nil,
            headRef: String? = nil,
            filesChanged: Int = 0,
            insertions: Int = 0,
            deletions: Int = 0,
            files: [String] = []
        ) {
            self.baseRef = baseRef
            self.headRef = headRef
            self.filesChanged = filesChanged
            self.insertions = insertions
            self.deletions = deletions
            self.files = files
        }

        public var headline: String {
            "\(filesChanged) file\(filesChanged == 1 ? "" : "s")  +\(insertions)  −\(deletions)"
        }
    }

    /// What goes back to the agent. Structure beats free text.
    public struct Response: Codable, Hashable, Sendable {
        public enum Decision: String, Codable, Sendable {
            case approved
            case sentBack
            case answered
            case chose
            case expired
            case cancelled
        }

        public var decision: Decision
        public var text: String?
        public var choiceId: String?
        public var checklist: [ChecklistItem]
        public var respondedAt: Date

        public init(
            decision: Decision,
            text: String? = nil,
            choiceId: String? = nil,
            checklist: [ChecklistItem] = [],
            respondedAt: Date = Date()
        ) {
            self.decision = decision
            self.text = text
            self.choiceId = choiceId
            self.checklist = checklist
            self.respondedAt = respondedAt
        }

        /// The failed items. This is the detail the agent needs on a send-back.
        public var unmetItems: [ChecklistItem] {
            checklist.filter { $0.required && !$0.checked }
        }
    }
}
