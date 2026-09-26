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

    /// Esc closes whatever the notch is showing.
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// The panel is never the active window, so buttons must respond to the very first click.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
        let host = FirstClickHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
        panel.onEscape = { [weak model] in model?.dismiss() }
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
        // Clicks reach global monitors reliably, so they're event-driven.
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            Task { @MainActor in self?.handleClick(global: true) }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] e in
            Task { @MainActor in self?.handleClick(global: false) }
            return e
        }) { monitors.append(l) }

        // Pointer position is polled: macOS only generates mouse-moved events over windows that
        // ask for them, so a monitor can miss the pointer arriving over the notch entirely and
        // clicks would fall through to the window behind it.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private var pointerTimer: Timer?
    private var lastPointer: NSPoint = .zero

    private var pointerInside: Bool {
        interactiveRect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    private func handleClick(global: Bool) {
        let inside = pointerInside
        updateMousePassthrough(inside: inside)
        if global && !inside { clickedOutside() }
    }

    private func trackPointer() {
        let location = NSEvent.mouseLocation
        let moved = location != lastPointer
        lastPointer = location
        let inside = pointerInside
        updateMousePassthrough(inside: inside)
        guard moved || model.presentation == .expanded else { return }

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
                    if !self.pointerInside { self.model.collapse() }
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
