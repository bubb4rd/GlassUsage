import AppKit
import SwiftUI

/// TokenHell-style tokens: flat ink on the glass, hairline dividers, a fixed categorical
/// palette for identities and four status bands for limits.
enum Theme {
    // Ink and surfaces, as opacities of the label color so they follow light/dark and the glass tint.
    static let hair = Color.primary.opacity(0.09)
    static let fill1 = Color.primary.opacity(0.05)
    static let fill2 = Color.primary.opacity(0.10)
    static let track = Color.primary.opacity(0.10)

    // Categorical palette (light, dark).
    static let s1 = dynamic(0x2A78D6, 0x3987E5)  // blue
    static let s2 = dynamic(0xEB6834, 0xD95926)  // orange
    static let s3 = dynamic(0x1BAF7A, 0x199E70)  // green
    static let s4 = dynamic(0xEDA100, 0xC98500)  // amber
    static let accent = dynamic(0xEB6834, 0xEB6834)

    // Status bands.
    static let good = dynamic(0x0CA30C, 0x0CA30C)
    static let warning = dynamic(0xFAB219, 0xFAB219)
    static let serious = dynamic(0xEC835A, 0xEC835A)
    static let critical = dynamic(0xD03B3B, 0xE66767)

    /// Fixed identity color per provider, used for dots, chart stacks and share bars.
    static func color(for provider: ProviderID) -> Color {
        switch provider {
        case .claude: s2
        case .codex: s1
        }
    }

    enum Band {
        case good, warning, serious, critical

        init(percent: Double) {
            switch percent {
            case 90...: self = .critical
            case 75...: self = .serious
            case 50...: self = .warning
            default: self = .good
            }
        }

        var color: Color {
            switch self {
            case .good: Theme.good
            case .warning: Theme.warning
            case .serious: Theme.serious
            case .critical: Theme.critical
            }
        }
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        func nsColor(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? nsColor(dark) : nsColor(light)
        })
    }
}

/// Small uppercase section label ("LIMITS · % used").
struct Eyebrow: View {
    let text: String
    var unit: String?

    init(_ text: String, unit: String? = nil) {
        self.text = text
        self.unit = unit
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(text.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
            if let unit {
                Text(" · \(unit)").font(.system(size: 10.5, weight: .medium))
            }
        }
        .foregroundStyle(.tertiary)
    }
}

struct Dot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// Thin rounded meter on a neutral track.
struct Meter: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color)
                    .frame(width: proxy.size.width * min(max(fraction, 0.015), 1))
            }
        }
        .frame(height: height)
        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.4), value: fraction)
    }
}

/// Square icon button with a hover fill. `active` marks a toggle that's on.
struct IconButton: View {
    let symbol: String
    let help: String
    var spinning = false
    var active = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: spinning)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(active ? Theme.fill2 : hovering ? Theme.fill2 : .clear))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .foregroundStyle(active || hovering ? .primary : .secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// TokenHell's compact segmented control: a tinted track with a raised selected pill.
struct PillPicker<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.fill1))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}
