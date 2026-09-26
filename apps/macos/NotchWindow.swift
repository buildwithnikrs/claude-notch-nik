import AppKit
import SwiftUI

/// Borderless, non-activating panel pinned over the notch. It never steals focus from the
/// user's app, except when they click into the answer text field.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchLayout: ObservableObject {
    @Published var metrics = NotchMetrics(notchWidth: 180, notchHeight: 32, hasNotch: false)
}

/// Positions the panel, keeps its hit area matched to the visible shape (so clicks pass
/// through everywhere else), and drives hover / auto-collapse.
@MainActor
final class NotchWindowController {
    static let windowSize = CGSize(width: 780, height: 480)

    let panel = NotchPanel()
    let layout = NotchLayout()
    private let model: NotchModel
    private let settings: AppSettings
    private var contentSize: CGSize = .zero
    private var monitors: [Any] = []
    private var hoverTask: Task<Void, Never>?
    private var exitTask: Task<Void, Never>?
    private var screen: NSScreen?
    private var questionShownAt: Date?

    init(model: NotchModel, settings: AppSettings, onOpenSettings: @escaping () -> Void,
         onConnect: @escaping (Bool) -> Void, onDemo: @escaping () -> Void) {
        self.model = model
        self.settings = settings
        let root = LayoutHost(layout: layout, model: model, settings: settings,
                              onSizeChange: { [weak self] size in self?.contentSize = size; self?.updateMousePassthrough() },
                              onOpenSettings: onOpenSettings, onConnect: onConnect, onDemo: onDemo)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
        reposition()
        panel.orderFrontRegardless()
        installMonitors()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
    }

    // MARK: Geometry

    func reposition() {
        let screens = NSScreen.screens
        let notched = screens.first { $0.safeAreaInsets.top > 0 }
        let target = (settings.screen == .notched ? notched : nil) ?? NSScreen.main ?? screens.first
        guard let s = target else { return }
        screen = s
        var m: NotchMetrics
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            m = NotchMetrics(notchWidth: s.frame.width - l.width - r.width, notchHeight: s.safeAreaInsets.top, hasNotch: true)
        } else {
            let menuBar = max(s.frame.maxY - s.visibleFrame.maxY, NSStatusBar.system.thickness)
            m = NotchMetrics(notchWidth: 150, notchHeight: max(menuBar, 24), hasNotch: false)
        }
        if layout.metrics != m { layout.metrics = m }
        let size = Self.windowSize
        panel.setFrame(NSRect(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    /// The visible notch shape, in screen coordinates.
    private var interactiveRect: NSRect {
        guard let s = screen else { return .zero }
        let m = layout.metrics
        var size = contentSize
        if model.presentation == .hidden || size.height < m.notchHeight {
            size = CGSize(width: max(size.width, m.notchWidth), height: m.notchHeight)
        }
        return NSRect(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height, width: size.width, height: size.height)
    }

    // MARK: Mouse

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .rightMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            Task { @MainActor in self?.handle(e, global: true) }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            Task { @MainActor in self?.handle(e, global: false) }
            return e
        }) { monitors.append(l) }
    }

    private func handle(_ e: NSEvent, global: Bool) {
        let inside = interactiveRect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        updateMousePassthrough(inside: inside)

        if e.type == .leftMouseDown || e.type == .rightMouseDown {
            if global && !inside { clickedOutside() }
            return
        }
        if inside {
            exitTask?.cancel()
            exitTask = nil
            if !model.hovering && hoverTask == nil {
                hoverTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    guard let self, !Task.isCancelled else { return }
                    withAnimation(Theme.spring) { self.model.hovering = true }
                    self.hoverTask = nil
                }
            }
        } else {
            hoverTask?.cancel()
            hoverTask = nil
            if model.hovering { withAnimation(Theme.spring) { model.hovering = false } }
            if model.presentation == .expanded, exitTask == nil {
                exitTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard let self, !Task.isCancelled else { return }
                    self.exitTask = nil
                    if !self.interactiveRect.contains(NSEvent.mouseLocation) { self.model.collapse() }
                }
            }
        }
    }

    private func clickedOutside() {
        switch model.presentation {
        case .expanded:
            model.collapse()
        case .question:
            // Don't swallow a question the user hasn't had a chance to see.
            if let shown = questionShownAt, Date().timeIntervalSince(shown) > 1.5, !model.textFieldFocused {
                model.later()
            }
        default:
            break
        }
    }

    func updateMousePassthrough(inside: Bool? = nil) {
        let isInside = inside ?? interactiveRect.contains(NSEvent.mouseLocation)
        if case .question = model.presentation {
            if questionShownAt == nil { questionShownAt = Date() }
        } else {
            questionShownAt = nil
        }
        let wants = !isInside
        if panel.ignoresMouseEvents != wants { panel.ignoresMouseEvents = wants }
        if !isInside, panel.isKeyWindow, !model.textFieldFocused, model.presentation == .hidden || model.presentation == .compact {
            panel.resignKey()
        }
    }
}

/// Re-renders the root view when the notch metrics change (display switch, etc.).
private struct LayoutHost: View {
    @ObservedObject var layout: NotchLayout
    var model: NotchModel
    var settings: AppSettings
    var onSizeChange: (CGSize) -> Void
    var onOpenSettings: () -> Void
    var onConnect: (Bool) -> Void
    var onDemo: () -> Void

    var body: some View {
        NotchRootView(model: model, settings: settings, metrics: layout.metrics, onSizeChange: onSizeChange,
                      onOpenSettings: onOpenSettings, onConnect: onConnect, onDemo: onDemo)
    }
}
