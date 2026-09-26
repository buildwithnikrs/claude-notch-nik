// swift-tools-version:6.0
import PackageDescription

// Renders the Claude Notch intro film (video + synthesized soundtrack) to MP4.
//   cd tools/film && swift run -c release film ../../site/media
let package = Package(
    name: "film",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "film", path: "Sources", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
