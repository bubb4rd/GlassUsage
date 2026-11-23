import AppKit
import CryptoKit
import SQLite3

/// Finds a project's own logo: any custom icon set for it in T3 Code first, then app icons, web icons,
/// logos and favicons inside its folder. Read-only and bounded: a few levels deep, skipping dependencies and build output.
nonisolated enum ProjectIcons {
    /// Icon files in `folder`, best first: by kind, then by depth so a project's own icon beats a nested one.
    static func candidates(in folder: URL) -> [URL] {
        var found: [(url: URL, rank: Int, depth: Int)] = []
        var queue: [(URL, Int)] = [(folder, 0)]
        var visited = 0
        let fileManager = FileManager.default
        while !queue.isEmpty, visited < maxDirectories {
            let (directory, depth) = queue.removeFirst()
            visited += 1
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                let name = entry.lastPathComponent.lowercased()
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDirectory {
                    if entry.pathExtension == "appiconset", let largest = largestImage(in: entry) {
                        found.append((largest, 0, depth))
                    } else if depth < maxDepth, !skippedDirectories.contains(name), !bundleExtensions.contains(entry.pathExtension) {
                        queue.append((entry, depth + 1))
                    }
                } else if let rank = rank(name) {
                    found.append((entry, rank, depth))
                }
            }
        }
        return found.sorted { ($0.rank, $0.depth, $0.url.path) < ($1.rank, $1.depth, $1.url.path) }.map(\.url)
    }

    /// The first candidate that loads and isn't a framework's stock icon, drawn into a square of `pixels`.
    /// Checks a custom icon set in T3 Code's database first (still honoring `readProtected` if that file
    /// lives inside a folder macOS guards such as Downloads or Documents), then searches the project folder.
    static func image(forProject path: String, pixels: Int = 64, readProtected: Bool = true,
                      t3StateDatabase: URL = AntigravityLogs.t3HomeDirectory.appending(path: "userdata/statev2.sqlite")) -> CGImage? {
        guard !path.isEmpty else { return nil }
        if let custom = t3IconURL(forProject: path, database: t3StateDatabase),
           readProtected || !isProtected(custom.path),
           let data = try? Data(contentsOf: custom),
           let image = NSImage(data: data),
           let thumbnail = thumbnail(image, pixels: pixels) {
            return thumbnail
        }
        for url in candidates(in: URL(filePath: path, directoryHint: .isDirectory)) {
            guard let data = try? Data(contentsOf: url), !stockIcons.contains(sha256(data)) else { continue }
            if let image = NSImage(data: data), let thumbnail = thumbnail(image, pixels: pixels) { return thumbnail }
        }
        return nil
    }

    /// Custom project icon (`favicon_path`) stored by T3 Code in `projection_projects`, resolved against `workspace_root`
    /// when relative. Read-only; returns nil when T3 Code isn't installed or the project has no custom icon.
    static func t3IconURL(forProject path: String,
                          database: URL = AntigravityLogs.t3HomeDirectory.appending(path: "userdata/statev2.sqlite"),
                          home: URL = URL.homeDirectory) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: database.path) else { return nil }
        let hasLog = fm.fileExists(atPath: database.path + "-wal")
        var components = URLComponents(url: database, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: hasLog ? "mode" : "immutable", value: hasLog ? "ro" : "1")]
        guard let uri = components?.string else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)

        let normalized = URL(filePath: path).standardizedFileURL.path
        let sql = """
            SELECT favicon_path FROM projection_projects
            WHERE workspace_root = ? AND deleted_at IS NULL AND favicon_path IS NOT NULL AND favicon_path != ''
            ORDER BY updated_at DESC LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, normalized, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { return nil }
        let favicon = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !favicon.isEmpty else { return nil }
        if favicon.hasPrefix("/") {
            return URL(filePath: favicon).standardizedFileURL
        }
        if favicon.hasPrefix("~/") {
            return home.appending(path: String(favicon.dropFirst(2))).standardizedFileURL
        }
        return URL(filePath: normalized, directoryHint: .isDirectory).appending(path: favicon).standardizedFileURL
    }

    /// Inside a folder macOS guards with a permission prompt: Documents, Desktop, Downloads, iCloud Drive,
    /// cloud storage (Dropbox, Google Drive) and external or network volumes.
    static func isProtected(_ path: String, home: String = URL.homeDirectory.path) -> Bool {
        let guarded = ["Documents", "Desktop", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
            .map { "\(home)/\($0)" } + ["/Volumes"]
        return guarded.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static let maxDepth = 3
    /// Caps the walk in large monorepos.
    private static let maxDirectories = 400
    private static let skippedDirectories: Set<String> = [
        "node_modules", "build", "dist", "out", "target", "deriveddata", "pods", "vendor", "coverage",
    ]
    private static let bundleExtensions: Set<String> = ["app", "framework", "bundle", "xcframework", "xcarchive"]
    /// Templates' placeholder art: projects that never replaced it would all show the same mark.
    /// create-next-app's favicon (the Vercel triangle) and create-react-app's `src/logo.svg` (the React atom).
    private static let stockIcons: Set<String> = [
        "2b8ad2d33455a8f736fc3a8ebf8f0bdea8848ad4c0db48a2833bd0f9cd775932",
        "6000b0e9b0b05b3f112de04f0d039768a1db63588ff9b6ef7099dbd71632f383",
    ]

    /// Lower is better: macOS app icons, app and touch icons, logos, then favicons.
    private static func rank(_ name: String) -> Int? {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        if ext == "icns" { return 1 }
        guard ["png", "svg", "ico"].contains(ext) else { return nil }
        if ["icon", "app-icon", "appicon", "apple-touch-icon", "apple-icon"].contains(stem), ext != "ico" { return 2 }
        if stem == "logo" || stem.hasSuffix("-logo"), ext != "ico" { return 3 }
        if stem == "favicon" { return 4 }
        return nil
    }

    /// An asset catalog's app icon set holds one PNG per size; the largest file is the largest size.
    private static func largestImage(in iconSet: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: iconSet, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "png" }
            .max { size($0) < size($1) }
    }

    private static func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Aspect-fit into a transparent square so a 1024px icon or a wide logo doesn't stay in memory.
    private static func thumbnail(_ image: NSImage, pixels: Int) -> CGImage? {
        guard image.isValid, image.size.width > 0, image.size.height > 0,
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let side = CGFloat(pixels)
        let scale = min(side / image.size.width, side / image.size.height)
        let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = CGRect(x: (side - fitted.width) / 2, y: (side - fitted.height) / 2, width: fitted.width, height: fitted.height)
        context.interpolationQuality = .high
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
