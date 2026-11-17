import Foundation
import Testing
@testable import GlassUsage

/// Which file in a project folder becomes its logo.
@Suite struct ProjectIconTests {
    private func project(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "ProjectIconTests-\(UUID().uuidString)")
        for file in files {
            let url = root.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0, count: file.hasSuffix("big.png") ? 4096 : 16).write(to: url)
        }
        return root
    }

    /// Candidate paths relative to the project; the temp folder may come back behind /private.
    private func candidates(_ root: URL) -> [String] {
        ProjectIcons.candidates(in: root).map {
            $0.pathComponents.drop { !$0.hasPrefix("ProjectIconTests-") }.dropFirst().joined(separator: "/")
        }
    }

    @Test func appIconsBeatWebIconsAndDependenciesAreIgnored() throws {
        let root = try project([
            "public/favicon.svg",
            "docs/logo.png",
            "src-tauri/icons/icon.png",
            "node_modules/pkg/icon.icns",
            ".build/Release/AppIcon.icns",
            "dist/AppIcon.icns",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(candidates(root) == ["src-tauri/icons/icon.png", "docs/logo.png", "public/favicon.svg"])
    }

    @Test func projectsOwnIconBeatsANestedOneOfTheSameKind() throws {
        let root = try project(["packages/site/public/favicon.ico", "favicon.ico"])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(candidates(root) == ["favicon.ico", "packages/site/public/favicon.ico"])
    }

    @Test func assetCatalogUsesItsLargestAppIcon() throws {
        let root = try project([
            "App/Assets.xcassets/AppIcon.appiconset/16.png",
            "App/Assets.xcassets/AppIcon.appiconset/big.png",
            "App/Assets.xcassets/AppIcon.appiconset/Contents.json",
            "Support/AppIcon.icns",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(ProjectIcons.candidates(in: root).map(\.lastPathComponent) == ["big.png", "AppIcon.icns"])
    }
}
