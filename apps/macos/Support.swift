import AppKit
import NotchCore
import NotchBridge
import ClaudeCodeAdapter

/// Subtle system sounds only — no bundled audio to license.
@MainActor
final class SoundPlayer {
    func completion(intensity: CelebrationIntensity) {
        let name: NSSound.Name = intensity == .celebratory ? "Hero" : (intensity == .subtle ? "Tink" : "Glass")
        play(name, volume: intensity == .subtle ? 0.35 : 0.55)
    }

    func attention() { play("Pop", volume: 0.5) }

    private func play(_ name: NSSound.Name, volume: Float) {
        guard let s = NSSound(named: name)?.copy() as? NSSound else { return }
        s.volume = volume
        s.play()
    }
}

/// Brings the app that hosts a Claude Code session (Terminal, iTerm, VS Code, Claude) to the front.
enum HostActivator {
    @MainActor
    static func activate(session: Session) {
        guard let pid = session.claudePid else { return }
        for p in [pid] + ProcessTree.ancestors(of: pid) {
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular {
                app.activate()
                return
            }
        }
    }

    @MainActor
    static func hostAppName(session: Session) -> String {
        guard let pid = session.claudePid else { return session.host.displayName }
        for p in ProcessTree.ancestors(of: pid) {
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular,
               let name = app.localizedName {
                return name
            }
        }
        return session.host.displayName
    }
}

/// Saves session state so a relaunch can show what's still running (PRD §39).
/// Restored sessions are marked so they never trigger celebrations.
enum StatePersistence {
    static var url: URL { BridgePaths.supportDirectory.appendingPathComponent("state.json") }

    static func load() -> AppState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? BridgeCoding.decoder().decode(AppState.self, from: data)
    }

    static func save(_ state: AppState) {
        guard let data = try? BridgeCoding.encoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Wires the hook helper into Claude Code.
enum Integration {
    static var installedHookPath: String {
        BridgePaths.supportDirectory.appendingPathComponent("bin/notch-hook").path
    }

    static var installer: HookInstaller {
        HookInstaller(hookBinaryPath: installedHookPath,
                      configURL: BridgePaths.supportDirectory.appendingPathComponent("config.json"))
    }

    /// The helper shipped inside the app bundle (or next to the binary during development).
    static var bundledHookURL: URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/notch-hook"),
            URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
                .deletingLastPathComponent().appendingPathComponent("notch-hook"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var claudeCodeDetected: Bool {
        FileManager.default.fileExists(atPath: HookInstaller.defaultSettingsURL.deletingLastPathComponent().path)
    }

    /// Copies the bundled helper to a stable path (atomically, so a running hook is never torn).
    ///
    /// A browser-downloaded app carries `com.apple.quarantine`, and copies keep it. Approving
    /// the app in Privacy & Security doesn't cover a standalone copy, so Gatekeeper would
    /// SIGKILL the helper every time Claude Code runs a hook. Always clear it on our copy.
    @discardableResult
    static func syncHelper() throws -> URL {
        guard let src = bundledHookURL else { throw HookInstaller.InstallError.missingHookBinary("app bundle") }
        try BridgePaths.ensureSupportDirectory()
        let bin = BridgePaths.supportDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let dest = URL(fileURLWithPath: installedHookPath)
        if !FileManager.default.contentsEqual(atPath: src.path, andPath: dest.path) {
            let tmp = bin.appendingPathComponent("notch-hook.tmp-\(getpid())")
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.copyItem(at: src, to: tmp)
            removexattr(tmp.path, "com.apple.quarantine", 0)
            if rename(tmp.path, dest.path) != 0 { throw CocoaError(.fileWriteUnknown) }
        }
        removexattr(dest.path, "com.apple.quarantine", 0)
        return dest
    }

    /// True when the installed helper actually runs, i.e. macOS isn't blocking it.
    static func helperRuns() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: installedHookPath)
        p.arguments = ["status"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return false }
        return p.terminationReason == .exit && p.terminationStatus == 0
    }

    static let blockedMessage = "macOS blocked the Claude Notch helper. Move Claude Notch to Applications, open it, and click Connect again."

    static func connect(includeStatusLine: Bool) throws {
        try syncHelper()
        guard helperRuns() else { throw ConnectError.helperBlocked }
        try installer.install(includeStatusLine: includeStatusLine)
    }

    enum ConnectError: Error, LocalizedError {
        case helperBlocked
        var errorDescription: String? { Integration.blockedMessage }
    }

    static func disconnect() throws {
        try installer.uninstall()
    }

    static func status(includeStatusLine: Bool) -> ConnectionStatus {
        switch installer.status(includeStatusLine: includeStatusLine) {
        case .installed: return helperQuarantined ? .needsUpdate : .connected
        case .notInstalled: return .notConnected
        case .outdated: return .needsUpdate
        case .unreadable(let why): return .error(why)
        }
    }

    static var helperQuarantined: Bool {
        getxattr(installedHookPath, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }
}
