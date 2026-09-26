import Foundation

/// Adds / removes Claude Notch's hooks in Claude Code's user settings (~/.claude/settings.json).
///
/// Rules: never touch entries we didn't create (ours are identified by the `notch-hook`
/// binary name), back the file up once before the first edit, refuse to edit a file we
/// can't parse, and keep any existing status line working by chaining to it.
public struct HookInstaller {
    public enum Status: Equatable {
        case notInstalled
        case installed
        case outdated          // some of our hooks are missing or stale; re-run install
        case unreadable(String)
    }

    public enum InstallError: Error, LocalizedError {
        case unreadableSettings(String)
        case missingHookBinary(String)

        public var errorDescription: String? {
            switch self {
            case .unreadableSettings(let why):
                return "Couldn't read ~/.claude/settings.json (\(why)). Fix or remove it, then try again."
            case .missingHookBinary(let p):
                return "The Claude Notch helper is missing at \(p)."
            }
        }
    }

    public static let marker = "notch-hook"

    public var settingsURL: URL
    public var hookBinaryPath: String
    /// Our own config file; stores the user's previous status line so we can chain to it.
    public var configURL: URL

    public init(settingsURL: URL = HookInstaller.defaultSettingsURL, hookBinaryPath: String, configURL: URL) {
        self.settingsURL = settingsURL
        self.hookBinaryPath = hookBinaryPath
        self.configURL = configURL
    }

    public static var defaultSettingsURL: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent("settings.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    // MARK: Desired configuration

    func command(_ args: String) -> String {
        "'" + hookBinaryPath.replacingOccurrences(of: "'", with: "'\\''") + "' " + args
    }

    private func cmd(_ args: String, timeout: Int? = nil, async: Bool = false) -> [String: Any] {
        var h: [String: Any] = ["type": "command", "command": command(args)]
        if let timeout { h["timeout"] = timeout }
        if async { h["async"] = true }
        return h
    }

    private func group(_ matcher: String?, _ hooks: [String: Any]...) -> [String: Any] {
        var g: [String: Any] = ["hooks": hooks]
        if let matcher { g["matcher"] = matcher }
        return g
    }

    /// Lifecycle hooks are synchronous (a few ms, keeps event order); tool heartbeats are
    /// async so they never slow Claude down. The AskUserQuestion hook blocks while the
    /// notch waits for an answer, and falls back to the terminal on its own timeout.
    public func desiredHooks(questionTimeout: Int = 180) -> [String: [[String: Any]]] {
        [
            "SessionStart": [group(nil, cmd("event", timeout: 5))],
            "UserPromptSubmit": [group(nil, cmd("event", timeout: 5))],
            "PreToolUse": [
                group("AskUserQuestion", cmd("event --question", timeout: questionTimeout)),
                group("*", cmd("event", async: true)),
            ],
            "PostToolUse": [group("*", cmd("event", async: true))],
            "PostToolUseFailure": [group("*", cmd("event", async: true))],
            "PermissionRequest": [group("*", cmd("event", timeout: 5))],
            "Notification": [group("elicitation_dialog|idle_prompt", cmd("event", async: true))],
            "Stop": [group(nil, cmd("event", timeout: 5))],
            "StopFailure": [group(nil, cmd("event", timeout: 5))],
            "SessionEnd": [group(nil, cmd("event", timeout: 2))],
        ]
    }

    // MARK: Status

    public func status(includeStatusLine: Bool) -> Status {
        let settings: [String: Any]
        switch readSettings() {
        case .failure(let e): return .unreadable(e.localizedDescription)
        case .success(let s): settings = s
        }
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let ours = ourCommands(in: hooks)
        if ours.isEmpty { return .notInstalled }
        let wanted = ourCommands(in: desiredHooks())
        guard ours == wanted, FileManager.default.isExecutableFile(atPath: hookBinaryPath) else { return .outdated }
        if includeStatusLine && !statusLineIsOurs(settings) { return .outdated }
        return .installed
    }

    /// event name → sorted list of "matcher|command" for our entries only.
    func ourCommands(in hooks: [String: Any]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for (event, value) in hooks {
            for g in value as? [[String: Any]] ?? [] {
                let matcher = g["matcher"] as? String ?? ""
                for h in g["hooks"] as? [[String: Any]] ?? [] {
                    if let c = h["command"] as? String, c.contains(Self.marker) {
                        out[event, default: []].append("\(matcher)|\(c)")
                    }
                }
            }
        }
        return out.mapValues { $0.sorted() }
    }

    func statusLineIsOurs(_ settings: [String: Any]) -> Bool {
        ((settings["statusLine"] as? [String: Any])?["command"] as? String)?.contains(Self.marker) == true
    }

    // MARK: Install / uninstall

    public func install(includeStatusLine: Bool) throws {
        guard FileManager.default.isExecutableFile(atPath: hookBinaryPath) else {
            throw InstallError.missingHookBinary(hookBinaryPath)
        }
        var settings: [String: Any]
        switch readSettings() {
        case .failure(let e): throw e
        case .success(let s): settings = s
        }
        try backupOnce()

        var hooks = removingOurs(from: settings["hooks"] as? [String: Any] ?? [:])
        for (event, groups) in desiredHooks() {
            var existing = hooks[event] as? [[String: Any]] ?? []
            existing.append(contentsOf: groups)
            hooks[event] = existing
        }
        settings["hooks"] = hooks

        var config = readConfig()
        if includeStatusLine {
            if let current = settings["statusLine"] as? [String: Any], !statusLineIsOurs(settings) {
                config["chainedStatusLine"] = current
            }
            settings["statusLine"] = ["type": "command", "command": command("statusline"), "padding": 0] as [String: Any]
        } else if statusLineIsOurs(settings) {
            restoreStatusLine(&settings, config: &config)
        }
        try writeConfig(config)
        try writeSettings(settings)
    }

    public func uninstall() throws {
        var settings: [String: Any]
        switch readSettings() {
        case .failure(let e): throw e
        case .success(let s): settings = s
        }
        let hooks = removingOurs(from: settings["hooks"] as? [String: Any] ?? [:])
        if hooks.isEmpty { settings["hooks"] = nil } else { settings["hooks"] = hooks }
        var config = readConfig()
        if statusLineIsOurs(settings) { restoreStatusLine(&settings, config: &config) }
        try writeConfig(config)
        try writeSettings(settings)
    }

    private func restoreStatusLine(_ settings: inout [String: Any], config: inout [String: Any]) {
        settings["statusLine"] = config["chainedStatusLine"]
        config["chainedStatusLine"] = nil
    }

    func removingOurs(from hooks: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { out[event] = value; continue }
            let kept: [[String: Any]] = groups.compactMap { g in
                guard let hs = g["hooks"] as? [[String: Any]] else { return g }
                let remaining = hs.filter { !(($0["command"] as? String)?.contains(Self.marker) ?? false) }
                if remaining.isEmpty { return nil }
                var g2 = g
                g2["hooks"] = remaining
                return g2
            }
            if !kept.isEmpty { out[event] = kept }
        }
        return out
    }

    // MARK: Files

    func readSettings() -> Result<[String: Any], InstallError> {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return .success([:]) }
        guard let data = try? Data(contentsOf: settingsURL) else { return .failure(.unreadableSettings("can't open file")) }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x09 || $0 == 0x0D }) { return .success([:]) }
        guard let obj = try? JSONSerialization.jsonObject(with: data), let dict = obj as? [String: Any] else {
            return .failure(.unreadableSettings("not valid JSON"))
        }
        return .success(dict)
    }

    func writeSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    func backupOnce() throws {
        let backup = settingsURL.appendingPathExtension("claude-notch-backup")
        let fm = FileManager.default
        if fm.fileExists(atPath: settingsURL.path), !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: settingsURL, to: backup)
        }
    }

    public func readConfig() -> [String: Any] {
        guard let data = try? Data(contentsOf: configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    func writeConfig(_ config: [String: Any]) throws {
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configURL, options: .atomic)
    }
}
