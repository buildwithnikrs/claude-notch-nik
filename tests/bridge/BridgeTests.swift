import Foundation
import Darwin
import Testing
@testable import NotchBridge
import NotchCore

/// Sun paths are limited to ~104 bytes, so tests use short /tmp names.
private func socketPath() -> String { "/tmp/cn-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock" }

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}

private func question(_ id: String, session: String) -> NormalizedEvent {
    NormalizedEvent(type: .sessionNeedsInput, sessionId: session, question: QuestionPayload(
        id: id, kind: .question, items: [QuestionItem(text: "Pick one", options: [QuestionOption(label: "A"), QuestionOption(label: "B")])],
        answerable: true))
}

@Suite(.serialized) struct BridgeRoundTrip {
    @Test func appNotRunningIsReportedQuickly() {
        let start = Date()
        let r = BridgeClient.send(BridgeEnvelope(event: NormalizedEvent(type: .sessionWorking, sessionId: "a")), path: socketPath())
        #expect(r == .appNotRunning)
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func deliversEventsAndRejectsMalformed() throws {
        let path = socketPath()
        let q = DispatchQueue(label: "t")
        let server = BridgeServer(path: path, handlerQueue: q)
        let got = Box<[NormalizedEvent]>([])
        let rejected = Box(0)
        let sem = DispatchSemaphore(value: 0)
        server.onEvent = { e, _ in got.value.append(e); sem.signal() }
        server.onRejected = { _ in rejected.value += 1; sem.signal() }
        try server.start()
        defer { server.stop() }

        // Socket is private to this user.
        var st = stat()
        stat(path, &st)
        #expect(st.st_mode & 0o077 == 0)

        #expect(BridgeClient.send(BridgeEnvelope(event: NormalizedEvent(type: .sessionWorking, sessionId: "abc")), path: path) == .delivered)
        #expect(sem.wait(timeout: .now() + 2) == .success)

        // Invalid session id → rejected, never reaches the state machine.
        _ = BridgeClient.send(BridgeEnvelope(event: NormalizedEvent(type: .sessionWorking, sessionId: "../x")), path: path)
        #expect(sem.wait(timeout: .now() + 2) == .success)

        // Raw garbage.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = try makeAddress(path)
        _ = withSockaddr(&addr) { connect(fd, $0, $1) }
        _ = "not json\n".withCString { write(fd, $0, 9) }
        close(fd)
        #expect(sem.wait(timeout: .now() + 2) == .success)

        q.sync {}
        #expect(got.value.map(\.sessionId) == ["abc"])
        #expect(rejected.value == 2)
    }

    @Test func answerReachesOnlyTheAskingHook() throws {
        let path = socketPath()
        let q = DispatchQueue(label: "t")
        let server = BridgeServer(path: path, handlerQueue: q)
        let pendings = Box<[String: PendingReply]>([:])
        let sem = DispatchSemaphore(value: 0)
        server.onEvent = { e, p in
            if let p { pendings.value[e.sessionId] = p }
            sem.signal()
        }
        try server.start()
        defer { server.stop() }

        let resultA = Box<BridgeSendResult?>(nil)
        let resultB = Box<BridgeSendResult?>(nil)
        let done = DispatchGroup()
        for (session, box) in [("A", resultA), ("B", resultB)] {
            done.enter()
            Thread {
                box.value = BridgeClient.send(BridgeEnvelope(event: question("q-\(session)", session: session), expectsReply: true),
                                              path: path, replyTimeout: 5)
                done.leave()
            }.start()
        }
        #expect(sem.wait(timeout: .now() + 2) == .success)
        #expect(sem.wait(timeout: .now() + 2) == .success)

        let pb = try #require(q.sync { pendings.value["B"] })
        let pa = try #require(q.sync { pendings.value["A"] })
        // A reply for the wrong question id is refused outright.
        #expect(pb.send(BridgeReply(questionId: "q-A", action: .answer, answers: ["Pick one": "A"])) == false)
        #expect(pb.send(BridgeReply(questionId: "q-B", action: .answer, answers: ["Pick one": "B"])))
        #expect(pa.send(BridgeReply(questionId: "q-A", action: .defer)))
        #expect(done.wait(timeout: .now() + 5) == .success)

        #expect(resultB.value == .reply(BridgeReply(questionId: "q-B", action: .answer, answers: ["Pick one": "B"])))
        #expect(resultA.value == .reply(BridgeReply(questionId: "q-A", action: .defer)))
        // Replying twice is a no-op.
        #expect(pb.send(BridgeReply(questionId: "q-B", action: .answer, answers: ["Pick one": "A"])) == false)
    }

    @Test func hookTimeoutIsDetectedAsDisconnect() throws {
        let path = socketPath()
        let q = DispatchQueue(label: "t")
        let server = BridgeServer(path: path, handlerQueue: q)
        let pending = Box<PendingReply?>(nil)
        let disconnected = DispatchSemaphore(value: 0)
        server.onEvent = { _, p in
            pending.value = p
            p?.onDisconnect = { disconnected.signal() }
        }
        try server.start()
        defer { server.stop() }

        let r = BridgeClient.send(BridgeEnvelope(event: question("q1", session: "S"), expectsReply: true), path: path, replyTimeout: 0.3)
        #expect(r == .noReply)
        #expect(disconnected.wait(timeout: .now() + 2) == .success)
        let p = try #require(q.sync { pending.value })
        #expect(p.isOpen == false)
        #expect(p.send(BridgeReply(questionId: "q1", action: .answer, answers: ["Pick one": "A"])) == false)
    }

    @Test func secondServerRefusesToStart() throws {
        let path = socketPath()
        let a = BridgeServer(path: path, handlerQueue: DispatchQueue(label: "a"))
        try a.start()
        defer { a.stop() }
        let b = BridgeServer(path: path, handlerQueue: DispatchQueue(label: "b"))
        #expect(throws: BridgeServerError.alreadyRunning) { try b.start() }
    }
}
