import Foundation

/// Side effects the UI should perform in response to a state change. The core never
/// touches UI or sound directly; it only reports what happened.
public enum StateEffect: Equatable, Sendable {
    /// A session just started needing the user.
    case attention(sessionId: String, questionId: String)
    /// A session finished a turn. `notable` is false for very short turns or failures,
    /// so the UI can celebrate meaningful work without celebrating every "hi".
    case completed(sessionId: String, notable: Bool, failed: Bool)
    /// The user's answer was accepted locally.
    case acknowledged(sessionId: String)
}

public struct StatePolicy: Equatable, Sendable {
    /// Turns shorter than this finish quietly (no confetti, no sound).
    public var notableTurnDuration: TimeInterval = 15
    /// DONE decays to IDLE after this long.
    public var doneToIdleAfter: TimeInterval = 5 * 60
    /// Sessions whose process we can't check are forgotten after this much silence.
    public var forgetSilentSessionsAfter: TimeInterval = 3 * 60 * 60
    public init() {}
}

/// The single source of truth for session status (PRD §48).
public struct AppState: Codable, Equatable, Sendable {
    public var sessions: [String: Session] = [:]
    public var focusedSessionId: String?
    /// Account-wide plan limits, from whichever session reported them last.
    public var rateLimits: UsageSnapshot?

    public init() {}

    // MARK: Reducer

    @discardableResult
    public mutating func apply(_ e: NormalizedEvent, policy: StatePolicy = StatePolicy()) -> [StateEffect] {
        if e.type == .sessionEnded {
            sessions[e.sessionId] = nil
            if focusedSessionId == e.sessionId { focusedSessionId = nil }
            return []
        }

        var s = sessions[e.sessionId] ?? Session(
            id: e.sessionId,
            projectName: e.projectName ?? projectName(forDirectory: e.workingDirectory),
            workingDirectory: e.workingDirectory,
            host: e.host ?? .unknown,
            claudePid: e.claudePid,
            now: e.timestamp
        )
        // Identity can improve over time (e.g. first event we saw lacked cwd).
        if let p = e.projectName { s.projectName = p }
        if let d = e.workingDirectory { s.workingDirectory = d }
        if let h = e.host, h != .unknown { s.host = h }
        if let pid = e.claudePid { s.claudePid = pid }
        s.restored = false

        var effects: [StateEffect] = []
        defer { sessions[s.id] = s }

        switch e.type {
        case .sessionStarted:
            s.lastActivityAt = max(s.lastActivityAt, e.timestamp)

        case .sessionWorking:
            // Hooks can race; never let a stale heartbeat reopen a finished turn.
            if let done = s.completedAt, e.timestamp < done, s.state == .done || s.state == .idle { break }
            s.lastActivityAt = max(s.lastActivityAt, e.timestamp)
            if let a = e.activity { s.activity = a }
            switch s.state {
            case .idle, .done:
                s.state = .working
                s.turnStartedAt = e.timestamp
                s.lastTurnFailed = false
                if e.reason == .prompt { s.activity = nil }
            case .working:
                if s.turnStartedAt == nil { s.turnStartedAt = e.timestamp }
            case .needsInput:
                if e.reason == .prompt {
                    // A new prompt means every outstanding question is moot.
                    s.questions.removeAll()
                } else {
                    // Tool activity after a permission/elicitation prompt means the user
                    // resolved it in the host. Structured questions need an explicit resolve.
                    s.questions.removeAll { $0.kind != .question && $0.createdAt <= e.timestamp }
                }
                if s.questions.isEmpty { s.state = .working }
            }

        case .sessionNeedsInput:
            guard let payload = e.question else { break }
            s.lastActivityAt = max(s.lastActivityAt, e.timestamp)
            if s.turnStartedAt == nil || s.state == .done || s.state == .idle { s.turnStartedAt = e.timestamp }
            if let i = s.questions.firstIndex(where: { $0.id == payload.id }) {
                // Duplicate delivery: refresh content, keep status.
                let status = s.questions[i].status
                s.questions[i] = Question(payload: payload, sessionId: s.id, createdAt: s.questions[i].createdAt)
                s.questions[i].status = payload.answerable ? status : .deferredToHost
            } else {
                s.questions.append(Question(payload: payload, sessionId: s.id, createdAt: e.timestamp))
                effects.append(.attention(sessionId: s.id, questionId: payload.id))
            }
            s.state = .needsInput

        case .sessionInputResolved:
            s.lastActivityAt = max(s.lastActivityAt, e.timestamp)
            if let qid = e.questionId {
                s.questions.removeAll { $0.id == qid }
            } else {
                s.questions.removeAll()
            }
            if s.questions.isEmpty && s.state == .needsInput { s.state = .working }

        case .sessionCompleted:
            guard s.state == .working || s.state == .needsInput else {
                // Duplicate or out-of-order completion: nothing to celebrate.
                s.lastActivityAt = max(s.lastActivityAt, e.timestamp)
                break
            }
            if let t = s.turnStartedAt, e.timestamp < t { break }
            let duration = s.turnStartedAt.map { e.timestamp.timeIntervalSince($0) } ?? 0
            let failed = e.failed ?? false
            s.state = .done
            s.questions.removeAll()
            s.completedAt = e.timestamp
            s.lastActivityAt = max(s.lastActivityAt, e.timestamp)
            s.lastTurnDuration = duration
            s.lastTurnFailed = failed
            s.turnStartedAt = nil
            effects.append(.completed(sessionId: s.id, notable: !failed && duration >= policy.notableTurnDuration, failed: failed))

        case .sessionIdle:
            guard s.state == .working || s.state == .needsInput else { break }
            if let t = s.turnStartedAt, e.timestamp < t { break }
            s.state = .idle
            s.questions.removeAll()
            s.turnStartedAt = nil
            s.activity = nil
            s.lastActivityAt = max(s.lastActivityAt, e.timestamp)

        case .usageUpdated:
            if let u = e.usage {
                if let c = u.context {
                    // Never let an estimate overwrite a verified value.
                    if !(c.source == .estimated && s.context?.source == .verified) { s.context = c }
                }
                if u.hasRateLimits, (rateLimits?.capturedAt ?? .distantPast) <= u.capturedAt {
                    rateLimits = UsageSnapshot(fiveHour: u.fiveHour, sevenDay: u.sevenDay, capturedAt: u.capturedAt)
                }
            }

        case .sessionEnded:
            break
        }
        return effects
    }

    // MARK: User actions

    /// Marks a question as answered from the notch. Returns false (and changes nothing) if
    /// the question is no longer answerable here — stale answers are never sent.
    @discardableResult
    public mutating func markAnswered(sessionId: String, questionId: String, now: Date = Date()) -> Bool {
        guard var s = sessions[sessionId],
              let i = s.questions.firstIndex(where: { $0.id == questionId }),
              s.questions[i].canAnswerHere else { return false }
        s.questions.remove(at: i)
        s.lastActivityAt = now
        if s.questions.isEmpty { s.state = .working }
        sessions[sessionId] = s
        return true
    }

    /// The question now has to be answered in the host (user chose so, hook timed out,
    /// or the hook connection dropped).
    public mutating func deferToHost(sessionId: String, questionId: String) {
        guard var s = sessions[sessionId],
              let i = s.questions.firstIndex(where: { $0.id == questionId }) else { return }
        s.questions[i].status = .deferredToHost
        sessions[sessionId] = s
    }

    // MARK: Time-based housekeeping

    /// Decays DONE → IDLE and removes dead or long-silent sessions.
    /// `isAlive` answers whether a Claude process id still exists (nil = unknown).
    public mutating func tick(now: Date, policy: StatePolicy = StatePolicy(), isAlive: (Int32) -> Bool? = { _ in nil }) {
        for (id, var s) in sessions {
            if let pid = s.claudePid, isAlive(pid) == false {
                sessions[id] = nil
                continue
            }
            if s.claudePid == nil || isAlive(s.claudePid!) == nil,
               s.state != .needsInput,
               now.timeIntervalSince(s.lastActivityAt) > policy.forgetSilentSessionsAfter {
                sessions[id] = nil
                continue
            }
            if s.state == .done, let c = s.completedAt, now.timeIntervalSince(c) > policy.doneToIdleAfter {
                s.state = .idle
                sessions[id] = s
            }
        }
        if let f = focusedSessionId, sessions[f] == nil { focusedSessionId = nil }
        if let r = rateLimits {
            // Claude Code drops windows once they reset; so do we.
            var r2 = r
            if let t = r.fiveHour?.resetsAt, t <= now { r2.fiveHour = nil }
            if let t = r.sevenDay?.resetsAt, t <= now { r2.sevenDay = nil }
            rateLimits = r2.hasRateLimits ? r2 : nil
        }
    }

    /// Prepares state loaded from disk: nothing restored may trigger celebrations, and
    /// questions whose hook connection died with the old app process must be answered in the host.
    public mutating func markRestored() {
        for (id, var s) in sessions {
            s.restored = true
            for i in s.questions.indices where s.questions[i].status == .pending {
                s.questions[i].status = .deferredToHost
            }
            sessions[id] = s
        }
    }

    // MARK: Priority / attention (PRD §6, §18)

    /// Sessions ordered for display: highest-priority state first, then most recent activity.
    public var orderedSessions: [Session] {
        sessions.values.sorted {
            if $0.state.priority != $1.state.priority { return $0.state.priority > $1.state.priority }
            if $0.state == .needsInput, let a = $0.currentQuestion?.createdAt, let b = $1.currentQuestion?.createdAt, a != b {
                return a < b // oldest question first: attention is a queue
            }
            if $0.lastActivityAt != $1.lastActivityAt { return $0.lastActivityAt > $1.lastActivityAt }
            return $0.id < $1.id
        }
    }

    /// The session currently requiring user action, if any. Retains priority over focus.
    public var attentionSession: Session? {
        orderedSessions.first { $0.state == .needsInput }
    }

    /// The session the notch should represent right now.
    public var primarySession: Session? {
        if let a = attentionSession { return a }
        if let f = focusedSessionId, let s = sessions[f] { return s }
        return orderedSessions.first
    }

    public var globalState: SessionState {
        sessions.values.map(\.state).max { $0.priority < $1.priority } ?? .idle
    }

    public func count(in state: SessionState) -> Int {
        sessions.values.filter { $0.state == state }.count
    }

    /// Single-line text description of the global state, for accessibility and the menu bar.
    public func statusText(now: Date) -> String {
        guard let p = primarySession else { return "Claude — Idle" }
        var parts = ["Claude", p.projectName, p.state.label]
        if p.state == .working, let e = p.elapsed(at: now) { parts.append(formatDuration(e)) }
        let waiting = count(in: .needsInput)
        if waiting > 1 { parts.append("\(waiting) sessions need you") }
        return parts.joined(separator: " — ")
    }
}
