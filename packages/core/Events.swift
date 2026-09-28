import Foundation

/// The stable internal event contract. Claude Code specifics never leak past the adapter;
/// everything downstream (state machine, UI) only sees these.
public struct NormalizedEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case sessionStarted = "session.started"
        case sessionWorking = "session.working"
        case sessionNeedsInput = "session.needs_input"
        case sessionInputResolved = "session.input_resolved"
        case sessionCompleted = "session.completed"
        /// The session is sitting at its prompt (e.g. the user interrupted Claude, which
        /// doesn't produce a completion). Quietly ends any running turn.
        case sessionIdle = "session.idle"
        case sessionEnded = "session.ended"
        case usageUpdated = "usage.updated"
    }

    /// Why a session is (still) working. Matters for whether a pending question is cleared.
    public enum WorkReason: String, Codable, Sendable {
        case prompt      // the user sent a new prompt
        case tool        // tool activity heartbeat
    }

    public var type: Kind
    public var sessionId: String
    public var timestamp: Date
    public var projectName: String?
    public var workingDirectory: String?
    public var host: SessionHost?
    public var claudePid: Int32?
    public var reason: WorkReason?
    /// Short, human-friendly description of the latest activity ("Editing App.swift").
    public var activity: String?
    public var question: QuestionPayload?
    /// For `session.input_resolved`: which question. nil resolves every pending question.
    public var questionId: String?
    public var usage: UsageSnapshot?
    public var failed: Bool?

    public init(
        type: Kind, sessionId: String, timestamp: Date = Date(),
        projectName: String? = nil, workingDirectory: String? = nil, host: SessionHost? = nil,
        claudePid: Int32? = nil, reason: WorkReason? = nil, activity: String? = nil,
        question: QuestionPayload? = nil, questionId: String? = nil,
        usage: UsageSnapshot? = nil, failed: Bool? = nil
    ) {
        self.type = type
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.projectName = projectName
        self.workingDirectory = workingDirectory
        self.host = host
        self.claudePid = claudePid
        self.reason = reason
        self.activity = activity
        self.question = question
        self.questionId = questionId
        self.usage = usage
        self.failed = failed
    }
}

/// Where the Claude Code session is running. Determines whether the notch may answer
/// questions itself or should defer to the host's own question UI.
public enum SessionHost: String, Codable, Sendable {
    case cli, desktop, ide, sdk, unknown

    public var displayName: String {
        switch self {
        case .cli: return "Terminal"
        case .desktop: return "Claude app"
        case .ide: return "your IDE"
        case .sdk: return "SDK"
        case .unknown: return "Claude Code"
        }
    }
}

public struct QuestionPayload: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case question     // AskUserQuestion: structured, may be answerable from the notch
        case permission   // tool permission prompt: always answered in the host (V2 per PRD)
        case elicitation  // MCP elicitation dialog: answered in the host
    }

    public var id: String
    public var kind: Kind
    /// 1–4 items for AskUserQuestion; a single item for permission/elicitation.
    public var items: [QuestionItem]
    /// True only when the hook is holding the question open waiting for our answer.
    public var answerable: Bool

    public init(id: String, kind: Kind, items: [QuestionItem], answerable: Bool) {
        self.id = id
        self.kind = kind
        self.items = items
        self.answerable = answerable
    }
}

public struct QuestionItem: Codable, Equatable, Sendable {
    public var text: String
    public var header: String?
    public var options: [QuestionOption]
    public var multiSelect: Bool

    public init(text: String, header: String? = nil, options: [QuestionOption] = [], multiSelect: Bool = false) {
        self.text = text
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }
}

public struct QuestionOption: Codable, Equatable, Sendable {
    public var label: String
    public var description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

// MARK: - Usage

/// Every usage value carries its provenance so the UI can never present an estimate as official.
public enum UsageSource: String, Codable, Sendable {
    case verified   // reported by Claude Code itself (status line JSON)
    case estimated  // derived by this app (e.g. from transcript token counts)
}

public struct PercentMetric: Codable, Equatable, Sendable {
    public var usedPercent: Double
    public var source: UsageSource
    /// For context estimates: the window size (in tokens) the percentage assumes.
    public var windowTokens: Double?

    public init(usedPercent: Double, source: UsageSource, windowTokens: Double? = nil) {
        self.usedPercent = usedPercent
        self.source = source
        self.windowTokens = windowTokens
    }
}

public struct RateWindow: Codable, Equatable, Sendable {
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(usedPercent: Double, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    /// Per-session context window usage.
    public var context: PercentMetric?
    /// Account-wide plan limits (claude.ai Pro/Max only). Always `verified` when present.
    public var fiveHour: RateWindow?
    public var sevenDay: RateWindow?
    public var capturedAt: Date

    public init(context: PercentMetric? = nil, fiveHour: RateWindow? = nil, sevenDay: RateWindow? = nil, capturedAt: Date = Date()) {
        self.context = context
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.capturedAt = capturedAt
    }

    public var hasRateLimits: Bool { fiveHour != nil || sevenDay != nil }
}

// MARK: - Validation

public enum EventValidationError: Error, Equatable {
    case invalidSessionId
    case invalidQuestion
}

extension NormalizedEvent {
    static let maxText = 2_000
    static let maxShort = 200

    /// Rejects malformed events and clamps oversized strings. Called on every event that
    /// crosses the bridge, so nothing downstream has to be defensive about payload shape.
    public func validated() throws -> NormalizedEvent {
        guard Self.isValidSessionId(sessionId) else { throw EventValidationError.invalidSessionId }
        var e = self
        e.projectName = projectName.map { Self.clamp($0, Self.maxShort) }
        e.workingDirectory = workingDirectory.map { Self.clamp($0, 1_024) }
        e.activity = activity.map { Self.clamp($0, 120) }
        e.questionId = questionId.map { Self.clamp($0, Self.maxShort) }
        if type == .sessionNeedsInput && question == nil { throw EventValidationError.invalidQuestion }
        if var q = question {
            guard !q.id.isEmpty, q.id.count <= Self.maxShort, !q.items.isEmpty else {
                throw EventValidationError.invalidQuestion
            }
            q.items = Array(q.items.prefix(4)).map { item in
                QuestionItem(
                    text: Self.clamp(item.text, Self.maxText),
                    header: item.header.map { Self.clamp($0, 120) },
                    options: Array(item.options.prefix(8)).map {
                        QuestionOption(label: Self.clamp($0.label, Self.maxShort),
                                       description: $0.description.map { Self.clamp($0, 500) })
                    },
                    multiSelect: item.multiSelect
                )
            }
            e.question = q
        }
        if var u = usage {
            u.context = u.context.map { PercentMetric(usedPercent: Self.clampPercent($0.usedPercent), source: $0.source) }
            u.fiveHour = u.fiveHour.map { RateWindow(usedPercent: Self.clampPercent($0.usedPercent), resetsAt: $0.resetsAt) }
            u.sevenDay = u.sevenDay.map { RateWindow(usedPercent: Self.clampPercent($0.usedPercent), resetsAt: $0.resetsAt) }
            e.usage = u
        }
        return e
    }

    public static func isValidSessionId(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128 else { return false }
        return id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    static func clamp(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    static func clampPercent(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return min(max(v, 0), 100)
    }
}
