import SwiftUI
import NotchCore

enum Theme {
    // Palette: pure black glass with a pink → lilac → periwinkle gradient.
    static let pink = Color(red: 0.976, green: 0.659, blue: 0.831)        // #F9A8D4
    static let fuchsia = Color(red: 0.941, green: 0.671, blue: 0.988)     // #F0ABFC
    static let lilac = Color(red: 0.847, green: 0.706, blue: 0.996)       // #D8B4FE
    static let periwinkle = Color(red: 0.647, green: 0.706, blue: 0.988)  // #A5B4FC
    static let glow = Color(red: 0.957, green: 0.447, blue: 0.714)        // #F472B6
    static let gradient = LinearGradient(colors: [pink, fuchsia, lilac, periwinkle], startPoint: .leading, endPoint: .trailing)

    static let accent = lilac
    static let attention = pink
    static let success = periwinkle
    static let text = Color.white
    static let secondary = Color.white.opacity(0.6)
    static let tertiary = Color.white.opacity(0.35)
    static let card = Color.white.opacity(0.07)
    static let cardHover = Color.white.opacity(0.11)
    static let hairline = Color.white.opacity(0.10)
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.78)

    static func color(for state: SessionState) -> Color {
        switch state {
        case .needsInput: return attention
        case .working: return accent
        case .done: return success
        case .idle: return tertiary
        }
    }
}

struct NotchMetrics: Equatable {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasNotch: Bool

    var wing: CGFloat { 76 }
    var compactWidth: CGFloat { notchWidth + wing * 2 }
    var panelWidth: CGFloat { max(notchWidth + 220, 500) }
}

/// A notch-like silhouette: concave top corners that blend into the bezel, rounded bottom.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let t = min(topRadius, r.width / 4), b = min(bottomRadius, r.height / 2, r.width / 4)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct ContentSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

// MARK: - Root

struct NotchRootView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var settings: AppSettings
    var metrics: NotchMetrics
    var onSizeChange: (CGSize) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}
    var onConnect: (Bool) -> Void = { _ in }
    var onDemo: () -> Void = {}

    var body: some View {
        let p = model.presentation
        VStack(spacing: 0) {
            content(p)
                .frame(width: width(for: p))
                .background(
                    NotchShape(topRadius: p == .hidden ? 0 : 8, bottomRadius: bottomRadius(for: p))
                        .fill(Color.black)
                        .shadow(color: .black.opacity(p == .hidden || p == .compact ? 0 : 0.45), radius: 20, y: 10)
                        .modifier(AttentionGlow(active: p != .hidden && model.state.globalState == .needsInput,
                                                animated: !model.reduceMotion))
                )
                .clipShape(NotchShape(topRadius: p == .hidden ? 0 : 8, bottomRadius: bottomRadius(for: p)))
                .background(GeometryReader { g in Color.clear.preference(key: ContentSizeKey.self, value: g.size) })
                .onPreferenceChange(ContentSizeKey.self) { onSizeChange($0) }
                .contentShape(Rectangle())
                .onTapGesture {
                    if p == .compact || p == .peek || p == .hidden { model.toggleExpanded() }
                }
                // Confetti bursts out from under the notch; an overlay so it never affects layout.
                .overlay(alignment: .top) {
                    if let c = model.celebration, c.notable, settings.completionAnimation, !model.reduceMotion,
                       settings.intensity != .subtle {
                        ConfettiView(start: c.startedAt, count: settings.intensity == .celebratory ? 70 : 36)
                            .frame(width: metrics.panelWidth + 80, height: 220)
                            .offset(y: metrics.notchHeight - 12)
                            .allowsHitTesting(false)
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(model.reduceMotion ? .easeInOut(duration: 0.15) : Theme.spring, value: p)
        .animation(model.reduceMotion ? nil : Theme.spring, value: model.questionStep)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.state.statusText(now: Date()))
    }

    private func width(for p: Presentation) -> CGFloat {
        switch p {
        case .hidden: return metrics.notchWidth
        case .compact: return metrics.compactWidth
        case .peek: return max(metrics.compactWidth, 320)
        case .expanded, .question: return metrics.panelWidth
        case .onboarding: return max(metrics.panelWidth - 20, 460)
        }
    }

    private func bottomRadius(for p: Presentation) -> CGFloat {
        switch p {
        case .hidden: return metrics.hasNotch ? 10 : 0
        case .compact: return 12
        case .peek: return 16
        default: return 24
        }
    }

    @ViewBuilder
    private func content(_ p: Presentation) -> some View {
        switch p {
        case .hidden:
            Color.clear.frame(height: metrics.hasNotch ? metrics.notchHeight : 0)
        case .compact:
            CompactBar(model: model, metrics: metrics)
        case .peek:
            VStack(spacing: 0) {
                CompactBar(model: model, metrics: metrics)
                PeekLine(model: model)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .padding(.top, 2)
            }
        case .expanded:
            VStack(spacing: 0) {
                HeaderBar(model: model, metrics: metrics)
                ExpandedPanel(model: model, settings: settings, onOpenSettings: onOpenSettings, onConnect: { onConnect(settings.readPlanUsage) })
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
        case .question:
            VStack(spacing: 0) {
                HeaderBar(model: model, metrics: metrics)
                if let (s, q) = model.activeQuestion {
                    QuestionCard(model: model, session: s, question: q)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 16)
                }
            }
        case .onboarding:
            VStack(spacing: 0) {
                Color.clear.frame(height: metrics.notchHeight)
                OnboardingCard(model: model, settings: settings, onConnect: onConnect, onDemo: onDemo)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
            }
        }
    }
}

// MARK: - Compact

@MainActor func mood(for model: NotchModel) -> MascotMood {
    if model.acknowledgement != nil { return .acknowledging }
    if let c = model.celebration, !c.failed { return .celebrating }
    switch model.state.globalState {
    case .needsInput: return .waiting
    case .working: return .working
    case .done, .idle: return .idle
    }
}

struct CompactBar: View {
    @ObservedObject var model: NotchModel
    var metrics: NotchMetrics

    var body: some View {
        HStack(spacing: 0) {
            HStack {
                MascotView(mood: mood(for: model), height: min(metrics.notchHeight - 4, 28),
                           animated: !model.reduceMotion && !model.animationsPaused)
                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
            .frame(width: metrics.wing)

            Spacer(minLength: metrics.notchWidth)

            HStack {
                Spacer(minLength: 0)
                CompactStatus(model: model)
            }
            .padding(.trailing, 14)
            .frame(width: metrics.wing)
        }
        .frame(height: metrics.notchHeight)
    }
}

struct CompactStatus: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        Group {
            if let ack = model.acknowledgement {
                Text(ack).foregroundStyle(Theme.success)
                    .lineLimit(1).minimumScaleFactor(0.6)
            } else if let c = model.celebration {
                Label(c.failed ? "Stopped" : "Done", systemImage: c.failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(c.failed ? Theme.attention : Theme.success)
            } else {
                switch model.state.globalState {
                case .needsInput:
                    HStack(spacing: 5) {
                        PulsingDot(color: Theme.attention, animated: !model.reduceMotion)
                        Text(model.state.count(in: .needsInput) > 1 ? "\(model.state.count(in: .needsInput)) need you" : "Needs you")
                            .foregroundStyle(Theme.gradient)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                case .working:
                    if let s = model.state.orderedSessions.first(where: { $0.state == .working }) {
                        HStack(spacing: 4) {
                            ElapsedText(since: s.turnStartedAt)
                                .foregroundStyle(Theme.text)
                            let n = model.state.count(in: .working)
                            if n > 1 {
                                Text("×\(n)").foregroundStyle(Theme.secondary).font(.system(size: 10, weight: .semibold))
                            }
                        }
                    }
                case .done:
                    Image(systemName: "checkmark").foregroundStyle(Theme.success.opacity(0.8))
                case .idle:
                    EmptyView()
                }
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }
}

struct ElapsedText: View {
    var since: Date?
    var prefix: String = ""

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(prefix + (since.map { formatDuration(max(0, ctx.date.timeIntervalSince($0))) } ?? "--:--"))
                .monospacedDigit()
        }
    }
}

/// The notch glows pink while any session needs you.
struct AttentionGlow: ViewModifier {
    var active: Bool
    var animated: Bool
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .shadow(color: Theme.glow.opacity(active ? (on ? 0.85 : 0.45) : 0), radius: active ? (on ? 16 : 9) : 0)
            .shadow(color: Theme.lilac.opacity(active ? 0.25 : 0), radius: 28)
            .onAppear { start() }
            .onChange(of: active) { _, _ in start() }
    }

    private func start() {
        guard animated, active else { on = false; return }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { on = true }
    }
}

struct PulsingDot: View {
    var color: Color
    var animated: Bool
    @State private var on = false

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .scaleEffect(on ? 1.25 : 0.85)
            .opacity(on ? 1 : 0.6)
            .onAppear {
                guard animated else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

struct PeekLine: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(spacing: 6) {
            if let s = model.state.primarySession {
                Circle().fill(Theme.color(for: s.state)).frame(width: 6, height: 6)
                Text(s.projectName).fontWeight(.semibold).foregroundStyle(Theme.text)
                Text(detail(s)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                let others = model.state.sessions.count - 1
                if others > 0 { Text("+\(others)").foregroundStyle(Theme.tertiary) }
            } else {
                Text("No Claude Code sessions yet").foregroundStyle(Theme.secondary)
                Spacer()
            }
        }
        .font(.system(size: 11.5))
    }

    private func detail(_ s: Session) -> String {
        switch s.state {
        case .working: return s.activity ?? "Working"
        case .needsInput: return "Needs you"
        case .done: return s.lastTurnFailed ? "Stopped" : "Done"
        case .idle: return "Idle"
        }
    }
}

// MARK: - Header (top row of the expanded notch)

struct HeaderBar: View {
    @ObservedObject var model: NotchModel
    var metrics: NotchMetrics

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                MascotView(mood: mood(for: model), height: min(metrics.notchHeight - 4, 28),
                           animated: !model.reduceMotion && !model.animationsPaused)
                Text("Claude").font(.system(size: 13, weight: .semibold)).tracking(-0.2).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
            Spacer(minLength: metrics.notchWidth + 8)
            HStack {
                Spacer(minLength: 0)
                CompactStatus(model: model)
            }
            .padding(.trailing, 16)
        }
        .frame(height: max(metrics.notchHeight, 30))
    }
}
