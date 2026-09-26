import Foundation
import Darwin
import NotchCore

public enum BridgeSendResult: Equatable, Sendable {
    /// The app isn't running (or the socket is missing). Callers must carry on silently.
    case appNotRunning
    case delivered
    case reply(BridgeReply)
    /// Waited for a reply but none came (timeout, or the app closed the connection).
    case noReply
}

/// Blocking client used by the short-lived hook process.
public enum BridgeClient {
    public static func send(
        _ envelope: BridgeEnvelope,
        path: String = BridgePaths.socketPath,
        replyTimeout: TimeInterval? = nil
    ) -> BridgeSendResult {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .appNotRunning }
        defer { close(fd) }
        disableSigpipe(fd)
        guard var addr = try? makeAddress(path) else { return .appNotRunning }
        guard withSockaddr(&addr, { connect(fd, $0, $1) }) == 0 else { return .appNotRunning }

        setTimeout(fd, SO_SNDTIMEO, 2)
        guard var data = try? BridgeCoding.encoder().encode(envelope) else { return .appNotRunning }
        data.append(0x0A)
        guard writeAll(fd, data) else { return .appNotRunning }

        guard let timeout = replyTimeout else { return .delivered }

        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return .noReply }
            setTimeout(fd, SO_RCVTIMEO, min(remaining, 5))
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(chunk, count: n)
                if buffer.count > BridgeCoding.maxLineBytes { return .noReply }
                if let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<nl)
                    guard let reply = try? BridgeCoding.decoder().decode(BridgeReply.self, from: line) else { return .noReply }
                    return .reply(reply)
                }
            } else if n == 0 {
                return .noReply // app closed the connection (e.g. app quit)
            } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                continue // per-read timeout; loop re-checks the overall deadline
            } else {
                return .noReply
            }
        }
    }
}
