import SwiftUI
import NotchCore

// MARK: - Expanded panel

struct ExpandedPanel: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var settings: AppSettings
    var onOpenSettings: () -> Void
    var onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(ExpandedTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(Theme.spring) { model.tab = tab }
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(Capsule().fill(model.tab == tab ? Color.white.opacity(0.12) : .clear))
                            .overlay(Capsule().strokeBorder(model.tab == tab ? Theme.hairline : .clear, lineWidth: 1))
                            .foregroundStyle(model.tab == tab ? Theme.text : Theme.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape.fill").foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }

            Group {
                switch model.tab {
                case .sessions: SessionList(model: model)
                case .usage: UsagePanel(model: model)
                }
            }
            .transition(.opacity)

            if model.connection != .connected {
                ConnectionBanner(status: model.connection, onConnect: onConnect)
            }
        }
    }
}

struct ConnectionBanner: View {
    var status: ConnectionStatus
    var onConnect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle").foregroundStyle(Theme.pink)
            Text(status.label).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            Spacer()
            if status != .unknown {
                Button(status == .needsUpdate ? "Reconnect" : "Connect Claude Code", action: onConnect)
                    .buttonStyle(PillButtonStyle(prominent: true))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

// MARK: Sessions

struct SessionList: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let sessions = model.visibleSessions
        if sessions.isEmpty {
            VStack(spacing: 6) {
                Text("No Claude Code sessions right now")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Start `claude` in a terminal, or a session in the Claude app — it'll show up here.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        } else {
            let rows = VStack(spacing: 6) {
                ForEach(sessions) { s in
                    SessionRow(session: s, focused: model.state.primarySession?.id == s.id,
                               onSelect: { model.focus(s.id) },
                               onOpenHost: { HostActivator.activate(session: s) })
                }
            }
            if sessions.count <= 4 {
                rows
            } else {
                ScrollView(.vertical, showsIndicators: false) { rows }.frame(height: 250)
            }
        }
    }
}

struct SessionRow: View {
    var session: Session
    var focused: Bool
    var onSelect: () -> Void
    var onOpenHost: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.color(for: session.state)).frame(width: 8, height: 8)
                .overlay(Circle().stroke(Theme.color(for: session.state).opacity(0.35), lineWidth: session.state == .needsInput ? 4 : 0))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.projectName)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(session.host.displayName)
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .foregroundStyle(Theme.tertiary)
                }
                subtitle
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let c = session.context {
                MiniMeter(value: c.usedPercent, estimated: c.source == .estimated)
                    .help(c.source == .estimated ? "Context used (estimated)" : "Context used")
            }
            if hover {
                Button(action: onOpenHost) {
                    Image(systemName: "arrow.up.forward.app").foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .help("Open \(session.host.displayName)")
                .accessibilityLabel("Open \(session.host.displayName)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 16).fill(hover || focused ? Theme.cardHover : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hairline, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.projectName), \(session.state.label)")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var subtitle: some View {
        switch session.state {
        case .working:
            HStack(spacing: 4) {
                ElapsedText(since: session.turnStartedAt, prefix: "Working · ")
                if let a = session.activity { Text("· \(a)") }
            }
        case .needsInput:
            Text(session.currentQuestion.map { "Needs you · \($0.items.first?.text ?? "")" } ?? "Needs you")
                .foregroundStyle(Theme.pink)
        case .done:
            Text(session.lastTurnFailed ? "Stopped with an error" :
                 "Done" + (session.lastTurnDuration.map { " · took \(formatDuration($0))" } ?? ""))
        case .idle:
            Text(session.restored ? "Idle · restored" : "Idle")
        }
    }
}

struct MiniMeter: View {
    var value: Double
    var estimated: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(Int(value.rounded()))%\(estimated ? "~" : "")")
                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
            Meter(value: value, height: 3).frame(width: 34)
        }
    }
}

struct Meter: View {
    var value: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(value >= 85 ? AnyShapeStyle(Theme.glow) : AnyShapeStyle(Theme.gradient))
                    .frame(width: max(height, g.size.width * CGFloat(min(max(value, 0), 100) / 100)))
            }
        }
        .frame(height: height)
        .animation(Theme.spring, value: value)
    }
}

// MARK: Usage

struct UsagePanel: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let now = ctx.date
            VStack(alignment: .leading, spacing: 10) {
                if let r = model.state.rateLimits, r.hasRateLimits {
                    if let w = r.fiveHour {
                        UsageRow(title: "Current session", caption: "5-hour window", value: w.usedPercent, badge: nil,
                                 trailing: w.resetsAt.map { "Resets in \(formatCountdown($0.timeIntervalSince(now)))" })
                    }
                    if let w = r.sevenDay {
                        UsageRow(title: "Weekly", caption: "7-day window", value: w.usedPercent, badge: nil,
                                 trailing: w.resetsAt.map { "Resets in \(formatCountdown($0.timeIntervalSince(now)))" })
                    }
                } else {
                    UnavailableRow(title: "Plan usage unavailable",
                                   caption: "Claude Code shares your 5-hour and weekly limits only when it runs in Terminal. The Claude app and IDEs don't report them, so they show up here after your first reply in a Terminal session.")
                }

                if let s = model.state.primarySession, let c = s.context {
                    UsageRow(title: "Context", caption: s.projectName, value: c.usedPercent,
                             badge: c.source == .estimated ? "Estimated" : nil, trailing: nil)
                } else {
                    UnavailableRow(title: "Context unavailable", caption: "Appears after Claude's first reply in a session.")
                }

                if let t = model.state.rateLimits?.capturedAt {
                    Text("Plan usage as reported by Claude Code \(relative(t, now)) · daily limits aren't reported")
                        .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                }
            }
        }
    }

    private func relative(_ t: Date, _ now: Date) -> String {
        let s = now.timeIntervalSince(t)
        return s < 60 ? "just now" : "\(formatCountdown(s)) ago"
    }
}

struct UsageRow: View {
    var title: String
    var caption: String
    var value: Double
    var badge: String?
    var trailing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Text(caption).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                if let badge {
                    Text(badge).font(.system(size: 9.5, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().stroke(Theme.secondary, lineWidth: 1))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                Text("\(Int(value.rounded()))%")
                    .font(.system(size: 13, weight: .bold).monospacedDigit()).foregroundStyle(Theme.text)
            }
            Meter(value: value)
            if let trailing {
                Text(trailing).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

struct UnavailableRow: View {
    var title: String
    var caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
            Text(caption).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

// MARK: - Question

struct QuestionCard: View {
    @ObservedObject var model: NotchModel
    var session: Session
    var question: Question
    @FocusState private var fieldFocused: Bool
    @State private var multi: Set<String> = []

    var body: some View {
        let step = min(model.questionStep, question.items.count - 1)
        let item = question.items[step]
        let hostName = HostActivator.hostAppName(session: session)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(Theme.glow).frame(width: 6, height: 6).shadow(color: Theme.glow, radius: 4)
                Text(session.projectName).fontWeight(.semibold).foregroundStyle(Theme.text)
                Text(title).foregroundStyle(Theme.secondary)
                Spacer()
                if question.items.count > 1 {
                    Text("\(step + 1) of \(question.items.count)").foregroundStyle(Theme.tertiary).monospacedDigit()
                }
            }
            .font(.system(size: 11.5))

            if let h = item.header, question.kind == .question {
                Text(h.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(1.2).foregroundStyle(Theme.gradient)
            }
            Text(item.text)
                .font(.system(size: 17, weight: .semibold)).tracking(-0.4).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .id("q-\(step)")
                .transition(.push(from: .trailing))
            if question.kind == .permission, let detail = item.header {
                Text(detail).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            }

            if !item.options.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(item.options, id: \.label) { opt in
                        OptionButton(option: opt, selected: multi.contains(opt.label), enabled: question.canAnswerHere) {
                            if item.multiSelect {
                                if multi.contains(opt.label) { multi.remove(opt.label) } else { multi.insert(opt.label) }
                            } else {
                                model.choose(opt.label)
                            }
                        }
                    }
                }
                .id("opts-\(step)")
            }

            if question.canAnswerHere {
                HStack(spacing: 6) {
                    TextField("Type your own answer…", text: $model.freeText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                        .focused($fieldFocused)
                        .onSubmit { submitText(item) }
                    if item.multiSelect || !model.freeText.isEmpty {
                        Button(item.multiSelect && model.freeText.isEmpty ? "Submit" : "Send") { submitText(item) }
                            .buttonStyle(PillButtonStyle(prominent: true))
                            .disabled(item.multiSelect ? (multi.isEmpty && model.freeText.isEmpty) : model.freeText.isEmpty)
                    }
                }
                HStack {
                    Button("Answer in \(hostName) instead") { model.answerInHost() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    Spacer()
                    Button("Later") { model.later() }.buttonStyle(PillButtonStyle(prominent: false))
                }
            } else {
                HStack {
                    Text(question.kind == .question ? "Answer this in \(hostName)." : "Respond in \(hostName).")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("Later") { model.later() }.buttonStyle(PillButtonStyle(prominent: false))
                    Button("Open \(hostName)") { model.answerInHost() }.buttonStyle(PillButtonStyle(prominent: true))
                }
            }
        }
        .onChange(of: fieldFocused) { _, f in model.textFieldFocused = f }
        .onChange(of: model.questionStep) { _, _ in multi = [] }
    }

    private var title: String {
        switch question.kind {
        case .question: return "· Claude needs your input"
        case .permission: return "· Claude wants permission"
        case .elicitation: return "· A tool needs your input"
        }
    }

    private func submitText(_ item: QuestionItem) {
        var parts = item.options.map(\.label).filter { multi.contains($0) }
        let typed = model.freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { parts.append(typed) }
        guard !parts.isEmpty else { return }
        fieldFocused = false
        model.choose(parts.joined(separator: ", "))
    }
}

struct OptionButton: View {
    var option: QuestionOption
    var selected: Bool
    var enabled: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.label).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text).lineLimit(2)
                if let d = option.description, !d.isEmpty {
                    Text(d).font(.system(size: 10.5)).foregroundStyle(Theme.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(selected ? Theme.lilac.opacity(0.16) : (hover && enabled ? Theme.cardHover : Theme.card))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.hairline), lineWidth: selected ? 1.2 : 1)
            )
            .scaleEffect(hover && enabled ? 1.02 : 1)
            .opacity(enabled ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
        .accessibilityLabel(option.label)
        .accessibilityHint(option.description ?? "")
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(prominent ? Color.white : Color.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : Theme.hairline, lineWidth: 1))
            .foregroundStyle(prominent ? Color.black : Color.white)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Onboarding

struct OnboardingCard: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var settings: AppSettings
    var onConnect: (Bool) -> Void
    var onDemo: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            MascotView(mood: model.onboardingConnected ? .celebrating : .waiting, height: 44,
                       animated: !model.reduceMotion)
            if model.onboardingConnected {
                Text("You're connected.").font(.system(size: 20, weight: .semibold)).tracking(-0.6).foregroundStyle(Theme.gradient)
                Text("You're all set. Claude Code sessions you start from now on will show up here. Already-open sessions need a restart.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Show me a demo", action: onDemo).buttonStyle(PillButtonStyle(prominent: false))
                    Button("Done") {
                        withAnimation(Theme.spring) { model.showOnboarding = false }
                        settings.onboarded = true
                    }
                    .buttonStyle(PillButtonStyle(prominent: true))
                }
            } else {
                (Text("I'm here when\n").foregroundStyle(Theme.text) + Text("Claude needs you.").foregroundStyle(Theme.gradient))
                    .font(.system(size: 22, weight: .semibold)).tracking(-0.8).multilineTextAlignment(.center)
                Text("Go do something else — the notch lights up when Claude Code has a question or finishes. Nothing leaves your Mac.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: $settings.readPlanUsage) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show plan usage").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text("Adds a small status line to Claude Code in Terminal (keeps yours if you have one).")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                    }
                }
                .toggleStyle(.switch).controlSize(.mini).tint(Theme.lilac)
                .padding(12).background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hairline, lineWidth: 1))
                if case .error(let why) = model.connection {
                    Text(why).font(.system(size: 11)).foregroundStyle(Theme.pink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Not now") {
                        withAnimation(Theme.spring) { model.showOnboarding = false }
                        settings.onboarded = true
                    }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    Button("Connect Claude Code") { onConnect(settings.readPlanUsage) }
                        .buttonStyle(PillButtonStyle(prominent: true))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Confetti

struct ConfettiView: View {
    var start: Date
    var count: Int
    private static let colors: [Color] = [Theme.pink, Theme.fuchsia, Theme.lilac, Theme.periwinkle, .white]

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSince(start)
            Canvas { gc, size in
                guard t < 2.2 else { return }
                Self.draw(in: &gc, size: size, t: t, seed: UInt64(start.timeIntervalSince1970 * 1000), count: count)
            }
        }
    }

    private static func draw(in gc: inout GraphicsContext, size: CGSize, t: Double, seed: UInt64, count: Int) {
        var rng = SeededRandom(seed: seed)
        let alpha = max(0, 1 - t / 2.2)
        for i in 0..<count {
            let angle: Double = Double.pi * (0.15 + 0.7 * rng.next()) // downward fan
            let speed: Double = 120 + 180 * rng.next()
            let spin: Double = (rng.next() - 0.5) * 12
            let side: Double = i % 2 == 0 ? 1 : -1
            let dx: Double = cos(angle) * speed * t * side
            let dy: Double = sin(angle) * speed * t * 0.6 + 220 * t * t
            var g = gc
            g.opacity = alpha
            g.translateBy(x: size.width / 2 + CGFloat(dx), y: CGFloat(dy))
            g.rotate(by: .radians(spin * t))
            let w: CGFloat = i % 3 == 0 ? 3 : 5
            g.fill(Path(CGRect(x: -w / 2, y: -1.5, width: w, height: 3)), with: .color(colors[i % colors.count]))
        }
    }
}

struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
    }
}
