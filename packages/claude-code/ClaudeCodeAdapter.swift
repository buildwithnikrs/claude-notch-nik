import Foundation
import NotchCore

/// Translates Claude Code hook / status line payloads into `NormalizedEvent`s.
///
/// This is the only place that knows Claude Code's JSON shapes. When Claude Code changes,
/// this file changes; the core and UI do not (PRD §29).
public enum ClaudeCodeAdapter {
    public typealias JSON = [String: Any]

    public struct HookContext {
        public var env: [String: String]
        public var now: Date
        public var claudePid: Int32?
        /// Whether this invocation is the blocking PreToolUse(AskUserQuestion) hook.
        public var synchronousQuestionHook: Bool

        public init(env: [String: String], now: Date = Date(), claudePid: Int32? = nil, synchronousQuestionHook: Bool = false) {
            self.env = env
            self.now = now
            self.claudePid = claudePid
            self.synchronousQuestionHook = synchronousQuestionHook
        }
    }

    public struct Result {
        public var event: NormalizedEvent
        /// True when the hook should hold the connection open and wait for the user's answer.
        public var waitForAnswer: Bool
    }

    // MARK: Hooks

    public static func normalize(hook input: JSON, context ctx: HookContext) -> Result? {
        guard let sessionId = input["session_id"] as? String,
              NormalizedEvent.isValidSessionId(sessionId),
              let name = input["hook_event_name"] as? String else { return nil }

        let cwd = input["cwd"] as? String
        let host = host(from: ctx.env)
        func base(_ kind: NormalizedEvent.Kind) -> NormalizedEvent {
            NormalizedEvent(
                type: kind, sessionId: sessionId, timestamp: ctx.now,
                projectName: cwd.map(projectDisplayName(for:)), workingDirectory: cwd,
                host: host, claudePid: ctx.claudePid
            )
        }
        let toolName = input["tool_name"] as? String
        let toolInput = input["tool_input"] as? JSON ?? [:]
        let toolUseId = input["tool_use_id"] as? String

        switch name {
        case "SessionStart":
            return Result(event: base(.sessionStarted), waitForAnswer: false)

        case "UserPromptSubmit":
            var e = base(.sessionWorking)
            e.reason = .prompt
            return Result(event: e, waitForAnswer: false)

        case "PreToolUse":
            if toolName == "AskUserQuestion" {
                // The async catch-all PreToolUse hook also sees this call; only the
                // dedicated synchronous hook reports the question.
                guard ctx.synchronousQuestionHook else { return nil }
                guard let items = parseQuestions(toolInput), !items.isEmpty else { return nil }
                // Only the terminal CLI lets a hook answer cleanly. In the desktop app and
                // IDEs the host shows its own question UI, so we notify and step aside.
                let answerable = host == .cli
                var e = base(.sessionNeedsInput)
                e.question = QuestionPayload(
                    id: toolUseId ?? "ask-\(sessionId)-\(Int(ctx.now.timeIntervalSince1970 * 1000))",
                    kind: .question, items: items, answerable: answerable
                )
                return Result(event: e, waitForAnswer: answerable)
            }
            var e = base(.sessionWorking)
            e.reason = .tool
            e.activity = describeTool(toolName, toolInput, finished: false)
            return Result(event: e, waitForAnswer: false)

        case "PostToolUse", "PostToolUseFailure":
            if toolName == "AskUserQuestion" {
                // Answered (from the notch or the host) — the question is gone.
                var e = base(.sessionInputResolved)
                e.questionId = toolUseId
                return Result(event: e, waitForAnswer: false)
            }
            var e = base(.sessionWorking)
            e.reason = .tool
            return Result(event: e, waitForAnswer: false)

        case "PermissionRequest":
            // AskUserQuestion's own dialog is reported by the PreToolUse hook instead.
            guard let toolName, toolName != "AskUserQuestion" else { return nil }
            var e = base(.sessionNeedsInput)
            let text = toolName == "ExitPlanMode"
                ? "Claude has a plan ready for review"
                : "Allow \(friendlyToolName(toolName))?"
            let detail = toolName == "ExitPlanMode" ? nil : describeTool(toolName, toolInput, finished: false)
            e.question = QuestionPayload(
                id: toolUseId ?? "perm-\(sessionId)-\(Int(ctx.now.timeIntervalSince1970 * 1000))",
                kind: .permission,
                items: [QuestionItem(text: text, header: detail)],
                answerable: false
            )
            return Result(event: e, waitForAnswer: false)

        case "Notification":
            let type = input["notification_type"] as? String
            if type == "idle_prompt" {
                return Result(event: base(.sessionIdle), waitForAnswer: false)
            }
            guard type == "elicitation_dialog" else { return nil }
            var e = base(.sessionNeedsInput)
            let message = (input["message"] as? String) ?? "An MCP server is asking for input."
            e.question = QuestionPayload(
                id: "elicit-\(sessionId)-\(Int(ctx.now.timeIntervalSince1970 * 1000))",
                kind: .elicitation, items: [QuestionItem(text: message)], answerable: false
            )
            return Result(event: e, waitForAnswer: false)

        case "Stop":
            return Result(event: base(.sessionCompleted), waitForAnswer: false)

        case "StopFailure":
            var e = base(.sessionCompleted)
            e.failed = true
            return Result(event: e, waitForAnswer: false)

        case "SessionEnd":
            return Result(event: base(.sessionEnded), waitForAnswer: false)

        default:
            return nil
        }
    }

    public static func host(from env: [String: String]) -> SessionHost {
        let entry = (env["CLAUDE_CODE_ENTRYPOINT"] ?? "").lowercased()
        switch entry {
        case "cli": return .cli
        case "claude-desktop": return .desktop
        case "": return .unknown
        default:
            if entry.contains("vscode") || entry.contains("jetbrains") || entry.contains("ide") { return .ide }
            if entry.hasPrefix("sdk") { return .sdk }
            if entry.contains("desktop") { return .desktop }
            return .unknown
        }
    }

    static func parseQuestions(_ input: JSON) -> [QuestionItem]? {
        guard let qs = input["questions"] as? [JSON] else { return nil }
        return qs.compactMap { q in
            guard let text = q["question"] as? String, !text.isEmpty else { return nil }
            let options = (q["options"] as? [JSON] ?? []).compactMap { o -> QuestionOption? in
                guard let label = o["label"] as? String, !label.isEmpty else { return nil }
                return QuestionOption(label: label, description: o["description"] as? String)
            }
            return QuestionItem(text: text, header: q["header"] as? String, options: options,
                                multiSelect: q["multiSelect"] as? Bool ?? false)
        }
    }

    /// The PreToolUse hook output that answers an AskUserQuestion call.
    /// Mirrors the Agent SDK contract: pass the questions through, add `answers` keyed by question text.
    public static func answerOutput(originalToolInput: JSON, answers: [String: String]) -> JSON {
        var updated = originalToolInput
        updated["answers"] = answers
        return [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "permissionDecisionReason": "Answered from Claude Notch",
                "updatedInput": updated,
            ] as JSON,
        ]
    }

    /// Fallback answer path: deny the tool call and hand Claude the answer as the reason.
    /// Used if a Claude Code version ignores `updatedInput.answers` from hooks
    /// (config.json: `"answerMode": "deny"`).
    public static func answerViaDenyOutput(answers: [String: String]) -> JSON {
        let text = answers.sorted { $0.key < $1.key }
            .map { "\"\($0.key)\" → \($0.value)" }
            .joined(separator: "; ")
        return [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": "The user already answered from Claude Notch: \(text). Continue with these answers; don't ask again.",
            ] as JSON,
        ]
    }

    // MARK: Activity descriptions

    /// A short, safe description of what Claude is doing. Never includes file contents,
    /// and uses the tool's own description for shell commands rather than the raw command
    /// (which could contain secrets).
    public static func describeTool(_ name: String?, _ input: JSON, finished: Bool) -> String? {
        guard let name else { return nil }
        func file(_ key: String) -> String? {
            (input[key] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        }
        switch name {
        case "Bash":
            if let d = input["description"] as? String, !d.isEmpty { return d }
            // First word that isn't an env assignment (which could carry a secret).
            if let c = input["command"] as? String,
               let first = c.split(whereSeparator: { $0 == " " || $0 == "\n" }).first(where: { !$0.contains("=") }) {
                return "Running \(URL(fileURLWithPath: String(first)).lastPathComponent.prefix(40))"
            }
            return "Running a command"
        case "Edit", "MultiEdit": return file("file_path").map { "Editing \($0)" } ?? "Editing"
        case "Write": return file("file_path").map { "Writing \($0)" } ?? "Writing"
        case "Read": return file("file_path").map { "Reading \($0)" } ?? "Reading"
        case "NotebookEdit": return file("notebook_path").map { "Editing \($0)" } ?? "Editing notebook"
        case "Grep", "Glob": return "Searching the code"
        case "WebFetch":
            if let u = input["url"] as? String, let h = URL(string: u)?.host { return "Reading \(h)" }
            return "Reading the web"
        case "WebSearch": return "Searching the web"
        case "Task", "Agent": return "Delegating to a subagent"
        case "TodoWrite", "TaskCreate", "TaskUpdate": return "Planning"
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.split(separator: "_", omittingEmptySubsequences: true)
                if parts.count >= 2 { return "Using \(parts[1])" }
            }
            return "Using \(name)"
        }
    }

    static func friendlyToolName(_ name: String) -> String {
        switch name {
        case "Bash": return "running a command"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "editing a file"
        case "WebFetch": return "fetching a web page"
        default: return name.hasPrefix("mcp__") ? "an MCP tool" : name
        }
    }

    // MARK: Status line (verified usage)

    /// Parses the JSON Claude Code passes to status line commands. Every value here is
    /// reported by Claude Code itself, so it is `verified`.
    public static func normalize(statusLine input: JSON, context ctx: HookContext) -> NormalizedEvent? {
        guard let sessionId = input["session_id"] as? String, NormalizedEvent.isValidSessionId(sessionId) else { return nil }
        let cwd = (input["workspace"] as? JSON)?["current_dir"] as? String ?? input["cwd"] as? String

        var usage = UsageSnapshot(capturedAt: ctx.now)
        if let cw = input["context_window"] as? JSON, let pct = number(cw["used_percentage"]) {
            usage.context = PercentMetric(usedPercent: pct, source: .verified)
        }
        if let rl = input["rate_limits"] as? JSON {
            usage.fiveHour = window(rl["five_hour"])
            usage.sevenDay = window(rl["seven_day"])
        }
        guard usage.context != nil || usage.hasRateLimits else { return nil }
        return NormalizedEvent(
            type: .usageUpdated, sessionId: sessionId, timestamp: ctx.now,
            projectName: cwd.map(projectDisplayName(for:)), workingDirectory: cwd,
            host: host(from: ctx.env), claudePid: ctx.claudePid, usage: usage
        )
    }

    static func window(_ any: Any?) -> RateWindow? {
        guard let w = any as? JSON, let pct = number(w["used_percentage"]) else { return nil }
        let reset = number(w["resets_at"]).map { Date(timeIntervalSince1970: $0) }
        return RateWindow(usedPercent: pct, resetsAt: reset)
    }

    static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    // MARK: Estimated context (fallback when no status line data exists)

    /// Estimates context usage from the last assistant message in the transcript tail.
    /// Always labeled `estimated`: the context window size has to be guessed.
    public static func estimateContext(transcriptTail: String, knownLargeWindow: Bool = false) -> PercentMetric? {
        var lastTokens: Double?
        var model: String?
        for line in transcriptTail.split(separator: "\n") {
            guard line.contains("\"usage\""),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? JSON,
                  let msg = obj["message"] as? JSON,
                  let usage = msg["usage"] as? JSON else { continue }
            let t = (number(usage["input_tokens"]) ?? 0)
                + (number(usage["cache_creation_input_tokens"]) ?? 0)
                + (number(usage["cache_read_input_tokens"]) ?? 0)
            if t > 0 {
                lastTokens = t
                model = msg["model"] as? String
            }
        }
        guard let tokens = lastTokens else { return nil }
        let large = knownLargeWindow || model?.contains("[1m]") == true || tokens > 200_000
        let window: Double = large ? 1_000_000 : 200_000
        return PercentMetric(usedPercent: min(100, tokens / window * 100), source: .estimated, windowTokens: window)
    }

    /// True if the transcript shows the session held more than 200k tokens at some point
    /// (a compaction's `preTokens`), which means its model has a 1M-token window. Streams the
    /// file so large transcripts stay cheap.
    public static func transcriptShowsLargeWindow(path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        let marker = Array("\"preTokens\":".utf8)
        var carry: [UInt8] = []
        while let chunk = try? fh.read(upToCount: 1 << 20), !chunk.isEmpty {
            let bytes = carry + [UInt8](chunk)
            var i = 0
            while i + marker.count < bytes.count {
                if bytes[i] == marker[0], Array(bytes[i..<(i + marker.count)]) == marker {
                    var j = i + marker.count, n = 0.0
                    while j < bytes.count, bytes[j] >= 48, bytes[j] <= 57 { n = n * 10 + Double(bytes[j] - 48); j += 1 }
                    if n > 200_000 { return true }
                    i = j
                } else {
                    i += 1
                }
            }
            carry = Array(bytes.suffix(marker.count + 12))
        }
        return false
    }

    public static func readTail(of path: String, bytes: Int = 64 * 1024) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Project naming

    /// Prefers the enclosing git repository's name ("my-app" rather than "src").
    public static func projectDisplayName(for cwd: String) -> String {
        var url = URL(fileURLWithPath: cwd).standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        for _ in 0..<8 {
            if url.path == "/" || url.path == home { break }
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.lastPathComponent
            }
            url.deleteLastPathComponent()
        }
        return projectName(forDirectory: cwd)
    }
}
