import Foundation
import Testing
@testable import ClaudeCodeAdapter
@testable import NotchCore

private let cli = ClaudeCodeAdapter.HookContext(env: ["CLAUDE_CODE_ENTRYPOINT": "cli"])
private let desktop = ClaudeCodeAdapter.HookContext(env: ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop"])

private func hook(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
    var h: [String: Any] = ["session_id": "5f1c-aa", "hook_event_name": name, "cwd": "/tmp/nowhere/my-app"]
    h.merge(extra) { $1 }
    return h
}

private let askInput: [String: Any] = [
    "questions": [[
        "question": "Which database should I use?",
        "header": "Database",
        "multiSelect": false,
        "options": [
            ["label": "PostgreSQL", "description": "Robust"],
            ["label": "SQLite", "description": "Simple"],
        ],
    ]],
]

@Suite struct HookNormalization {
    @Test func lifecycle() {
        #expect(ClaudeCodeAdapter.normalize(hook: hook("SessionStart"), context: cli)?.event.type == .sessionStarted)
        let prompt = ClaudeCodeAdapter.normalize(hook: hook("UserPromptSubmit", ["prompt_text": "secret stuff"]), context: cli)?.event
        #expect(prompt?.type == .sessionWorking)
        #expect(prompt?.reason == .prompt)
        #expect(prompt?.projectName == "my-app")
        #expect(prompt?.host == .cli)
        #expect(ClaudeCodeAdapter.normalize(hook: hook("Stop"), context: cli)?.event.type == .sessionCompleted)
        #expect(ClaudeCodeAdapter.normalize(hook: hook("StopFailure"), context: cli)?.event.failed == true)
        #expect(ClaudeCodeAdapter.normalize(hook: hook("SessionEnd"), context: cli)?.event.type == .sessionEnded)
    }

    @Test func askUserQuestionInCLIWaitsForAnswer() throws {
        var ctx = cli
        ctx.synchronousQuestionHook = true
        let r = try #require(ClaudeCodeAdapter.normalize(
            hook: hook("PreToolUse", ["tool_name": "AskUserQuestion", "tool_input": askInput, "tool_use_id": "toolu_1"]),
            context: ctx))
        #expect(r.waitForAnswer)
        #expect(r.event.type == .sessionNeedsInput)
        #expect(r.event.question?.id == "toolu_1")
        #expect(r.event.question?.answerable == true)
        #expect(r.event.question?.items.first?.options.map(\.label) == ["PostgreSQL", "SQLite"])
    }

    @Test func askUserQuestionInDesktopAppOnlyNotifies() throws {
        var ctx = desktop
        ctx.synchronousQuestionHook = true
        let r = try #require(ClaudeCodeAdapter.normalize(
            hook: hook("PreToolUse", ["tool_name": "AskUserQuestion", "tool_input": askInput, "tool_use_id": "toolu_1"]),
            context: ctx))
        #expect(!r.waitForAnswer)
        #expect(r.event.question?.answerable == false)
    }

    @Test func asyncCatchAllIgnoresAskUserQuestion() {
        #expect(ClaudeCodeAdapter.normalize(
            hook: hook("PreToolUse", ["tool_name": "AskUserQuestion", "tool_input": askInput]), context: cli) == nil)
    }

    @Test func postToolUseOfQuestionResolvesIt() {
        let e = ClaudeCodeAdapter.normalize(
            hook: hook("PostToolUse", ["tool_name": "AskUserQuestion", "tool_use_id": "toolu_1"]), context: cli)?.event
        #expect(e?.type == .sessionInputResolved)
        #expect(e?.questionId == "toolu_1")
    }

    @Test func toolActivityIsDescribedWithoutRawCommands() {
        let e = ClaudeCodeAdapter.normalize(hook: hook("PreToolUse", [
            "tool_name": "Bash", "tool_input": ["command": "export TOKEN=abc && npm test", "description": "Run tests"],
        ]), context: cli)?.event
        #expect(e?.activity == "Run tests")
        let noDesc = ClaudeCodeAdapter.describeTool("Bash", ["command": "TOKEN=abc API_KEY=zzz npm test"], finished: false)
        #expect(noDesc == "Running npm")
        #expect(!(noDesc ?? "").contains("abc"))
        #expect(ClaudeCodeAdapter.describeTool("Edit", ["file_path": "/a/b/App.swift"], finished: false) == "Editing App.swift")
    }

    @Test func permissionRequestIsNotAnswerable() {
        let e = ClaudeCodeAdapter.normalize(hook: hook("PermissionRequest", [
            "tool_name": "Bash", "tool_input": ["command": "rm -rf build", "description": "Clean build"], "tool_use_id": "t9",
        ]), context: cli)?.event
        #expect(e?.type == .sessionNeedsInput)
        #expect(e?.question?.kind == .permission)
        #expect(e?.question?.answerable == false)
        #expect(ClaudeCodeAdapter.normalize(hook: hook("PermissionRequest", ["tool_name": "AskUserQuestion"]), context: cli) == nil)
    }

    @Test func malformedInputIsIgnored() {
        #expect(ClaudeCodeAdapter.normalize(hook: [:], context: cli) == nil)
        #expect(ClaudeCodeAdapter.normalize(hook: ["session_id": "a b/c", "hook_event_name": "Stop"], context: cli) == nil)
        #expect(ClaudeCodeAdapter.normalize(hook: hook("SomethingNew"), context: cli) == nil)
        #expect(ClaudeCodeAdapter.normalize(hook: hook("Notification", ["notification_type": "auth_success"]), context: cli) == nil)
        #expect(ClaudeCodeAdapter.normalize(hook: hook("Notification", ["notification_type": "idle_prompt"]), context: cli)?.event.type == .sessionIdle)
    }

    @Test func hostDetection() {
        #expect(ClaudeCodeAdapter.host(from: ["CLAUDE_CODE_ENTRYPOINT": "cli"]) == .cli)
        #expect(ClaudeCodeAdapter.host(from: ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop"]) == .desktop)
        #expect(ClaudeCodeAdapter.host(from: ["CLAUDE_CODE_ENTRYPOINT": "claude-vscode"]) == .ide)
        #expect(ClaudeCodeAdapter.host(from: ["CLAUDE_CODE_ENTRYPOINT": "sdk-ts"]) == .sdk)
        #expect(ClaudeCodeAdapter.host(from: [:]) == .unknown)
    }

    @Test func answerOutputMatchesAgentSDKContract() throws {
        let out = ClaudeCodeAdapter.answerOutput(originalToolInput: askInput, answers: ["Which database should I use?": "SQLite"])
        let hso = try #require(out["hookSpecificOutput"] as? [String: Any])
        #expect(hso["hookEventName"] as? String == "PreToolUse")
        #expect(hso["permissionDecision"] as? String == "allow")
        let updated = try #require(hso["updatedInput"] as? [String: Any])
        #expect((updated["questions"] as? [[String: Any]])?.count == 1)
        #expect((updated["answers"] as? [String: String])?["Which database should I use?"] == "SQLite")
    }
}

@Suite struct DenyFallback {
    @Test func carriesTheAnswerInTheReason() throws {
        let out = ClaudeCodeAdapter.answerViaDenyOutput(answers: ["Which database should I use?": "SQLite"])
        let hso = try #require(out["hookSpecificOutput"] as? [String: Any])
        #expect(hso["permissionDecision"] as? String == "deny")
        #expect((hso["permissionDecisionReason"] as? String)?.contains("\"Which database should I use?\" → SQLite") == true)
    }
}

@Suite struct StatusLineUsage {
    @Test func parsesVerifiedUsage() throws {
        let input: [String: Any] = [
            "session_id": "abc",
            "workspace": ["current_dir": "/tmp/x/my-app"],
            "context_window": ["used_percentage": 61, "context_window_size": 200_000],
            "rate_limits": [
                "five_hour": ["used_percentage": 23.5, "resets_at": 1_738_425_600],
                "seven_day": ["used_percentage": 41.2, "resets_at": 1_738_857_600],
            ],
        ]
        let e = try #require(ClaudeCodeAdapter.normalize(statusLine: input, context: cli))
        #expect(e.type == .usageUpdated)
        #expect(e.usage?.context == PercentMetric(usedPercent: 61, source: .verified))
        #expect(e.usage?.fiveHour?.usedPercent == 23.5)
        #expect(e.usage?.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_738_425_600))
        #expect(e.usage?.sevenDay?.usedPercent == 41.2)
    }

    @Test func missingRateLimitsStayMissing() throws {
        let e = try #require(ClaudeCodeAdapter.normalize(statusLine: [
            "session_id": "abc", "context_window": ["used_percentage": 8],
        ], context: cli))
        #expect(e.usage?.fiveHour == nil)
        #expect(e.usage?.sevenDay == nil)
        #expect(ClaudeCodeAdapter.normalize(statusLine: ["session_id": "abc"], context: cli) == nil)
    }

    @Test func estimatesContextFromTranscript() throws {
        let tail = """
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":1000,"cache_creation_input_tokens":9000,"cache_read_input_tokens":40000,"output_tokens":500}}}
        """
        let m = try #require(ClaudeCodeAdapter.estimateContext(transcriptTail: tail))
        #expect(m.source == .estimated)
        #expect(m.usedPercent == 25)
    }

    @Test func compactionHistoryMeansLargeWindow() throws {
        let tail = """
        {"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_read_input_tokens":189990}}}
        """
        let m = try #require(ClaudeCodeAdapter.estimateContext(transcriptTail: tail, knownLargeWindow: true))
        #expect(m.usedPercent == 19)
        #expect(m.windowTokens == 1_000_000)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cn-tx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let big = dir.appendingPathComponent("big.jsonl"), small = dir.appendingPathComponent("small.jsonl")
        // Pad so the marker straddles the 1 MB read boundary.
        let pad = String(repeating: "x", count: (1 << 20) - 20)
        try (pad + #"{"compactMetadata":{"trigger":"auto","preTokens":593013}}"# + "\n").write(to: big, atomically: true, encoding: .utf8)
        try (#"{"compactMetadata":{"trigger":"auto","preTokens":180000}}"# + "\n").write(to: small, atomically: true, encoding: .utf8)
        #expect(ClaudeCodeAdapter.transcriptShowsLargeWindow(path: big.path))
        #expect(!ClaudeCodeAdapter.transcriptShowsLargeWindow(path: small.path))
        #expect(!ClaudeCodeAdapter.transcriptShowsLargeWindow(path: dir.appendingPathComponent("missing").path))
    }
}

@Suite struct Installer {
    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cn-inst-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func fakeBinary(in dir: URL) -> String {
        let p = dir.appendingPathComponent("notch-hook").path
        FileManager.default.createFile(atPath: p, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        return p
    }

    @Test func installPreservesUserHooksAndIsIdempotent() throws {
        let dir = tempDir()
        let settings = dir.appendingPathComponent("settings.json")
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]],
            "statusLine": ["type": "command", "command": "~/my-status.sh"],
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: settings)
        let inst = HookInstaller(settingsURL: settings, hookBinaryPath: fakeBinary(in: dir), configURL: dir.appendingPathComponent("config.json"))

        #expect(inst.status(includeStatusLine: true) == .notInstalled)
        try inst.install(includeStatusLine: true)
        try inst.install(includeStatusLine: true) // twice: no duplicates
        #expect(inst.status(includeStatusLine: true) == .installed)

        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        #expect(after["model"] as? String == "opus")
        let stop = (after["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        #expect(stop.count == 2) // user's + ours
        #expect(((stop[0]["hooks"] as! [[String: Any]])[0]["command"] as? String) == "say done")
        #expect(((after["statusLine"] as? [String: Any])?["command"] as? String)?.hasSuffix("notch-hook' statusline") == true)
        #expect((inst.readConfig()["chainedStatusLine"] as? [String: Any])?["command"] as? String == "~/my-status.sh")
        #expect(FileManager.default.fileExists(atPath: settings.appendingPathExtension("claude-notch-backup").path))

        try inst.uninstall()
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        #expect(((restored["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]).count == 1)
        #expect((restored["hooks"] as! [String: Any])["PreToolUse"] == nil)
        #expect((restored["statusLine"] as? [String: Any])?["command"] as? String == "~/my-status.sh")
    }

    @Test func refusesToEditInvalidSettings() throws {
        let dir = tempDir()
        let settings = dir.appendingPathComponent("settings.json")
        try Data("{ // comment\n }".utf8).write(to: settings)
        let inst = HookInstaller(settingsURL: settings, hookBinaryPath: fakeBinary(in: dir), configURL: dir.appendingPathComponent("config.json"))
        #expect(throws: (any Error).self) { try inst.install(includeStatusLine: false) }
        #expect(try String(contentsOf: settings, encoding: .utf8) == "{ // comment\n }")
    }

    @Test func questionHookBlocksAndHeartbeatsAreAsync() {
        let inst = HookInstaller(settingsURL: URL(fileURLWithPath: "/dev/null"), hookBinaryPath: "/x/notch-hook", configURL: URL(fileURLWithPath: "/dev/null"))
        let pre = inst.desiredHooks()["PreToolUse"]!
        let ask = pre.first { $0["matcher"] as? String == "AskUserQuestion" }!
        let askHook = (ask["hooks"] as! [[String: Any]])[0]
        #expect(askHook["async"] == nil)
        #expect((askHook["command"] as? String) == "'/x/notch-hook' event --question")
        let post = (inst.desiredHooks()["PostToolUse"]![0]["hooks"] as! [[String: Any]])[0]
        #expect(post["async"] as? Bool == true)
    }
}
