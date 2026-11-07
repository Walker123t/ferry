// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ferry",
    platforms: [.macOS(.v14)],
    targets: [
        // Thin bridge to Homebrew's libmtp (brew install libmtp).
        .systemLibrary(
            name: "CLibMTP",
            path: "Sources/CLibMTP",
            pkgConfig: "libmtp",
            providers: [.brew(["libmtp"])]
        ),
        .executableTarget(
            name: "Ferry",
            dependencies: ["CLibMTP"],
            path: "Sources/Ferry"
        ),
    ]
)
