import Foundation
import Testing
@testable import NotchCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func ev(_ type: NormalizedEvent.Kind, _ id: String = "A", at s: Double = 0,
                reason: NormalizedEvent.WorkReason? = nil, question: QuestionPayload? = nil,
                questionId: String? = nil, failed: Bool? = nil) -> NormalizedEvent {
    NormalizedEvent(type: type, sessionId: id, timestamp: t0.addingTimeInterval(s), workingDirectory: "/Users/x/Projects/\(id.lowercased())-app",
                    host: .cli, reason: reason, question: question, questionId: questionId, failed: failed)
}

private func q(_ id: String = "q1", answerable: Bool = true, kind: QuestionPayload.Kind = .question) -> QuestionPayload {
    QuestionPayload(id: id, kind: kind, items: [QuestionItem(text: "Which database?", options: [
        QuestionOption(label: "PostgreSQL"), QuestionOption(label: "SQLite"),
    ])], answerable: answerable)
}

@Suite struct StateTransitions {
    @Test func idleToWorking() {
        var s = AppState()
        s.apply(ev(.sessionStarted))
        #expect(s.sessions["A"]?.state == .idle)
        s.apply(ev(.sessionWorking, at: 1, reason: .prompt))
        #expect(s.sessions["A"]?.state == .working)
        #expect(s.sessions["A"]?.turnStartedAt == t0.addingTimeInterval(1))
        #expect(s.sessions["A"]?.projectName == "a-app")
    }

    @Test func workingToNeedsInputAndBack() {
        var s = AppState()
        s.apply(ev(.sessionWorking, reason: .prompt))
        let fx = s.apply(ev(.sessionNeedsInput, at: 5, question: q()))
        #expect(fx == [.attention(sessionId: "A", questionId: "q1")])
        #expect(s.sessions["A"]?.state == .needsInput)
        // A tool heartbeat must not clear a structured question.
        s.apply(ev(.sessionWorking, at: 6, reason: .tool))
        #expect(s.sessions["A"]?.state == .needsInput)
        s.apply(ev(.sessionInputResolved, at: 7, questionId: "q1"))
        #expect(s.sessions["A"]?.state == .working)
        // Timer keeps counting from the original turn start.
        #expect(s.sessions["A"]?.turnStartedAt == t0)
    }

    @Test func permissionClearedByToolActivity() {
        var s = AppState()
        s.apply(ev(.sessionWorking, reason: .prompt))
        s.apply(ev(.sessionNeedsInput, at: 2, question: q("p1", answerable: false, kind: .permission)))
        #expect(s.sessions["A"]?.currentQuestion?.status == .deferredToHost)
        s.apply(ev(.sessionWorking, at: 3, reason: .tool))
        #expect(s.sessions["A"]?.state == .working)
    }

    @Test func workingToDoneCelebratesOnlyNotableTurns() {
        var s = AppState()
        s.apply(ev(.sessionWorking, reason: .prompt))
        let fx = s.apply(ev(.sessionCompleted, at: 60))
        #expect(fx == [.completed(sessionId: "A", notable: true, failed: false)])
        #expect(s.sessions["A"]?.state == .done)
        #expect(s.sessions["A"]?.lastTurnDuration == 60)

        s.apply(ev(.sessionWorking, at: 100, reason: .prompt))
        let quick = s.apply(ev(.sessionCompleted, at: 103))
        #expect(quick == [.completed(sessionId: "A", notable: false, failed: false)])
    }

    @Test func needsInputToDone() {
        var s = AppState()
        s.apply(ev(.sessionWorking, reason: .prompt))
        s.apply(ev(.sessionNeedsInput, at: 1, question: q()))
        s.apply(ev(.sessionCompleted, at: 30))
        #expect(s.sessions["A"]?.state == .done)
        #expect(s.sessions["A"]?.questions.isEmpty == true)
    }

    @Test func doneToWorkingAndDoneToIdle() {
        var s = AppState()
        s.apply(ev(.sessionWorking, reason: .prompt))
        s.apply(ev(.sessionCompleted, at: 30))
        s.apply(ev(.sessionWorking, at: 40, reason: .prompt))
        #expect(s.sessions["A"]?.state == .working)
        #expect(s.sessions["A"]?.turnStartedAt == t0.addingTimeInterval(40))
        s.apply(ev(.sessionCompleted, at: 50))
        s.tick(now: t0.addingTimeInterval(50 + 301))
        #expect(s.sessions["A"]?.state == .idle)
    }

    @Test func duplicateCompletionDoesNotCelebrateTwice() {
        var s = AppState()
        s.apply(ev(.sessionWorking, reason: .prompt))
        #expect(s.apply(ev(.sessionCompleted, at: 30)).count == 1)
        #expect(s.apply(ev(.sessionCompleted, at: 30)).isEmpty)
    }

    @Test func staleHeartbeatAfterCompletionIsIgnored() {
        var s = AppState()
        s.apply(ev(.sessionWorking, reason: .prompt))
        s.apply(ev(.sessionCompleted, at: 30))
        // An async PostToolUse that was fired before Stop but delivered after it.
        s.apply(ev(.sessionWorking, at: 29, reason: .tool))
        #expect(s.sessions["A"]?.state == .done)
    }

    @Test func newPromptClearsOutstandingQuestions() {
        var s = AppState()
        s.apply(ev(.sessionWorking, reason: .prompt))
        s.apply(ev(.sessionNeedsInput, at: 1, question: q()))
        s.apply(ev(.sessionWorking, at: 5, reason: .prompt))
        #expect(s.sessions["A"]?.state == .working)
        #expect(s.sessions["A"]?.questions.isEmpty == true)
    }

    @Test func duplicateQuestionDeliveryIsIdempotent() {
        var s = AppState()
        #expect(s.apply(ev(.sessionNeedsInput, question: q())).count == 1)
        #expect(s.apply(ev(.sessionNeedsInput, at: 1, question: q())).isEmpty)
        #expect(s.sessions["A"]?.questions.count == 1)
    }

    @Test func interruptedTurnGoesIdleQuietly() {
        var s = AppState()
        s.apply(ev(.sessionWorking, reason: .prompt))
        s.apply(ev(.sessionNeedsInput, at: 5, question: q()))
        #expect(s.apply(ev(.sessionIdle, at: 70)).isEmpty) // no celebration
        #expect(s.sessions["A"]?.state == .idle)
        #expect(s.sessions["A"]?.questions.isEmpty == true)
        // Idle after a normal completion changes nothing.
        s.apply(ev(.sessionWorking, at: 80, reason: .prompt))
        s.apply(ev(.sessionCompleted, at: 120))
        s.apply(ev(.sessionIdle, at: 180))
        #expect(s.sessions["A"]?.state == .done)
    }

    @Test func sessionEndRemovesSession() {
        var s = AppState()
        s.apply(ev(.sessionWorking, reason: .prompt))
        s.focusedSessionId = "A"
        s.apply(ev(.sessionEnded, at: 1))
        #expect(s.sessions.isEmpty)
        #expect(s.focusedSessionId == nil)
    }
}

@Suite struct Priority {
    @Test func needsInputWinsGlobalAttention() {
        var s = AppState()
        s.apply(ev(.sessionWorking, "A", reason: .prompt))
        s.apply(ev(.sessionWorking, "B", at: 1, reason: .prompt))
        s.apply(ev(.sessionNeedsInput, "C", at: 2, question: q("c1")))
        #expect(s.globalState == .needsInput)
        #expect(s.attentionSession?.id == "C")
        #expect(s.primarySession?.id == "C")
    }

    @Test func attentionBeatsFocus() {
        var s = AppState()
        s.apply(ev(.sessionWorking, "A", reason: .prompt))
        s.apply(ev(.sessionNeedsInput, "B", at: 1, question: q("b1")))
        s.focusedSessionId = "A"
        #expect(s.primarySession?.id == "B")
        s.apply(ev(.sessionInputResolved, "B", at: 2, questionId: "b1"))
        #expect(s.primarySession?.id == "A")
    }

    @Test func simultaneousQuestionsQueueOldestFirst() {
        var s = AppState()
        s.apply(ev(.sessionNeedsInput, "B", at: 5, question: q("b1")))
        s.apply(ev(.sessionNeedsInput, "C", at: 2, question: q("c1")))
        #expect(s.attentionSession?.id == "C")
        s.apply(ev(.sessionInputResolved, "C", at: 6, questionId: "c1"))
        #expect(s.attentionSession?.id == "B")
    }

    @Test func completionElsewhereKeepsNeedsInputPriority() {
        var s = AppState()
        s.apply(ev(.sessionWorking, "A", reason: .prompt))
        s.apply(ev(.sessionNeedsInput, "B", at: 1, question: q("b1")))
        s.apply(ev(.sessionCompleted, "A", at: 40))
        #expect(s.primarySession?.id == "B")
    }

    @Test func statusTextDescribesState() {
        var s = AppState()
        s.apply(ev(.sessionWorking, "A", reason: .prompt))
        #expect(s.statusText(now: t0.addingTimeInterval(272)) == "Claude — a-app — Working — 04:32")
    }
}

@Suite struct Answers {
    @Test func answeringRoutesOnlyToThatSession() {
        var s = AppState()
        s.apply(ev(.sessionNeedsInput, "A", question: q("qa")))
        s.apply(ev(.sessionNeedsInput, "B", question: q("qb")))
        // Wrong session / question pair is refused (AC-017).
        #expect(s.markAnswered(sessionId: "B", questionId: "qa") == false)
        #expect(s.markAnswered(sessionId: "A", questionId: "qa") == true)
        #expect(s.sessions["A"]?.state == .working)
        #expect(s.sessions["B"]?.state == .needsInput)
    }

    @Test func staleQuestionCannotBeAnswered() {
        var s = AppState()
        s.apply(ev(.sessionNeedsInput, question: q()))
        s.deferToHost(sessionId: "A", questionId: "q1")
        #expect(s.markAnswered(sessionId: "A", questionId: "q1") == false)
        s.apply(ev(.sessionInputResolved, at: 1, questionId: "q1"))
        #expect(s.markAnswered(sessionId: "A", questionId: "q1") == false)
    }

    @Test func nonAnswerableQuestionIsDeferred() {
        var s = AppState()
        s.apply(ev(.sessionNeedsInput, question: q(answerable: false)))
        #expect(s.sessions["A"]?.currentQuestion?.canAnswerHere == false)
    }
}

@Suite struct Lifecycle {
    @Test func deadProcessesAreRemoved() {
        var s = AppState()
        var e = ev(.sessionWorking, reason: .prompt)
        e.claudePid = 4242
        s.apply(e)
        s.tick(now: t0.addingTimeInterval(1), isAlive: { _ in false })
        #expect(s.sessions.isEmpty)
    }

    @Test func silentSessionsWithoutPidAreForgotten() {
        var s = AppState()
        s.apply(ev(.sessionWorking, reason: .prompt))
        s.tick(now: t0.addingTimeInterval(60))
        #expect(s.sessions.count == 1)
        s.tick(now: t0.addingTimeInterval(4 * 3600))
        #expect(s.sessions.isEmpty)
    }

    @Test func restoredStateNeverCelebratesAndDefersQuestions() throws {
        var s = AppState()
        s.apply(ev(.sessionWorking, "A", reason: .prompt))
        s.apply(ev(.sessionNeedsInput, "B", question: q("b1")))
        let data = try JSONEncoder().encode(s)
        var restored = try JSONDecoder().decode(AppState.self, from: data)
        restored.markRestored()
        #expect(restored.sessions["A"]?.restored == true)
        #expect(restored.sessions["B"]?.currentQuestion?.status == .deferredToHost)
        // A completion observed live after restart still celebrates: it happened now.
        #expect(restored.apply(ev(.sessionCompleted, "A", at: 60)).count == 1)
    }
}

@Suite struct Usage {
    @Test func estimateNeverOverwritesVerified() {
        var s = AppState()
        var e = ev(.usageUpdated)
        e.usage = UsageSnapshot(context: PercentMetric(usedPercent: 40, source: .verified), capturedAt: t0)
        s.apply(e)
        e.usage = UsageSnapshot(context: PercentMetric(usedPercent: 10, source: .estimated), capturedAt: t0.addingTimeInterval(1))
        s.apply(e)
        #expect(s.sessions["A"]?.context == PercentMetric(usedPercent: 40, source: .verified))
    }

    @Test func rateLimitsExpireAtReset() {
        var s = AppState()
        var e = ev(.usageUpdated)
        e.usage = UsageSnapshot(fiveHour: RateWindow(usedPercent: 30, resetsAt: t0.addingTimeInterval(100)), capturedAt: t0)
        s.apply(e)
        #expect(s.rateLimits?.fiveHour?.usedPercent == 30)
        s.tick(now: t0.addingTimeInterval(101))
        #expect(s.rateLimits == nil)
    }
}

@Suite struct Validation {
    @Test func rejectsBadSessionIds() {
        #expect(throws: EventValidationError.invalidSessionId) {
            try NormalizedEvent(type: .sessionWorking, sessionId: "../../etc").validated()
        }
        #expect(throws: EventValidationError.invalidSessionId) {
            try NormalizedEvent(type: .sessionWorking, sessionId: "").validated()
        }
    }

    @Test func rejectsQuestionEventWithoutQuestion() {
        #expect(throws: EventValidationError.invalidQuestion) {
            try NormalizedEvent(type: .sessionNeedsInput, sessionId: "abc").validated()
        }
    }

    @Test func clampsOversizedText() throws {
        let long = String(repeating: "x", count: 10_000)
        let e = try NormalizedEvent(type: .sessionNeedsInput, sessionId: "abc", question: QuestionPayload(
            id: "q", kind: .question, items: Array(repeating: QuestionItem(text: long), count: 9), answerable: true
        )).validated()
        #expect(e.question?.items.count == 4)
        #expect((e.question?.items.first?.text.count ?? 0) <= 2_000)
    }

    @Test func formats() {
        #expect(formatDuration(272) == "04:32")
        #expect(formatDuration(3_725) == "1:02:05")
        #expect(formatCountdown(2 * 3600 + 14 * 60) == "2h 14m")
        #expect(projectName(forDirectory: "/Users/x/Projects/my-app") == "my-app")
    }
}

@Suite struct ContextWindow {
    @Test func sessionKeepsItsLargerWindow() {
        var state = AppState()
        func usage(_ pct: Double, _ window: Double) -> NormalizedEvent {
            var e = NormalizedEvent(type: .usageUpdated, sessionId: "s")
            e.usage = UsageSnapshot(context: PercentMetric(usedPercent: pct, source: .estimated, windowTokens: window))
            return e
        }
        state.apply(NormalizedEvent(type: .sessionStarted, sessionId: "s"))
        state.apply(usage(30, 1_000_000))   // 300k tokens: known 1M window
        state.apply(usage(90, 200_000))     // after compaction, 180k looks like 90% of 200k
        #expect(state.sessions["s"]?.context?.usedPercent == 18)
        #expect(state.sessions["s"]?.context?.windowTokens == 1_000_000)
    }
}
