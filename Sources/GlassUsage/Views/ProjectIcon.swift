import SwiftUI

/// A project's own logo when its folder has one; otherwise a letter tile.
/// "Other" (no folder recorded) and the home folder get neutral symbols. Folders macOS guards are only searched
/// when Settings allows it, so the panel never sets off a permission prompt on its own.
struct ProjectIcon: View {
    let project: ProjectSpend
    var size: CGFloat = 14

    @Environment(\.appSettings) private var settings
    private var store: ProjectIconStore { .shared }
    private var readProtected: Bool { settings?.readProtectedFolders == true }
    private var mayRead: Bool { readProtected || !ProjectIcons.isProtected(project.path) }

    var body: some View {
        content
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            .task(id: "\(project.path)|\(readProtected)") { if mayRead { store.load(project.path, readProtected: readProtected) } }
    }

    @ViewBuilder private var content: some View {
        if project.path.isEmpty {
            symbol("ellipsis")
        } else if project.path == URL.homeDirectory.path {
            symbol("house.fill")
        } else if mayRead, let image = store.images[project.path] {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .clipShape(.rect(cornerRadius: size * 0.25, style: .continuous))
                .transition(.opacity)
        } else {
            let letter = project.name.split(separator: "/").last?.first.map { String($0).uppercased() } ?? "?"
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(Self.tint(for: project.path).gradient)
                .overlay {
                    Text(letter)
                        .font(.system(size: size * 0.62, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
        }
    }

    private func symbol(_ name: String) -> some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(.quaternary)
            .overlay {
                Image(systemName: name)
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.secondary)
            }
    }

    /// Stable across launches (unlike `hashValue`), so a project keeps its color.
    private static func tint(for path: String) -> Color {
        let hash = path.unicodeScalars.reduce(UInt32(2_166_136_261)) { ($0 ^ $1.value) &* 16_777_619 }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.5, brightness: 0.72)
    }
}

extension EnvironmentValues {
    /// The spend rows read and offer to turn on `readProtectedFolders`.
    @Entry var appSettings: AppSettings? = nil
}

/// Logos found so far, kept for the app's lifetime; each folder is searched once, off the main actor.
@Observable final class ProjectIconStore {
    static let shared = ProjectIconStore()

    private(set) var images: [String: CGImage] = [:]
    /// Highest `readProtected` level already searched per project path, so enabling protected folders re-checks.
    @ObservationIgnored private var requested: [String: Bool] = [:]

    func load(_ path: String, readProtected: Bool) {
        guard !path.isEmpty else { return }
        if let previous = requested[path], previous || !readProtected { return }
        requested[path] = readProtected
        Task {
            let image = await Task.detached(priority: .utility) {
                ProjectIcons.image(forProject: path, readProtected: readProtected)
            }.value
            guard let image else { return }
            withAnimation(.easeOut(duration: 0.2)) { images[path] = image }
        }
    }
}
