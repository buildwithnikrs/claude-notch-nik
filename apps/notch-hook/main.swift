import Foundation
import NotchCore
import NotchBridge
import ClaudeCodeAdapter

// notch-hook — the helper Claude Code runs as a hook and status line.
//
//   notch-hook event [--question]   hook entry point (stdin: Claude Code hook JSON)
//   notch-hook statusline           status line entry point (stdin: status line JSON)
//   notch-hook install [--no-statusline] | uninstall | status
//   notch-hook demo                 play a scripted multi-session demo into the running app
//
// Golden rule for `event` and `statusline`: never break Claude Code. Any failure (app not
// running, bad input) exits 0 with no output, which Claude Code treats as "no opinion".

let args = Array(CommandLine.arguments.dropFirst())
let env = ProcessInfo.processInfo.environment

func readStdin(limit: Int = 8 * 1024 * 1024) -> Data {
    var data = Data()
    while let chunk = try? FileHandle.standardInput.read(upToCount: 64 * 1024), !chunk.isEmpty {
        data.append(chunk)
        if data.count > limit { break }
    }
    return data
}

func json(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func config() -> [String: Any] {
    let url = BridgePaths.supportDirectory.appendingPathComponent("config.json")
    guard let d = try? Data(contentsOf: url) else { return [:] }
    return json(d) ?? [:]
}

func printJSON(_ obj: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) {
        FileHandle.standardOutput.write(d)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    }
}

// MARK: - event

func runEvent(questionMode: Bool) {
    let raw = readStdin()
    guard let input = json(raw) else { return }
    let ctx = ClaudeCodeAdapter.HookContext(
        env: env, now: Date(), claudePid: ProcessTree.claudeProcess(), synchronousQuestionHook: questionMode
    )
    guard let result = ClaudeCodeAdapter.normalize(hook: input, context: ctx) else { return }

    if result.waitForAnswer {
        let timeout = (config()["answerTimeoutSeconds"] as? Double) ?? 120
        let outcome = BridgeClient.send(BridgeEnvelope(event: result.event, expectsReply: true), replyTimeout: timeout)
        guard case .reply(let reply) = outcome,
              reply.action == .answer,
              reply.questionId == result.event.question?.id,
              let answers = reply.answers, !answers.isEmpty,
              let toolInput = input["tool_input"] as? [String: Any] else {
            return // no decision → Claude Code shows its normal question prompt
        }
        if (config()["answerMode"] as? String) == "deny" {
            printJSON(ClaudeCodeAdapter.answerViaDenyOutput(answers: answers))
        } else {
            printJSON(ClaudeCodeAdapter.answerOutput(originalToolInput: toolInput, answers: answers))
        }
        return
    }

    guard BridgeClient.send(BridgeEnvelope(event: result.event)) != .appNotRunning else { return }

    // After each turn, estimate context usage from the transcript. The app ignores this
    // whenever Claude Code's own (verified) status line value is available.
    if result.event.type == .sessionCompleted,
       let path = input["transcript_path"] as? String,
       let tail = ClaudeCodeAdapter.readTail(of: path),
       let ctxMetric = ClaudeCodeAdapter.estimateContext(transcriptTail: tail) {
        var e = result.event
        e.type = .usageUpdated
        e.usage = UsageSnapshot(context: ctxMetric, capturedAt: ctx.now)
        _ = BridgeClient.send(BridgeEnvelope(event: e))
    }
}

// MARK: - statusline

func runStatusLine() {
    let raw = readStdin()
    let input = json(raw) ?? [:]
    let ctx = ClaudeCodeAdapter.HookContext(env: env, now: Date(), claudePid: ProcessTree.claudeProcess())
    if let e = ClaudeCodeAdapter.normalize(statusLine: input, context: ctx) {
        _ = BridgeClient.send(BridgeEnvelope(event: e))
    }

    // Keep the user's own status line if they had one.
    if let chained = config()["chainedStatusLine"] as? [String: Any],
       let command = chained["command"] as? String, !command.isEmpty {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            inPipe.fileHandleForWriting.write(raw)
            try? inPipe.fileHandleForWriting.close()
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            FileHandle.standardOutput.write(out)
        } catch {}
        return
    }

    // Otherwise a small default line.
    var parts = ["✻"]
    if let m = (input["model"] as? [String: Any])?["display_name"] as? String { parts.append(m) }
    if let pct = ((input["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue {
        parts.append("\(Int(pct))% context")
    }
    if let pct = (((input["rate_limits"] as? [String: Any])?["five_hour"] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue {
        parts.append("\(Int(pct))% of 5h limit")
    }
    print(parts.joined(separator: " · "))
}

// MARK: - install

func installer() -> HookInstaller {
    HookInstaller(
        hookBinaryPath: BridgePaths.supportDirectory.appendingPathComponent("bin/notch-hook").path,
        configURL: BridgePaths.supportDirectory.appendingPathComponent("config.json")
    )
}

/// Copies this binary to a stable location so settings.json doesn't depend on where the app lives.
func installSelf() throws -> String {
    try BridgePaths.ensureSupportDirectory()
    let bin = BridgePaths.supportDirectory.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let dest = bin.appendingPathComponent("notch-hook")
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    if me.path != dest.path {
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: me, to: dest)
    }
    // A quarantined copy would be killed by Gatekeeper whenever Claude Code runs it.
    removexattr(dest.path, "com.apple.quarantine", 0)
    return dest.path
}

// MARK: - demo

func runDemo() {
    func send(_ e: NormalizedEvent) {
        if BridgeClient.send(BridgeEnvelope(event: e)) == .appNotRunning {
            print("Claude Notch isn't running. Open the app first.")
            exit(1)
        }
    }
    func pause(_ s: Double) { Thread.sleep(forTimeInterval: s) }
    let now = Date()
    let ids = ["demo-ecommerce", "demo-marketing", "demo-api"]
    let names = ["ecommerce", "marketing-site", "api"]
    print("▶︎ Three sessions start working…")
    for (i, id) in ids.enumerated() {
        send(NormalizedEvent(type: .sessionStarted, sessionId: id, projectName: names[i], host: .cli))
        send(NormalizedEvent(type: .sessionWorking, sessionId: id, timestamp: now.addingTimeInterval(Double(-40 * (i + 1))),
                             reason: .prompt))
    }
    send(NormalizedEvent(type: .sessionWorking, sessionId: ids[0], reason: .tool, activity: "Editing CheckoutView.swift"))
    send(NormalizedEvent(type: .sessionWorking, sessionId: ids[2], reason: .tool, activity: "Run the test suite"))
    // Per-session context only: plan limits are account-wide and would outlive the demo,
    // so the demo never fakes them.
    send(NormalizedEvent(type: .usageUpdated, sessionId: ids[0], usage: UsageSnapshot(
        context: PercentMetric(usedPercent: 61, source: .estimated))))
    send(NormalizedEvent(type: .usageUpdated, sessionId: ids[2], usage: UsageSnapshot(
        context: PercentMetric(usedPercent: 23, source: .estimated))))
    pause(4)

    print("▶︎ marketing-site asks a question (answer it in the notch)…")
    let q = QuestionPayload(id: "demo-q1", kind: .question, items: [
        QuestionItem(text: "Which database should I use?", header: "Database", options: [
            QuestionOption(label: "PostgreSQL", description: "Production-grade, runs in Docker"),
            QuestionOption(label: "SQLite", description: "Zero setup, single file"),
        ]),
    ], answerable: true)
    let answerThread = Thread {
        let r = BridgeClient.send(
            BridgeEnvelope(event: NormalizedEvent(type: .sessionNeedsInput, sessionId: ids[1], question: q), expectsReply: true),
            replyTimeout: 60
        )
        switch r {
        case .reply(let reply) where reply.action == .answer:
            print("✓ Answer received: \(reply.answers ?? [:])")
        case .reply:
            print("↪︎ Deferred to Terminal")
        default:
            print("… no answer within 60s (would fall back to Terminal)")
        }
    }
    answerThread.start()
    pause(2)

    print("▶︎ api finishes its task…")
    send(NormalizedEvent(type: .sessionCompleted, sessionId: ids[2]))

    while !answerThread.isFinished { pause(0.2) }
    send(NormalizedEvent(type: .sessionInputResolved, sessionId: ids[1], questionId: q.id))
    pause(5)
    print("▶︎ ecommerce finishes…")
    send(NormalizedEvent(type: .sessionCompleted, sessionId: ids[0]))
    pause(4)
    send(NormalizedEvent(type: .sessionCompleted, sessionId: ids[1]))
    pause(6)
    print("▶︎ Cleaning up demo sessions.")
    for id in ids { send(NormalizedEvent(type: .sessionEnded, sessionId: id)) }
}

// MARK: - main

switch args.first {
case "event":
    runEvent(questionMode: args.contains("--question"))
    exit(0)
case "statusline":
    runStatusLine()
    exit(0)
case "install":
    do {
        let path = try installSelf()
        let inst = HookInstaller(hookBinaryPath: path, configURL: installer().configURL)
        try inst.install(includeStatusLine: !args.contains("--no-statusline"))
        print("✓ Claude Code hooks installed in \(inst.settingsURL.path)")
        print("  Restart running Claude Code sessions to pick them up.")
    } catch {
        print("✗ \(error.localizedDescription)")
        exit(1)
    }
case "uninstall":
    do {
        try installer().uninstall()
        print("✓ Removed Claude Notch hooks from \(installer().settingsURL.path)")
    } catch {
        print("✗ \(error.localizedDescription)")
        exit(1)
    }
case "status":
    print(installer().status(includeStatusLine: false))
case "demo":
    runDemo()
default:
    print("""
    usage: notch-hook <command>
      event [--question]   hook entry point (used by Claude Code)
      statusline           status line entry point (used by Claude Code)
      install [--no-statusline]
      uninstall
      status
      demo                 play a scripted demo into the running app
    """)
}
