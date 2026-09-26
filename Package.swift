// swift-tools-version:6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "ClaudeNotch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeNotch", targets: ["ClaudeNotch"]),
        .executable(name: "notch-hook", targets: ["NotchHook"]),
    ],
    targets: [
        // Normalized events, session state machine, priority model. No UI, no I/O.
        .target(name: "NotchCore", path: "packages/core", swiftSettings: v5),
        // Local IPC between the hook helper and the app (Unix domain socket).
        .target(name: "NotchBridge", dependencies: ["NotchCore"], path: "packages/bridge", swiftSettings: v5),
        // Everything that knows about Claude Code: hook payloads, settings.json install.
        .target(name: "ClaudeCodeAdapter", dependencies: ["NotchCore"], path: "packages/claude-code", swiftSettings: v5),
        // The tiny binary Claude Code runs as a hook / status line.
        .executableTarget(
            name: "NotchHook",
            dependencies: ["NotchCore", "NotchBridge", "ClaudeCodeAdapter"],
            path: "apps/notch-hook",
            swiftSettings: v5
        ),
        // The macOS notch app.
        .executableTarget(
            name: "ClaudeNotch",
            dependencies: ["NotchCore", "NotchBridge", "ClaudeCodeAdapter"],
            path: "apps/macos",
            swiftSettings: v5
        ),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore"], path: "tests/core", swiftSettings: v5),
        .testTarget(name: "ClaudeCodeAdapterTests", dependencies: ["ClaudeCodeAdapter", "NotchCore"], path: "tests/claude-code", swiftSettings: v5),
        .testTarget(name: "NotchBridgeTests", dependencies: ["NotchBridge", "NotchCore"], path: "tests/bridge", swiftSettings: v5),
    ]
)
