import SwiftUI

extension EnvironmentValues {
    /// Solid or dithered rings and spend charts, as chosen in Settings.
    @Entry var chartFill: ChartFill = .solid
}

/// Dot-matrix fills after an ordered dither: a grid of square cells, each lit when its 4×4 Bayer threshold falls
/// under the density wanted there. Dense edges keep each shape readable; value noise varies the inside.
enum Dither {
    /// Distance between cell centers in the day chart and list bars; the spend bar's cells are a little larger.
    static let pitch: CGFloat = 3

    private static let bayer: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { ($0 + 0.5) / 16 }

    /// Whether the cell at `column`, `row` is lit at `density`: 0 lights none, 1 all.
    static func lit(_ column: Int, _ row: Int, _ density: Double) -> Bool {
        bayer[(row & 3) * 4 + (column & 3)] < density
    }

    /// A stable pseudo-random value in [0, 1) for each triple.
    static func hash(_ i: Int, _ j: Int, _ k: Int) -> Double {
        var h = UInt64(bitPattern: Int64((i &* 73_856_093) ^ (j &* 19_349_663) ^ (k &* 83_492_791)))
        h ^= h >> 33
        h &*= 0xFF51_AFD7_ED55_8CCD
        h ^= h >> 33
        h &*= 0xC4CE_B9FE_1A85_EC53
        h ^= h >> 33
        return Double(h % 10_000) / 10_000
    }

    /// Smooth value noise in [0, 1].
    static func noise(_ x: Double, _ y: Double) -> Double {
        let xi = Int(x.rounded(.down)), yi = Int(y.rounded(.down))
        let xf = x - x.rounded(.down), yf = y - y.rounded(.down)
        let u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf)
        let a = hash(xi, yi, 7), b = hash(xi + 1, yi, 7), c = hash(xi, yi + 1, 7), d = hash(xi + 1, yi + 1, 7)
        return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v
    }

    /// Density inside a fill: mostly sparse with denser patches, drifting with `t` (seconds). The noise is sampled
    /// on skewed axes and jittered per cell, so the patches don't line up into the triangles an ordered dither draws
    /// along a grid-aligned gradient.
    static func texture(_ column: Int, _ row: Int, t: Double, seed: Int) -> Double {
        let x = Double(column), y = Double(row)
        let broad = noise(x * 0.13 + y * 0.11 + t * 0.45 + Double(seed) * 11, y * 0.24 - x * 0.06 - t * 0.15)
        let fine = noise(x * 0.47 - y * 0.2 - t * 0.9, y * 0.5 + x * 0.17 + Double(seed) * 5)
        let n = min(max((0.65 * broad + 0.35 * fine - 0.3) / 0.45, 0), 1)
        return 0.06 + 0.7 * n * n * (3 - 2 * n) + (hash(column, row, seed) - 0.5) * 0.16
    }

    /// Seconds for drifting textures, kept small so the noise stays precise.
    static func time(_ date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
    }
}

extension GraphicsContext {
    /// A square cell `side` wide centered on `center`.
    func cell(_ center: CGPoint, _ side: CGFloat, _ color: Color) {
        fill(Path(CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)), with: .color(color))
    }
}

/// Draws `paint` twice: blurred underneath as a glow (added light in dark mode, a faint halo in light), then sharp.
/// `paint`'s last argument is true for the glow pass, which leaves out what shouldn't glow: unlit dots, tints.
/// `paint` gets the view's own size; the canvases reach `bleed` past it on every side, since a Canvas clips at its
/// bounds and cut the ring's outer cells, which straddle its frame, flat at the top, bottom and sides.
struct DitherCanvas: View {
    var glow: CGFloat = 3
    let paint: (GraphicsContext, CGSize, Bool) -> Void

    @Environment(\.colorScheme) private var scheme

    /// Room for cells over the frame's edge and their glow.
    private var bleed: CGFloat { 4 + glow * 3 }

    var body: some View {
        ZStack {
            layer(glow: true)
                .blur(radius: glow)
                .opacity(scheme == .dark ? 0.85 : 0.3)
                .blendMode(scheme == .dark ? .plusLighter : .normal)
            layer(glow: false)
        }
        .padding(-bleed)
    }

    private func layer(glow: Bool) -> some View {
        Canvas { [bleed] context, size in
            var context = context
            context.translateBy(x: bleed, y: bleed)
            paint(context, CGSize(width: size.width - 2 * bleed, height: size.height - 2 * bleed), glow)
        }
    }
}

/// A limit ring as two rows of cells around the circle: lit from `startBand` up into `endBand` at the leading tip
/// up to `fill`, a tail on to `ghost` for the pace projection that tapers from the tip into `endBand`, faint dots after. While `fill`
/// sweeps toward `target` its leading cells run hot; `warmth` (0 at rest → 1 on hover) pulls the tip gradient back
/// and brightens the pace ghost.
struct DitherRing: View, Animatable {
    var fill: Double
    var ghost: Double
    var warmth: Double
    let target: Double
    let startBand: Theme.Band
    let endBand: Theme.Band

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { AnimatablePair(AnimatablePair(fill, ghost), warmth) }
        set {
            fill = newValue.first.first
            ghost = newValue.first.second
            warmth = newValue.second
        }
    }

    private static let steps = 52

    var body: some View {
        let power = Theme.Band.tipPower(warmth: warmth)
        let paceHot = endBand > startBand
        let ghostColor = endBand.color
        let ghostOpacity = paceHot ? 0.78 + 0.17 * warmth : 0.85
        let span = max(fill, target)
        // The fill's leading color, which the pace tail starts from.
        let tipColor = Theme.Band.color(from: startBand, to: endBand, at: span > 0 ? min(fill / span, 1) : 0, power: power)
        DitherCanvas(glow: 2.5) { context, size, glow in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // On the circle the solid ring strokes, two rows straddling it within its 7pt width.
            let mid = min(size.width, size.height) / 2
            let sweeping = fill < target - 0.001
            for (row, radius) in [mid - 1.9, mid + 1.9].enumerated() {
                for step in 0..<Self.steps {
                    let at = (Double(step) + 0.5) / Double(Self.steps)
                    let angle = at * 2 * .pi - .pi / 2
                    let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                    let cell = Path(CGRect(x: -1.35, y: -1.35, width: 2.7, height: 2.7))
                        .applying(CGAffineTransform(translationX: point.x, y: point.y).rotated(by: angle))
                    if at <= fill {
                        let u = span > 0 ? min(at / span, 1) : 0
                        let color = Theme.Band.color(from: startBand, to: endBand, at: u, power: power)
                        let heat = sweeping ? max(0, 1 - (fill - at) / 0.08) : 0
                        if Dither.lit(step, row * 2, 0.86 + heat) {
                            context.fill(cell, with: .color(heat > 0 ? color.mix(with: .white, by: heat * 0.8) : color))
                        } else if !glow {
                            context.fill(cell, with: .color(color.opacity(0.35)))
                        }
                    } else if at <= ghost {
                        // A tail tapering from the tip: dense where it leaves the fill, the outer row giving out by
                        // about halfway and the inner thinning to the end. Cells are picked by hash, as a 4×4 Bayer
                        // threshold over two rows lights a fixed every-fourth cell.
                        let d = (at - fill) / (ghost - fill)
                        let density = row == 0
                            ? 0.08 + 0.92 * pow(1 - d, 1.4)
                            : 0.95 * pow(max(0, 1 - d * 1.8), 1.6)
                        if Dither.hash(step, row, 3) < density {
                            let color = tipColor.mix(with: ghostColor, by: min(1, d * 4))
                            context.fill(cell, with: .color(color.opacity(ghostOpacity * (1 - 0.4 * d))))
                        } else if !glow {
                            context.fill(cell, with: .color(ghostColor.opacity(0.12)))
                        }
                    } else if !glow {
                        context.cell(point, 1.4, .primary.opacity(0.16))
                    }
                }
            }
        }
    }
}

/// A day's column in cells: provider slices stacked bottom up, the column's top row and each slice's lit solid and
/// the rest a sparse texture, with faint dots over the chart above it. An empty day keeps a dotted baseline.
struct DitherColumn: View, Animatable {
    /// Provider colors with their share of the column, bottom of the stack first.
    let slices: [(color: Color, share: Double)]
    let height: CGFloat
    /// 0 folds the column to its baseline, 1 draws it at full height.
    var progress: Double
    /// Nil while no day is hovered; else whether this one is.
    let highlighted: Bool?
    /// Varies the texture from column to column.
    let seed: Int

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        DitherCanvas(glow: 2) { context, size, glow in
            let pitch = Dither.pitch
            let columns = max(1, Int(size.width / pitch)), rows = Int(size.height / pitch)
            let x0 = (size.width - CGFloat(columns) * pitch) / 2
            let filled = height > 0 && progress > 0.05 ? max(1, Int((height * progress / pitch).rounded())) : 0
            var owners: [Int] = []
            for (index, slice) in slices.enumerated() {
                owners += repeatElement(index, count: max(1, Int((Double(filled) * slice.share).rounded())))
            }
            owners = Array(owners.prefix(filled))
            while owners.count < filled, let last = owners.last { owners.append(last) }
            let dim = highlighted == false ? 0.45 : 1
            for row in 0..<rows {
                for column in 0..<columns {
                    let center = CGPoint(x: x0 + (CGFloat(column) + 0.5) * pitch, y: size.height - (CGFloat(row) + 0.5) * pitch)
                    guard row < owners.count else {
                        if !glow {
                            let baseline = owners.isEmpty && row == 0
                            context.cell(center, baseline ? 1.6 : 0.9, .primary.opacity(baseline ? 0.25 * progress : 0.08))
                        }
                        continue
                    }
                    let owner = owners[row]
                    var density = 0.12 + Dither.texture(seed * 5 + column, row, t: 0, seed: owner)
                    if row == owners.count - 1 {
                        density += 1
                    } else if owners[row + 1] != owner {
                        density += 0.55
                    }
                    if highlighted == true { density += 0.5 }
                    let color = slices[owner].color
                    if Dither.lit(column, row, density) {
                        context.cell(center, pitch * 0.7, color.opacity(dim))
                    } else if !glow {
                        context.cell(center, pitch * 0.34, color.opacity(0.3 * dim))
                    }
                }
            }
        }
    }
}

/// A list row's bar as one row of cells: lit up to `fraction`, faint dots after.
struct DitherLine: View, Animatable {
    var fraction: Double
    let color: Color

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let pitch = Dither.pitch
            let count = Int(size.width / pitch)
            let lit = fraction > 0 ? max(1, Int((Double(count) * min(fraction, 1)).rounded())) : 0
            for index in 0..<count {
                let center = CGPoint(x: (CGFloat(index) + 0.5) * pitch, y: size.height / 2)
                if index < lit {
                    context.cell(center, 2, color)
                } else {
                    context.cell(center, 1, .primary.opacity(0.12))
                }
            }
        }
        .frame(height: 3)
    }
}

/// The spend bar in cells: each provider's slice tinted, outlined and lit in a drifting dither, densest along the
/// bottom and its edges, with faint dots where nothing's filled yet. While `progress` sweeps in, the leading cells
/// run white hot. A highlighted slice lights up and the others dim.
struct DitherShareBar: View, Animatable {
    let slices: [(color: Color, share: Double)]
    var progress: Double
    let highlighted: Int?
    /// Seconds, drifting the texture.
    let t: Double
    /// While drifting, stray cells flash white.
    let live: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    static let pitch: CGFloat = 3.5

    var body: some View {
        DitherCanvas(glow: 3.5) { context, size, glow in draw(context, size, glow: glow) }
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize, glow: Bool) {
        var context = context
        let pitch = Self.pitch
        let columns = Int(size.width / pitch), rows = Int(size.height / pitch)
        let x0 = (size.width - CGFloat(columns) * pitch) / 2, y0 = (size.height - CGFloat(rows) * pitch) / 2
        var bounds = [0]
        var total = 0.0
        for slice in slices {
            total += slice.share
            bounds.append(Int((total * Double(columns)).rounded()))
        }
        let head = Double(bounds.last ?? 0) * progress
        let sweeping = progress < 1
        let outline = Self.outline(size)
        if !glow { context.stroke(outline, with: .color(.primary.opacity(0.1)), lineWidth: 1) }
        context.clip(to: outline)
        if !glow { Self.track(context, size, from: Int(head.rounded(.up))) }

        for (index, slice) in slices.enumerated() {
            let start = bounds[index], end = min(Double(bounds[index + 1]), head)
            guard end > Double(start) else { continue }
            let picked = highlighted == index
            let dim = highlighted == nil || picked ? 1 : 0.32
            let rect = CGRect(x: x0 + CGFloat(start) * pitch, y: 0, width: CGFloat(end - Double(start)) * pitch, height: size.height)
            if !glow { context.fill(Path(rect), with: .color(slice.color.opacity((picked ? 0.2 : 0.12) * dim))) }
            for column in start..<Int(end.rounded(.up)) {
                let heat = sweeping ? max(0, 1 - (head - Double(column)) / 8) : 0
                for row in 0..<rows {
                    var density = Dither.texture(column, row, t: t, seed: index)
                    if row == rows - 1 { density += 0.75 } else if row == 0 { density += 0.45 }
                    if column == start || column == bounds[index + 1] - 1 { density += 0.18 }
                    if picked { density += 0.28 }
                    density += heat * 1.1
                    let center = CGPoint(x: x0 + (CGFloat(column) + 0.5) * pitch, y: y0 + (CGFloat(row) + 0.5) * pitch)
                    let spark = live && Dither.hash(column, row, Int(t * 6)) > 0.9965
                    if spark || Dither.lit(column, row, density) {
                        let color: Color = spark ? .white : heat > 0 ? slice.color.mix(with: .white, by: heat * 0.85) : slice.color
                        context.cell(center, pitch * 0.62, color.opacity(0.95 * dim))
                    } else if !glow {
                        context.cell(center, pitch * 0.3, slice.color.opacity(0.22 * dim))
                    }
                }
            }
            let edge = sweeping && Double(bounds[index + 1]) > head ? slice.color.mix(with: .white, by: 0.7) : slice.color
            context.stroke(outline.intersection(Path(rect.insetBy(dx: 0.6, dy: 0))), with: .color(edge.opacity(0.95 * dim)),
                           lineWidth: 1.2)
        }
        if sweeping, glow, head > 0 {
            let x = x0 + CGFloat(head) * pitch
            context.fill(Path(CGRect(x: x - 14, y: 0, width: 14, height: size.height)), with: .color(.white.opacity(0.55)))
        }
    }

    static func outline(_ size: CGSize) -> Path {
        RoundedRectangle(cornerRadius: 8).path(in: CGRect(origin: .zero, size: size).insetBy(dx: 0.6, dy: 0.6))
    }

    /// Faint dots from `first` on, where no slice is filled.
    static func track(_ context: GraphicsContext, _ size: CGSize, from first: Int) {
        let columns = Int(size.width / pitch), rows = Int(size.height / pitch)
        let x0 = (size.width - CGFloat(columns) * pitch) / 2, y0 = (size.height - CGFloat(rows) * pitch) / 2
        for column in max(first, 0)..<max(columns, first) {
            for row in 0..<rows {
                context.cell(CGPoint(x: x0 + (CGFloat(column) + 0.5) * pitch, y: y0 + (CGFloat(row) + 0.5) * pitch),
                             pitch * 0.3, .primary.opacity(0.09))
            }
        }
    }
}

/// The spend bar's empty track while the logs are first read: a hot band sweeps across and starts over.
struct DitherScan: View {
    let t: Double
    let scanning: Bool

    private static let band = 16.0

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let hot: Color = scheme == .dark ? .white : .primary
        return DitherCanvas(glow: 3.5) { context, size, glow in
            var context = context
            let pitch = DitherShareBar.pitch
            let columns = Int(size.width / pitch), rows = Int(size.height / pitch)
            let x0 = (size.width - CGFloat(columns) * pitch) / 2, y0 = (size.height - CGFloat(rows) * pitch) / 2
            let outline = DitherShareBar.outline(size)
            if !glow {
                context.stroke(outline, with: .color(.primary.opacity(0.1)), lineWidth: 1)
                DitherShareBar.track(context, size, from: 0)
            }
            guard scanning else { return }
            context.clip(to: outline)
            let head = (t / 1.6).truncatingRemainder(dividingBy: 1) * (Double(columns) + Self.band)
            for column in max(0, Int(head - Self.band))..<min(columns, Int(head.rounded(.up))) {
                let heat = max(0, 1 - (head - Double(column)) / Self.band)
                for row in 0..<rows where Dither.lit(column, row, heat * 1.1 + (row == rows - 1 ? 0.4 : 0)) {
                    context.cell(CGPoint(x: x0 + (CGFloat(column) + 0.5) * pitch, y: y0 + (CGFloat(row) + 0.5) * pitch),
                                 pitch * 0.62, hot.opacity(0.9 * heat))
                }
            }
        }
    }
}
