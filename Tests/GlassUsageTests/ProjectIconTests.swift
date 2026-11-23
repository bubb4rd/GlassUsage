import Foundation
import SQLite3
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

    @Test func onlyFoldersMacOSGuardsNeedPermission() {
        let home = "/Users/me"
        for path in ["/Users/me/Documents/app", "/Users/me/Desktop", "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/app",
                     "/Users/me/Library/CloudStorage/Dropbox/app", "/Volumes/Work/app"] {
            #expect(ProjectIcons.isProtected(path, home: home), "\(path)")
        }
        for path in ["/Users/me/Developer/app", "/Users/me/DocumentsArchive/app", "/Users/me", "/opt/work/app"] {
            #expect(!ProjectIcons.isProtected(path, home: home), "\(path)")
        }
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

    @Test func t3ProjectIconResolvesRelativeAndAbsolutePaths() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ProjectIconT3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appending(path: "statev2.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        let setup = """
        CREATE TABLE projection_projects (
            project_id TEXT PRIMARY KEY,
            workspace_root TEXT NOT NULL,
            favicon_path TEXT,
            updated_at TEXT NOT NULL,
            deleted_at TEXT
        );
        INSERT INTO projection_projects VALUES ('1', '/work/alpha', 'docs/brand/mark.svg', '2026-11-23T00:00:00Z', NULL);
        INSERT INTO projection_projects VALUES ('2', '/work/beta', '/custom/icon.png', '2026-11-23T00:00:00Z', NULL);
        INSERT INTO projection_projects VALUES ('3', '/work/deleted', '/custom/old.png', '2026-11-23T00:00:00Z', '2026-11-23T01:00:00Z');
        """
        #expect(sqlite3_exec(db, setup, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        #expect(ProjectIcons.t3IconURL(forProject: "/work/alpha", database: dbURL)?.path == "/work/alpha/docs/brand/mark.svg")
        #expect(ProjectIcons.t3IconURL(forProject: "/work/beta", database: dbURL)?.path == "/custom/icon.png")
        #expect(ProjectIcons.t3IconURL(forProject: "/work/deleted", database: dbURL) == nil)
        #expect(ProjectIcons.t3IconURL(forProject: "/work/missing", database: dbURL) == nil)
    }
}
