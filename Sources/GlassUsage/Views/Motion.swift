import SwiftUI

extension EnvironmentValues {
    /// False while the panel is closed or closing: blocks fade out and graphs fold to their baseline, then
    /// rebuild in a cascade when it opens again.
    @Entry var panelRevealed = true
    /// When the enclosing block starts entering, so the graphs and rows inside it cascade after it.
    @Entry var revealDelay: Double = 0
}

/// Timing for blocks and graphs entering and leaving the panel.
enum Motion {
    /// Blocks drop into place with a hint of overshoot.
    static let enter = Animation.spring(duration: 0.4, bounce: 0.18)
    /// Rings sweep and bars grow along a long ease-out.
    static let draw = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.6)
    /// Everything folds at once on close, inside the window's fade.
    static let exit = Animation.easeIn(duration: 0.14)
    /// Gap between successive blocks.
    static let step = 0.04
    /// Long labels slide at a reading pace once the pointer settles on them.
    static func slide(distance: CGFloat) -> Animation {
        .linear(duration: max(distance / 30, 0.6)).delay(0.35)
    }
    /// …and return briskly when it leaves.
    static let slideBack = Animation.easeOut(duration: 0.25)

    /// `enter` after `delay` when an element shows, `exit` right away when it hides.
    static func curve(_ shown: Bool, _ enter: Animation, delay: Double) -> Animation {
        shown ? enter.delay(delay) : exit
    }
}

/// Hands `content` whether it's shown: once it has appeared, and while the panel is open. So an element
/// enters both when it's inserted (spend turned on, back from Settings) and every time the panel opens.
struct Revealing<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content

    @Environment(\.panelRevealed) private var revealed
    @State private var appeared = false

    var body: some View {
        content(appeared && revealed).onAppear { appeared = true }
    }
}

extension View {
    /// Fades the block in, dropping into place, `delay` after the enclosing block starts; it fades out on close.
    func reveal(after delay: Double) -> some View { modifier(Reveal(delay: delay)) }
}

private struct Reveal: ViewModifier {
    let delay: Double

    @Environment(\.revealDelay) private var base
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        Revealing { shown in
            content
                .environment(\.revealDelay, base + delay)
                .opacity(shown ? 1 : 0)
                .offset(y: shown || reduceMotion ? 0 : -8)
                .animation(Motion.curve(shown, Motion.enter, delay: base + delay), value: shown)
        }
    }
}

/// One line of text that, when it doesn't fit, fades out at its trailing edge and slides to show the rest
/// while `sliding`. Fits: plain text. Reduce Motion: it stays put.
struct SlidingLabel: View {
    let text: String
    let sliding: Bool

    @State private var fullWidth: CGFloat = 0
    @State private var shownWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let overflow = max(fullWidth - shownWidth, 0)
        let offset = sliding && !reduceMotion ? overflow : 0
        // The hidden copy sizes the label like any truncating text; the visible one runs past it.
        Text(text)
            .lineLimit(1)
            .hidden()
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { shownWidth = $0 }
            .overlay(alignment: .leading) {
                Text(text)
                    .lineLimit(1)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { fullWidth = $0 }
                    .offset(x: -offset)
            }
            .modifier(EdgeFades(offset: offset, overflow: overflow))
            .animation(offset > 0 ? Motion.slide(distance: overflow) : Motion.slideBack, value: offset)
    }
}

/// Clips a sliding label, fading whichever edge has text running past it, as far as it runs past.
private struct EdgeFades: ViewModifier, Animatable {
    var offset: CGFloat
    let overflow: CGFloat

    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    private static let width: CGFloat = 12

    func body(content: Content) -> some View {
        content.mask {
            HStack(spacing: 0) {
                edge(.leading, strength: offset / Self.width)
                Rectangle()
                edge(.trailing, strength: (overflow - offset) / Self.width)
            }
        }
    }

    private func edge(_ side: UnitPoint, strength: CGFloat) -> some View {
        LinearGradient(colors: [.black.opacity(1 - Double(min(max(strength, 0), 1))), .black],
                       startPoint: side, endPoint: side == .leading ? .trailing : .leading)
            .frame(width: Self.width)
    }
}
