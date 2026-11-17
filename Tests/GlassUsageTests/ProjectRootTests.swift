import Foundation
import Testing
@testable import GlassUsage

/// Which project a session folder counts toward.
@Suite struct ProjectRootTests {
    private let base = FileManager.default.temporaryDirectory.appending(path: "ProjectRootTests-\(UUID().uuidString)").path

    private func make(_ folders: [String], files: [String: String] = [:]) throws {
        for folder in folders {
            try FileManager.default.createDirectory(atPath: "\(base)/\(folder)", withIntermediateDirectories: true)
        }
        for (file, text) in files { try text.write(toFile: "\(base)/\(file)", atomically: true, encoding: .utf8) }
    }

    private func root(_ path: String, readProtected: Bool = false, home: String = "/Users/nobody") -> String {
        ProjectRoots.root(of: "\(base)/\(path)", readProtected: readProtected, home: home)
            .replacing("\(base)/", with: "")
    }

    @Test func subfoldersCountTowardTheirRepository() throws {
        try make(["gliide/.git", "gliide/app/src", "loose/notes"])
        defer { try? FileManager.default.removeItem(atPath: base) }

        #expect(root("gliide/app") == "gliide")
        #expect(root("gliide/app/src") == "gliide")
        #expect(root("gliide/deleted-since") == "gliide", "a removed subfolder still belongs to its repository")
        #expect(root("gliide") == "gliide")
        #expect(root("loose/notes") == "loose/notes", "outside a repository a folder stays its own project")
    }

    @Test func worktreesAndSubmodulesCountTowardTheMainRepository() throws {
        try make(["main/.git/worktrees/feature", "main/.git/modules/lib", "main/lib", "main/.claude/worktrees/chip", "elsewhere/feature"],
                 files: [
                    "elsewhere/feature/.git": "gitdir: \(base)/main/.git/worktrees/feature\n",
                    "main/.claude/worktrees/chip/.git": "gitdir: \(base)/main/.git/worktrees/chip\n",
                    "main/lib/.git": "gitdir: ../.git/modules/lib\n",
                 ])
        defer { try? FileManager.default.removeItem(atPath: base) }

        #expect(root("elsewhere/feature") == "main")
        #expect(root("main/.claude/worktrees/chip") == "main")
        #expect(root("main/lib") == "main")
    }

    @Test func homeFolderUnderGitNeverSwallowsProjects() throws {
        try make(["home/.git", "home/work/app", "home/site/.git"])
        defer { try? FileManager.default.removeItem(atPath: base) }

        #expect(root("home/work/app", home: "\(base)/home") == "home/work/app")
        #expect(root("home/site", home: "\(base)/home") == "home/site")
    }

    @Test func protectedFoldersNeedPermission() throws {
        try make(["home/Documents/gliide/.git", "home/Documents/gliide/app"])
        defer { try? FileManager.default.removeItem(atPath: base) }

        #expect(root("home/Documents/gliide/app", home: "\(base)/home") == "home/Documents/gliide/app")
        #expect(root("home/Documents/gliide/app", readProtected: true, home: "\(base)/home") == "home/Documents/gliide")
    }
}
