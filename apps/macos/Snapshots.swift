import AppKit
import SwiftUI
import NotchCore

/// `ClaudeNotch --snapshot <dir>` renders every notch state to PNG with fixture data.
/// Used for docs/screenshots and for eyeballing layout without driving real sessions.
@MainActor
enum Snapshots {
    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let metrics = NotchMetrics(notchWidth: 185, notchHeight: 32, hasNotch: true)
        let now = Date()

        func event(_ type: NormalizedEvent.Kind, _ id: String, _ name: String, ago: Double = 0,
                   reason: NormalizedEvent.WorkReason? = nil, activity: String? = nil, host: SessionHost = .cli,
                   question: QuestionPayload? = nil) -> NormalizedEvent {
            NormalizedEvent(type: type, sessionId: id, timestamp: now.addingTimeInterval(-ago), projectName: name,
                            host: host, reason: reason, activity: activity, question: question)
        }

        var working = AppState()
        working.apply(event(.sessionWorking, "a", "ecommerce", ago: 761, reason: .prompt))
        working.apply(event(.sessionWorking, "a", "ecommerce", ago: 3, reason: .tool, activity: "Editing CheckoutView.swift"))
        working.apply(event(.sessionWorking, "c", "api", ago: 192, reason: .prompt))
        working.apply(event(.sessionWorking, "c", "api", ago: 2, reason: .tool, activity: "Run the test suite"))
        var u = event(.usageUpdated, "a", "ecommerce")
        u.usage = UsageSnapshot(context: PercentMetric(usedPercent: 61, source: .verified),
                                fiveHour: RateWindow(usedPercent: 78, resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60)),
                                sevenDay: RateWindow(usedPercent: 42, resetsAt: now.addingTimeInterval(3 * 86400 + 5 * 3600)),
                                capturedAt: now.addingTimeInterval(-60))
        working.apply(u)
        var u2 = event(.usageUpdated, "c", "api")
        u2.usage = UsageSnapshot(context: PercentMetric(usedPercent: 23, source: .estimated))
        working.apply(u2)

        var multi = working
        let q = QuestionPayload(id: "q1", kind: .question, items: [
            QuestionItem(text: "Which database should I use?", header: "Database", options: [
                QuestionOption(label: "PostgreSQL", description: "Production-grade, runs in Docker"),
                QuestionOption(label: "SQLite", description: "Zero setup, single file"),
                QuestionOption(label: "Keep investigating", description: "Compare both before deciding"),
            ]),
        ], answerable: true)
        multi.apply(event(.sessionWorking, "b", "marketing-site", ago: 300, reason: .prompt))
        multi.apply(event(.sessionNeedsInput, "b", "marketing-site", ago: 1, question: q))
        multi.apply(event(.sessionWorking, "d", "website", ago: 400, reason: .prompt))
        multi.apply(event(.sessionCompleted, "d", "website", ago: 20))

        var desktopQ = working
        var q2 = q
        q2.id = "q2"
        q2.answerable = false
        desktopQ.apply(event(.sessionNeedsInput, "e", "docs", host: .desktop, question: q2))

        var permission = working
        permission.apply(event(.sessionNeedsInput, "f", "infra", question: QuestionPayload(
            id: "p1", kind: .permission,
            items: [QuestionItem(text: "Allow running a command?", header: "Delete the build folder")], answerable: false)))

        let settings = AppSettings()
        settings.autoExpandOnQuestion = true
        settings.showCompletedSessions = true

        func shot(_ name: String, height: CGFloat = 330, configure: (NotchModel) -> Void) {
            let model = NotchModel(settings: settings)
            model.connection = .connected
            configure(model)
            let view = NotchRootView(model: model, settings: settings, metrics: metrics)
                .frame(width: 640, height: height)
                .background(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
            let r = ImageRenderer(content: view)
            r.scale = 2
            guard let img = r.nsImage, let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
            print("wrote \(name).png")
        }

        let sheet = HStack(spacing: 28) {
            ForEach(Array(zip(["working", "thinking", "waiting", "ack", "celebrate", "idle"],
                              [MascotMood.working, .thinking, .waiting, .acknowledging, .celebrating, .idle]).enumerated()), id: \.offset) { _, pair in
                VStack(spacing: 8) {
                    MascotView(mood: pair.1, height: 84, animated: false)
                    Text(pair.0).font(.caption).foregroundStyle(.white)
                }
            }
        }
        .padding(24)
        .background(Color.black)
        let r0 = ImageRenderer(content: sheet)
        r0.scale = 2
        if let img = r0.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("00-mascot.png"))
        }

        shot("01-compact-working", height: 90) { $0.setStateForPreview(working) }
        shot("02-peek", height: 110) { m in m.setStateForPreview(working); m.hovering = true }
        shot("03-question", height: 330) { $0.setStateForPreview(multi) }
        shot("04-sessions", height: 330) { m in
            var s = multi
            s.apply(NormalizedEvent(type: .sessionInputResolved, sessionId: "b", questionId: "q1"))
            s.apply(NormalizedEvent(type: .sessionNeedsInput, sessionId: "b", question: QuestionPayload(
                id: "q9", kind: .question, items: q.items, answerable: true)))
            m.setStateForPreview(s)
            m.later()
            m.expanded = true
            m.tab = .sessions
        }
        shot("05-usage", height: 360) { m in m.setStateForPreview(working); m.expanded = true; m.tab = .usage }
        shot("06-celebrating", height: 200) { m in
            var s = working
            s.apply(NormalizedEvent(type: .sessionCompleted, sessionId: "c"))
            m.setStateForPreview(s)
            m.setCelebrationForPreview(Celebration(sessionId: "c", notable: true, failed: false, startedAt: now.addingTimeInterval(-0.45)))
        }
        shot("07-acknowledged", height: 90) { m in m.setStateForPreview(working); m.setAcknowledgementForPreview("Got it!") }
        shot("08-question-desktop", height: 330) { $0.setStateForPreview(desktopQ) }
        shot("09-permission", height: 260) { $0.setStateForPreview(permission) }
        shot("10-onboarding", height: 330) { m in m.connection = .notConnected; m.showOnboarding = true }
        shot("11-needs-you-compact", height: 90) { m in m.setStateForPreview(multi); m.later() }
        shot("12-usage-unavailable", height: 300) { m in
            var s = AppState()
            s.apply(event(.sessionWorking, "z", "side-project", ago: 30, reason: .prompt))
            m.setStateForPreview(s); m.expanded = true; m.tab = .usage
        }
    }
}
