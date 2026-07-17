// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "monica",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "monica",
            path: "Sources/monica",
            swiftSettings: [
                // Full Swift 6 strict concurrency fights the AppKit/Carbon/
                // Process callback patterns here (opaque Carbon refs in
                // deinit, an ObservableObject singleton) — same call beacon
                // made. See AGENTS.md.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
