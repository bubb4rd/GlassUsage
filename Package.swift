// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GlassUsage",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "GlassUsage",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/GlassUsage",
            swiftSettings: [.defaultIsolation(MainActor.self)],
            // Sparkle.framework is embedded in GlassUsage.app/Contents/Frameworks by Scripts/build-app.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
