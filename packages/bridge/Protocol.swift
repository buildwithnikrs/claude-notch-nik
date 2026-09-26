import Foundation
import NotchCore

/// Wire format: one JSON object per line over a Unix domain socket.
///
///   hook → app   BridgeEnvelope
///   app  → hook  BridgeReply      (only when `expectsReply` is true)
///
/// The reply travels back on the same connection the hook opened, so an answer can
/// physically only reach the process that asked (PRD AC-017, session isolation).
public struct BridgeEnvelope: Codable, Equatable, Sendable {
    public var v: Int
    public var event: NormalizedEvent
    public var expectsReply: Bool

    public init(event: NormalizedEvent, expectsReply: Bool = false) {
        v = 1
        self.event = event
        self.expectsReply = expectsReply
    }
}

public struct BridgeReply: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case answer  // answers[questionText] = label or free text
        case `defer` // let the host (Terminal) ask the question itself
    }

    public var questionId: String
    public var action: Action
    public var answers: [String: String]?

    public init(questionId: String, action: Action, answers: [String: String]? = nil) {
        self.questionId = questionId
        self.action = action
        self.answers = answers
    }
}

public enum BridgeCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }

    /// Max bytes in one line. Questions are small; anything bigger is malformed.
    public static let maxLineBytes = 256 * 1024
}

public enum BridgePaths {
    /// ~/Library/Application Support/ClaudeNotch — created 0700 so only this user can reach the socket.
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeNotch", isDirectory: true)
    }

    public static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_SOCKET"], !override.isEmpty {
            return override
        }
        return supportDirectory.appendingPathComponent("bridge.sock").path
    }

    public static func ensureSupportDirectory() throws {
        let dir = supportDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }
}
