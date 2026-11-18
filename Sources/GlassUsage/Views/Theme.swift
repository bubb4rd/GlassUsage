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

    /// Identity color per provider in a color theme, for chart stacks, the spend bar and list bars (graphite is
    /// drawn by `SpendPalette`). Providers: each brand's own hue, Claude's clay, OpenAI's silver, Google blue
    /// and Meta violet. Neon: brighter and further apart, made to glow in dither. Neither uses green, which
    /// marks a limit with room left.
    static func color(for provider: ProviderID, in colors: SpendColors) -> Color {
        (colors == .neon ? neon : brand)[provider]!
    }

    private static let brand: [ProviderID: Color] = [
        .claude: dynamic(0xC4623F, 0xE08360), .codex: dynamic(0x55585F, 0xC9CDD6),
        .antigravity: dynamic(0x1A73E8, 0x4F8FF7), .muse: dynamic(0x8A3FFC, 0xAC7BFF),
    ]
    private static let neon: [ProviderID: Color] = [
        .claude: dynamic(0xE2580F, 0xFF7A3D), .codex: dynamic(0x2563EB, 0x4C8DFF),
        .antigravity: dynamic(0x0891B2, 0x2ED3F0), .muse: dynamic(0xD12677, 0xFF4FB0),
    ]

    /// Ordered by severity, so `max` picks the worse of two.
    enum Band: Comparable {
        case good, warning, serious, critical

        init(percent: Double) {
            switch percent {
            case 90...: self = .critical
            case 75...: self = .serious
            case 50...: self = .warning
            default: self = .good
            }
        }

        /// The worse of how much is used and where the pace leads: close to the limit by the reset is a warning,
        /// running out before it serious, and out for over a quarter of the window critical.
        init(window: UsageWindow, now: Date) {
            let pace: Band = switch window.pace(at: now) {
            case .onPace(let projected) where projected > 0.9: .warning
            case .runsOut(_, let lockout): lockout > 0.25 * window.duration ? .critical : .serious
            default: .good
            }
            self = max(Band(percent: window.percent), pace)
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

struct Dot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
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
        .pointingHand()
        .foregroundStyle(active || hovering ? .primary : .secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// TokenHell's compact segmented control: a tinted track with a raised selected pill.
/// `icon` draws something in front of an option's label: an SF Symbol, a swatch.
struct PillPicker<Value: Hashable, Icon: View>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    let icon: (Value) -> Icon

    init(options: [(value: Value, label: String)], selection: Binding<Value>, @ViewBuilder icon: @escaping (Value) -> Icon) {
        self.options = options
        _selection = selection
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    HStack(spacing: 4) {
                        icon(option.value)
                        Text(option.label)
                    }
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
                .pointingHand()
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.fill1))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

extension PillPicker where Icon == EmptyView {
    init(options: [(value: Value, label: String)], selection: Binding<Value>) {
        self.init(options: options, selection: selection) { _ in EmptyView() }
    }
}

/// The selected option between two chevrons that step back and forth through `options`, wrapping around.
/// The label keeps the width of the longest option so the arrows stay put while cycling.
struct CycleArrows<Value: Equatable>: View {
    let options: [(value: Value, label: String)]
    let selection: Value
    /// What the arrows step through, for their tooltips: "model group", "list".
    let noun: String
    let select: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ArrowButton(symbol: "chevron.left", help: "Previous \(noun)") { step(-1) }
            ZStack {
                ForEach(options.indices, id: \.self) { Text(options[$0].label).hidden() }
                Text(options.first { $0.value == selection }?.label ?? "")
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 4)
            .animation(.easeOut(duration: 0.15), value: options.firstIndex { $0.value == selection })
            ArrowButton(symbol: "chevron.right", help: "Next \(noun)") { step(1) }
        }
        .accessibilityElement(children: .contain)
    }

    private func step(_ delta: Int) {
        guard !options.isEmpty else { return }
        let index = options.firstIndex { $0.value == selection } ?? 0
        select(options[(index + delta + options.count) % options.count].value)
    }
}

private struct ArrowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 16, height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Theme.fill2 : Theme.fill1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHand()
        .foregroundStyle(hovering ? .primary : .secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
