import AppKit
import SwiftUI
import NotchCore
import NotchBridge

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let settings = AppSettings()
    lazy var model = NotchModel(settings: settings)
    private var server: BridgeServer?
    private var notch: NotchWindowController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var timers: [Timer] = []
    private var saveTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.enabled = settings.diagnosticLogging
        try? BridgePaths.ensureSupportDirectory()

        let server = BridgeServer()
        server.onEvent = { [weak self] event, reply in
            MainActor.assumeIsolated { self?.model.handle(event, reply: reply) }
        }
        server.onRejected = { why in Log.info("rejected message: \(why)") }
        do {
            try server.start()
        } catch BridgeServerError.alreadyRunning {
            let a = NSAlert()
            a.messageText = "Claude Notch is already running"
            a.runModal()
            NSApp.terminate(nil)
            return
        } catch {
            model.connection = .error("Couldn't start the local bridge (\(error)).")
        }
        self.server = server

        if let saved = StatePersistence.load() { model.restore(saved) }
        model.onStateChanged = { [weak self] in self?.stateChanged() }

        notch = NotchWindowController(
            model: model, settings: settings,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onConnect: { [weak self] statusLine in self?.connect(includeStatusLine: statusLine) },
            onDemo: { [weak self] in self?.runDemo() }
        )
        setUpStatusItem()
        refreshConnection()
        if model.connection == .connected || model.connection == .needsUpdate {
            // Keep the installed helper in sync with this app version.
            try? Integration.syncHelper()
            refreshConnection()
        }
        if !settings.onboarded { model.showOnboarding = true }

        timers.append(Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.tick() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshConnection() }
        })
        for t in timers { t.tolerance = 5 }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.animationsPaused = true }
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.animationsPaused = false
                self?.model.tick()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        StatePersistence.save(model.state)
        server?.stop()
    }

    // MARK: State

    private func stateChanged() {
        updateStatusItem()
        notch?.updateMousePassthrough()
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            StatePersistence.save(self.model.state)
        }
    }

    private func refreshConnection() {
        if case .error = model.connection, server == nil { return }
        model.connection = Integration.status(includeStatusLine: settings.readPlanUsage)
        updateStatusItem()
    }

    private func connect(includeStatusLine: Bool) {
        do {
            try Integration.connect(includeStatusLine: includeStatusLine)
            refreshConnection()
            withAnimation(Theme.spring) { model.onboardingConnected = true }
        } catch {
            model.connection = .error(error.localizedDescription)
        }
    }

    private func disconnect() {
        do {
            try Integration.disconnect()
        } catch {
            model.connection = .error(error.localizedDescription)
            return
        }
        refreshConnection()
    }

    private func runDemo() {
        withAnimation(Theme.spring) { model.showOnboarding = false }
        settings.onboarded = true
        guard let helper = Integration.bundledHookURL else { return }
        let p = Process()
        p.executableURL = helper
        p.arguments = ["demo"]
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        switch model.state.globalState {
        case .needsInput: symbol = "exclamationmark.bubble.fill"
        case .working: symbol = "sparkle"
        case .done: symbol = "checkmark.seal"
        case .idle: symbol = "sparkle"
        }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: model.state.statusText(now: Date()))
        img?.isTemplate = true
        button.image = img
        button.toolTip = model.state.statusText(now: Date())
        button.setAccessibilityLabel(model.state.statusText(now: Date()))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: model.state.statusText(now: Date()), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        for s in model.state.orderedSessions.prefix(8) {
            var title = "\(s.projectName) — \(s.state.label)"
            if s.state == .working, let e = s.elapsed(at: Date()) { title += " · \(formatDuration(e))" }
            let item = NSMenuItem(title: title, action: #selector(openSessionHost(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.id
            item.indentationLevel = 1
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Notch", action: #selector(openNotch), keyEquivalent: "").target = self
        let conn = model.connection
        let connTitle = conn == .connected ? "Disconnect Claude Code" : (conn == .needsUpdate ? "Reconnect Claude Code" : "Connect Claude Code")
        menu.addItem(withTitle: connTitle, action: #selector(toggleConnection), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Claude Notch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func openSessionHost(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let s = model.state.sessions[id] else { return }
        if s.state == .needsInput { model.focus(id) } else { HostActivator.activate(session: s) }
    }

    @objc private func openNotch() { model.toggleExpanded() }

    @objc private func toggleConnection() {
        if model.connection == .connected { disconnect() } else { connect(includeStatusLine: settings.readPlanUsage) }
    }

    @objc private func openSettingsAction() { openSettings() }

    func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, model: model,
                                    onConnect: { [weak self] in self?.connect(includeStatusLine: self?.settings.readPlanUsage ?? true) },
                                    onDisconnect: { [weak self] in self?.disconnect() },
                                    onScreenChange: { [weak self] in self?.notch?.reposition() })
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Claude Notch Settings"
            w.contentView = NSHostingView(rootView: view)
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: NotchModel
    var onConnect: () -> Void
    var onDisconnect: () -> Void
    var onScreenChange: () -> Void

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
                Picker("Show on", selection: $settings.screen) {
                    ForEach(ScreenPreference.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: settings.screen) { _, _ in onScreenChange() }
                Picker("Motion", selection: $settings.motion) {
                    ForEach(MotionPreference.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("When Claude needs you") {
                Toggle("Expand the notch automatically", isOn: $settings.autoExpandOnQuestion)
                Toggle("Play a sound", isOn: $settings.attentionSound)
            }
            Section("When Claude finishes") {
                Toggle("Celebration animation", isOn: $settings.completionAnimation)
                Toggle("Completion sound", isOn: $settings.completionSound)
                Picker("Intensity", selection: $settings.intensity) {
                    ForEach(CelebrationIntensity.allCases) { Text($0.label).tag($0) }
                }
                Text("Quick replies (under 15 seconds) finish quietly.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Sessions") {
                Toggle("Show finished sessions", isOn: $settings.showCompletedSessions)
            }
            Section("Claude Code") {
                LabeledContent("Status", value: model.connection.label)
                Toggle("Read plan usage via status line", isOn: $settings.readPlanUsage)
                    .onChange(of: settings.readPlanUsage) { _, _ in if model.connection != .notConnected { onConnect() } }
                HStack {
                    Button(model.connection == .connected ? "Reconnect" : "Connect", action: onConnect)
                    if model.connection == .connected || model.connection == .needsUpdate {
                        Button("Disconnect", role: .destructive, action: onDisconnect)
                    }
                }
            }
            Section("Privacy") {
                Toggle("Diagnostic logging (local only)", isOn: $settings.diagnosticLogging)
                    .onChange(of: settings.diagnosticLogging) { _, v in Log.enabled = v }
                Text("Claude Notch has no account, no server and no analytics. Everything stays on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 560)
    }
}
