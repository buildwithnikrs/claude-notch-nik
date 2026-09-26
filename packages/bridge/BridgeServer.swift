import Foundation
import Darwin
import NotchCore

/// A held-open hook connection waiting for the user's answer.
public final class PendingReply: @unchecked Sendable {
    public let questionId: String
    public let sessionId: String
    fileprivate let connection: Connection
    fileprivate let handlerQueue: DispatchQueue
    /// Called on the handler queue if the hook goes away before we reply
    /// (it timed out and fell back to the terminal, or Claude was interrupted).
    public var onDisconnect: (() -> Void)?

    fileprivate init(questionId: String, sessionId: String, connection: Connection, handlerQueue: DispatchQueue) {
        self.questionId = questionId
        self.sessionId = sessionId
        self.connection = connection
        self.handlerQueue = handlerQueue
    }

    public var isOpen: Bool { connection.isOpen }

    /// Sends the reply and closes the connection. Returns false if the hook is already gone.
    @discardableResult
    public func send(_ reply: BridgeReply) -> Bool {
        guard reply.questionId == questionId else { return false }
        return connection.reply(reply)
    }

    fileprivate func hookDisconnected() {
        handlerQueue.async { [self] in onDisconnect?() }
    }
}

fileprivate final class Connection: @unchecked Sendable {
    let fd: Int32
    let io: DispatchQueue
    var source: DispatchSourceRead?
    var buffer = Data()
    /// Weak: the app owns pending replies; the connection only notifies them.
    weak var pending: PendingReply?
    var expectsReply = false
    private var closed = false
    private let lock = NSLock()

    init(fd: Int32, io: DispatchQueue) {
        self.fd = fd
        self.io = io
    }

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed
    }

    func reply(_ r: BridgeReply) -> Bool {
        io.sync {
            guard isOpen, var data = try? BridgeCoding.encoder().encode(r) else { return false }
            data.append(0x0A)
            let ok = writeAll(fd, data)
            close(notify: false)
            return ok
        }
    }

    /// Must be called on `io`.
    func close(notify: Bool) {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        source?.cancel()
        source = nil
        if notify { pending?.hookDisconnected() }
    }
}

public enum BridgeServerError: Error, Equatable {
    case alreadyRunning
    case socket(String)
}

/// Listens on a Unix domain socket for hook events. Local-only by construction: no TCP,
/// socket file is 0600 inside a 0700 directory, and peers must be the same uid.
public final class BridgeServer: @unchecked Sendable {
    public let path: String
    private let handlerQueue: DispatchQueue
    private let io = DispatchQueue(label: "claude-notch.bridge.io")
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: Connection] = [:]

    /// Called on the handler queue for every valid event. `reply` is non-nil when the hook
    /// is holding a question open and waiting for an answer.
    public var onEvent: ((NormalizedEvent, PendingReply?) -> Void)?
    /// Called on the handler queue when a message fails to decode or validate.
    public var onRejected: ((String) -> Void)?

    public init(path: String = BridgePaths.socketPath, handlerQueue: DispatchQueue = .main) {
        self.path = path
        self.handlerQueue = handlerQueue
    }

    deinit { stop() }

    public func start() throws {
        if isSomeoneListening(path) { throw BridgeServerError.alreadyRunning }
        unlink(path) // stale socket from a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeServerError.socket("socket: \(errno)") }
        var addr: sockaddr_un
        do { addr = try makeAddress(path) } catch {
            Darwin.close(fd)
            throw BridgeServerError.socket("path too long")
        }
        let oldMask = umask(0o177) // socket file created as 0600
        let bound = withSockaddr(&addr) { bind(fd, $0, $1) }
        umask(oldMask)
        guard bound == 0 else {
            let err = errno
            Darwin.close(fd)
            throw BridgeServerError.socket("bind: \(err)")
        }
        chmod(path, 0o600)
        guard listen(fd, 32) == 0 else {
            Darwin.close(fd)
            throw BridgeServerError.socket("listen: \(errno)")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
        src.setEventHandler { [weak self] in self?.acceptAll() }
        src.setCancelHandler { Darwin.close(fd) }
        listenSource = src
        src.resume()
    }

    public func stop() {
        io.sync {
            listenSource?.cancel()
            listenSource = nil
            for c in connections.values { c.close(notify: false) }
            connections.removeAll()
        }
        if listenFD >= 0 {
            unlink(path)
            listenFD = -1
        }
    }

    private func isSomeoneListening(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = try? makeAddress(path) else { return false }
        defer { Darwin.close(fd) }
        return withSockaddr(&addr) { connect(fd, $0, $1) } == 0
    }

    // MARK: io queue

    private func acceptAll() {
        while true {
            let cfd = accept(listenFD, nil, nil)
            if cfd < 0 { return }
            // Same-user check on top of filesystem permissions.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(cfd, &uid, &gid) == 0, uid == getuid() else {
                Darwin.close(cfd)
                continue
            }
            disableSigpipe(cfd)
            _ = fcntl(cfd, F_SETFL, fcntl(cfd, F_GETFL) | O_NONBLOCK)
            let conn = Connection(fd: cfd, io: io)
            let key = ObjectIdentifier(conn)
            connections[key] = conn
            let src = DispatchSource.makeReadSource(fileDescriptor: cfd, queue: io)
            src.setEventHandler { [weak self, weak conn] in
                guard let self, let conn else { return }
                self.readAvailable(conn)
            }
            src.setCancelHandler { [weak self] in
                Darwin.close(cfd)
                self?.connections[key] = nil
            }
            conn.source = src
            src.resume()
        }
    }

    private func readAvailable(_ conn: Connection) {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(conn.fd, &chunk, chunk.count)
            if n > 0 {
                if conn.expectsReply { continue } // hook shouldn't send more; ignore
                conn.buffer.append(chunk, count: n)
                if conn.buffer.count > BridgeCoding.maxLineBytes {
                    reject(conn, "message too large")
                    return
                }
                if let nl = conn.buffer.firstIndex(of: 0x0A) {
                    let line = conn.buffer.subdata(in: conn.buffer.startIndex..<nl)
                    conn.buffer.removeAll()
                    handle(line: line, conn: conn)
                    if !conn.isOpen { return }
                }
                continue
            }
            if n == 0 {
                // EOF: the hook exited (or timed out) before we replied.
                conn.close(notify: true)
                return
            }
            if errno == EAGAIN || errno == EINTR { return }
            conn.close(notify: true)
            return
        }
    }

    private func reject(_ conn: Connection, _ why: String) {
        conn.close(notify: false)
        let cb = onRejected
        handlerQueue.async { cb?(why) }
    }

    private func handle(line: Data, conn: Connection) {
        let env: BridgeEnvelope
        do {
            env = try BridgeCoding.decoder().decode(BridgeEnvelope.self, from: line)
        } catch {
            reject(conn, "decode failed")
            return
        }
        guard env.v == 1 else { reject(conn, "unsupported version"); return }
        let event: NormalizedEvent
        do { event = try env.event.validated() } catch {
            reject(conn, "invalid event: \(error)")
            return
        }

        var pending: PendingReply?
        if env.expectsReply, event.type == .sessionNeedsInput, let q = event.question, q.answerable {
            let p = PendingReply(questionId: q.id, sessionId: event.sessionId, connection: conn, handlerQueue: handlerQueue)
            conn.pending = p
            conn.expectsReply = true
            pending = p
        } else {
            conn.close(notify: false)
        }
        let cb = onEvent
        handlerQueue.async { cb?(event, pending) }
    }
}
