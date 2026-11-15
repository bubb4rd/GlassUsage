// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GlassUsage",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "GlassUsage",
            path: "Sources/GlassUsage",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ]
)
