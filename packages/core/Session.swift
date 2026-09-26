import Foundation

public enum SessionState: String, Codable, Sendable, CaseIterable {
    case idle, working, needsInput, done

    /// Higher wins global attention (PRD §6): NEEDS_INPUT > WORKING > DONE > IDLE.
    public var priority: Int {
        switch self {
        case .needsInput: return 3
        case .working: return 2
        case .done: return 1
        case .idle: return 0
        }
    }

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .working: return "Working"
        case .needsInput: return "Needs you"
        case .done: return "Done"
        }
    }
}

public struct Question: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case pending         // waiting for the user
        case answered        // user answered from the notch; waiting for Claude to resume
        case deferredToHost  // must be (or was chosen to be) answered in Terminal / app
    }

    public var id: String
    public var sessionId: String
    public var kind: QuestionPayload.Kind
    public var items: [QuestionItem]
    public var answerable: Bool
    public var createdAt: Date
    public var status: Status

    public init(payload: QuestionPayload, sessionId: String, createdAt: Date) {
        id = payload.id
        self.sessionId = sessionId
        kind = payload.kind
        items = payload.items
        answerable = payload.answerable
        self.createdAt = createdAt
        status = payload.answerable ? .pending : .deferredToHost
    }

    /// Can the notch submit an answer right now?
    public var canAnswerHere: Bool { answerable && status == .pending }
}

public struct Session: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var projectName: String
    public var workingDirectory: String?
    public var host: SessionHost
    public var claudePid: Int32?
    public var state: SessionState
    public var startedAt: Date
    /// Start of the current unit of work; drives the "Working for 04:32" timer.
    public var turnStartedAt: Date?
    public var lastActivityAt: Date
    public var completedAt: Date?
    public var lastTurnDuration: TimeInterval?
    public var lastTurnFailed: Bool
    public var activity: String?
    /// FIFO queue; the first pending item is what the notch shows.
    public var questions: [Question]
    public var context: PercentMetric?
    /// Restored from disk after an app restart rather than observed live.
    public var restored: Bool

    public init(id: String, projectName: String, workingDirectory: String?, host: SessionHost, claudePid: Int32?, now: Date) {
        self.id = id
        self.projectName = projectName
        self.workingDirectory = workingDirectory
        self.host = host
        self.claudePid = claudePid
        state = .idle
        startedAt = now
        lastActivityAt = now
        lastTurnFailed = false
        questions = []
        restored = false
    }

    public var currentQuestion: Question? { questions.first }

    public func elapsed(at now: Date) -> TimeInterval? {
        guard let t = turnStartedAt else { return nil }
        return max(0, now.timeIntervalSince(t))
    }
}

/// Human-friendly name for a working directory: "~/Projects/my-app" → "my-app".
public func projectName(forDirectory dir: String?) -> String {
    guard let dir, !dir.isEmpty else { return "Claude" }
    let url = URL(fileURLWithPath: dir)
    if url.path == FileManager.default.homeDirectoryForCurrentUser.path { return "~" }
    let name = url.lastPathComponent
    return name.isEmpty || name == "/" ? "Claude" : name
}

public func formatDuration(_ t: TimeInterval) -> String {
    let s = Int(t.rounded(.down))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
}

/// "2h 14m", "14m", "45s"
public func formatCountdown(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded(.up)))
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m" }
    return "\(s)s"
}
