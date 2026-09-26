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
    static func syncHelper() throws {
        guard let src = bundledHookURL else { throw HookInstaller.InstallError.missingHookBinary("app bundle") }
        try BridgePaths.ensureSupportDirectory()
        let bin = BridgePaths.supportDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let dest = URL(fileURLWithPath: installedHookPath)
        if FileManager.default.contentsEqual(atPath: src.path, andPath: dest.path) { return }
        let tmp = bin.appendingPathComponent("notch-hook.tmp-\(getpid())")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.copyItem(at: src, to: tmp)
        if rename(tmp.path, dest.path) != 0 { throw CocoaError(.fileWriteUnknown) }
    }

    static func connect(includeStatusLine: Bool) throws {
        try syncHelper()
        try installer.install(includeStatusLine: includeStatusLine)
    }

    static func disconnect() throws {
        try installer.uninstall()
    }

    static func status(includeStatusLine: Bool) -> ConnectionStatus {
        switch installer.status(includeStatusLine: includeStatusLine) {
        case .installed: return .connected
        case .notInstalled: return .notConnected
        case .outdated: return .needsUpdate
        case .unreadable(let why): return .error(why)
        }
    }
}
