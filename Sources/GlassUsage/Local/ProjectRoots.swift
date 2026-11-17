import Foundation

/// The project a session folder belongs to: the top folder of its git repository, so sessions started in a
/// subfolder, a git worktree or a submodule count toward one project instead of each taking a row.
nonisolated enum ProjectRoots {
    /// The repository's top folder for `path`, or `path` itself when it isn't in a repository, or when finding out
    /// would read a folder macOS guards and `readProtected` is off. Never the home folder or one above it, so a
    /// home folder kept under git (dotfiles) doesn't swallow every project.
    static func root(of path: String, readProtected: Bool, home: String = URL.homeDirectory.path) -> String {
        guard readProtected || !ProjectIcons.isProtected(path, home: home) else { return path }
        func isHomeOrAbove(_ folder: String) -> Bool { folder == "/" || folder == home || home.hasPrefix(folder + "/") }
        var folder = path
        while !folder.isEmpty, !isHomeOrAbove(folder) {
            if let root = repository(at: folder) { return isHomeOrAbove(root) ? folder : root }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return path
    }

    /// The main repository's top folder when `folder` holds a `.git`, else nil. A repository's own `.git` is a
    /// folder; a worktree's or submodule's is a file pointing into the main repository's, at
    /// `<main>/.git/worktrees/<name>` or `<main>/.git/modules/<name>`.
    private static func repository(at folder: String) -> String? {
        let git = folder + "/.git"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: git, isDirectory: &isDirectory) else { return nil }
        guard !isDirectory.boolValue,
              let text = try? String(contentsOfFile: git, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:")
        else { return folder }
        let gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let target = URL(filePath: gitdir, directoryHint: .isDirectory,
                         relativeTo: URL(filePath: folder, directoryHint: .isDirectory)).standardizedFileURL.path(percentEncoded: false)
        guard let range = target.range(of: "/.git/") else { return folder }
        return String(target[..<range.lowerBound])
    }
}
