import AppKit
import SwiftUI
import NotchCore
import NotchBridge
import ClaudeCodeAdapter

enum ConnectionStatus: Equatable {
    case unknown
    case notConnected
    case connected
    case needsUpdate
    case error(String)

    var label: String {
        switch self {
        case .unknown: return "Checking…"
        case .notConnected: return "Claude Code not connected"
        case .connected: return "Connected to Claude Code"
        case .needsUpdate: return "Connection needs an update"
        case .error(let m): return m
        }
    }
}

/// What the notch is currently showing. Derived, never stored.
enum Presentation: Equatable {
    case hidden
    case compact
    case peek
    case expanded
    case question(sessionId: String, questionId: String)
    case onboarding
}

enum ExpandedTab: String, CaseIterable {
    case sessions = "Sessions"
    case usage = "Usage"
}

struct Celebration: Equatable {
    var sessionId: String
    var notable: Bool
    var failed: Bool
    var startedAt: Date
}

/// Owns app state and translates core effects into UI moments. The core state machine
/// remains the source of truth for session status; this only adds presentation state.
@MainActor
final class NotchModel: ObservableObject {
    @Published private(set) var state = AppState()
    @Published var expanded = false
    @Published var tab: ExpandedTab = .sessions
    @Published var hovering = false
    @Published private(set) var celebration: Celebration?
    @Published private(set) var acknowledgement: String?
    @Published var connection: ConnectionStatus = .unknown
    @Published var showOnboarding = false
    @Published var onboardingConnected = false
    @Published private(set) var dismissedQuestions: Set<String> = []
    @Published var animationsPaused = false
    /// Current step within a multi-question AskUserQuestion call, and answers so far.
    @Published var questionStep = 0
    @Published var draftAnswers: [String: String] = [:]
    @Published var freeText = ""
    @Published var textFieldFocused = false

    let settings: AppSettings
    let sounds = SoundPlayer()
    private var pending: [String: PendingReply] = [:]
    private var celebrationTask: Task<Void, Never>?
    private var ackTask: Task<Void, Never>?
    var onStateChanged: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: Derived presentation

    var presentation: Presentation {
        if showOnboarding { return .onboarding }
        if let s = state.attentionSession, let q = s.currentQuestion,
           !dismissedQuestions.contains(q.id), settings.autoExpandOnQuestion || expanded {
            return .question(sessionId: s.id, questionId: q.id)
        }
        if expanded { return .expanded }
        if celebration != nil || acknowledgement != nil { return .compact }
        let visible = state.sessions.values.contains { $0.state != .idle }
        if hovering { return .peek }
        return visible ? .compact : .hidden
    }

    var activeQuestion: (Session, Question)? {
        guard case .question(let sid, let qid) = presentation,
              let s = state.sessions[sid], let q = s.questions.first(where: { $0.id == qid }) else { return nil }
        return (s, q)
    }

    var visibleSessions: [Session] {
        state.orderedSessions.filter { settings.showCompletedSessions || ($0.state != .done && $0.state != .idle) }
    }

    var reduceMotion: Bool { settings.reduceMotion }

    // MARK: Events from the bridge

    func handle(_ event: NormalizedEvent, reply: PendingReply?) {
        if let reply, let q = event.question {
            pending[q.id]?.send(BridgeReply(questionId: q.id, action: .defer)) // superseded duplicate
            pending[q.id] = reply
            reply.onDisconnect = { [weak self] in
                // The hook gave up (timeout / interrupted): the terminal now owns the question.
                self?.hookDisconnected(sessionId: event.sessionId, questionId: q.id)
            }
        }
        apply(event)
    }

    func apply(_ event: NormalizedEvent) {
        let before = state.attentionSession?.currentQuestion?.id
        let effects = state.apply(event)
        for fx in effects { perform(fx) }
        if state.attentionSession?.currentQuestion?.id != before {
            questionStep = 0
            draftAnswers = [:]
            freeText = ""
        }
        prunePending()
        onStateChanged?()
    }

    private func perform(_ fx: StateEffect) {
        switch fx {
        case .attention(let sid, let qid):
            dismissedQuestions.remove(qid)
            if settings.attentionSound { sounds.attention() }
            _ = sid
        case .completed(let sid, let notable, let failed):
            // A needs-input session elsewhere keeps priority; keep celebrations short then.
            let busyElsewhere = state.attentionSession != nil
            guard settings.completionAnimation || settings.completionSound else { return }
            if settings.completionSound && notable && !busyElsewhere { sounds.completion(intensity: settings.intensity) }
            guard settings.completionAnimation else { return }
            celebration = Celebration(sessionId: sid, notable: notable && !busyElsewhere, failed: failed, startedAt: Date())
            celebrationTask?.cancel()
            let duration: Double = notable && !busyElsewhere ? (settings.intensity == .celebratory ? 4.5 : 3.2) : 1.8
            celebrationTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { self?.celebration = nil }
            }
        case .acknowledged:
            break
        }
    }

    private func hookDisconnected(sessionId: String, questionId: String) {
        pending[questionId] = nil
        state.deferToHost(sessionId: sessionId, questionId: questionId)
        onStateChanged?()
    }

    private func prunePending() {
        let live = Set(state.sessions.values.flatMap { $0.questions.map(\.id) })
        for (id, p) in pending where !live.contains(id) {
            p.send(BridgeReply(questionId: id, action: .defer))
            pending[id] = nil
        }
    }

    // MARK: User actions

    /// Records the answer for the current item; submits once every item is answered.
    func choose(_ answer: String) {
        guard let (session, question) = activeQuestion, question.canAnswerHere else { return }
        let items = question.items
        guard questionStep < items.count else { return }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draftAnswers[items[questionStep].text] = trimmed
        freeText = ""
        if questionStep + 1 < items.count {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { questionStep += 1 }
            return
        }
        submit(session: session, question: question, answers: draftAnswers)
    }

    private func submit(session: Session, question: Question, answers: [String: String]) {
        // Validate the question is still live on both ends before sending (PRD §52).
        guard let reply = pending[question.id], reply.isOpen,
              reply.sessionId == session.id,
              state.markAnswered(sessionId: session.id, questionId: question.id) else {
            state.deferToHost(sessionId: session.id, questionId: question.id)
            acknowledge("Answer in \(session.host.displayName)")
            onStateChanged?()
            return
        }
        let sent = reply.send(BridgeReply(questionId: question.id, action: .answer, answers: answers))
        pending[question.id] = nil
        acknowledge(sent ? ["Got it!", "On it!", "Thanks!"].randomElement()! : "Answer in \(session.host.displayName)")
        questionStep = 0
        draftAnswers = [:]
        textFieldFocused = false
        onStateChanged?()
    }

    func answerInHost() {
        guard let (session, question) = activeQuestion else { return }
        if let reply = pending[question.id] {
            reply.send(BridgeReply(questionId: question.id, action: .defer))
            pending[question.id] = nil
        }
        state.deferToHost(sessionId: session.id, questionId: question.id)
        later()
        HostActivator.activate(session: session)
        onStateChanged?()
    }

    /// Collapse the question card; the notch keeps showing "Needs you".
    func later() {
        guard let (_, q) = activeQuestion else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            dismissedQuestions.insert(q.id)
            expanded = false
            textFieldFocused = false
        }
    }

    func openQuestion(for sessionId: String) {
        guard let q = state.sessions[sessionId]?.currentQuestion else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            dismissedQuestions.remove(q.id)
            state.focusedSessionId = sessionId
        }
    }

    func focus(_ sessionId: String) {
        state.focusedSessionId = sessionId
        if state.sessions[sessionId]?.state == .needsInput { openQuestion(for: sessionId) }
        onStateChanged?()
    }

    func toggleExpanded() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
            if case .question = presentation {
                later()
            } else {
                expanded.toggle()
                // Re-open a dismissed question when the user explicitly opens the notch.
                if expanded, let q = state.attentionSession?.currentQuestion { dismissedQuestions.remove(q.id) }
            }
        }
    }

    func collapse() {
        guard !textFieldFocused else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
            expanded = false
            if case .question = presentation, let q = activeQuestion?.1 { dismissedQuestions.insert(q.id) }
        }
    }

    private func acknowledge(_ text: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            acknowledgement = text
            expanded = false
        }
        ackTask?.cancel()
        ackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { self?.acknowledgement = nil }
        }
    }

    // MARK: Housekeeping

    func tick() {
        let before = state
        state.tick(now: Date(), isAlive: { ProcessTree.isAlive($0) })
        if state != before {
            prunePending()
            onStateChanged?()
        }
    }

    func restore(_ restored: AppState) {
        var s = restored
        s.markRestored()
        s.tick(now: Date(), isAlive: { ProcessTree.isAlive($0) })
        state = s
    }

    /// For snapshots / previews.
    func setStateForPreview(_ s: AppState) { state = s }
    func setCelebrationForPreview(_ c: Celebration?) { celebration = c }
    func setAcknowledgementForPreview(_ a: String?) { acknowledgement = a }
}
