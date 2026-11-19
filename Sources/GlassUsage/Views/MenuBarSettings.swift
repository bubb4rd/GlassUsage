import AppKit
import SwiftUI

/// The ring, or the icon when there are several, Settings' menu bar editor is changing.
struct RingSelection: Equatable {
    var icon = 0
    var slot: RingSlot = .outer
}

/// Settings' menu bar rings: presets drawn as the menu bar would show them, then the layout's rings (or icons).
/// Clicking one opens its provider, window, model group and percentage below; clicking it again closes them, so
/// the section stays short until something is being changed. Edits show in the menu bar at once.
extension SettingsView {
    @ViewBuilder
    var menuBarRings: some View {
        let tracked = store.settings.enabledProviders
        if tracked.isEmpty {
            Text("Turn on a provider")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        } else {
            ringTiles(tracked: tracked)
            divider
            ringButtons(tracked: tracked)
            if let picked = selection(in: store.settings.menuBarLayout) {
                ringInspector(tracked: tracked, icon: picked.icon, slot: picked.slot)
            }
        }
    }

    /// The selection fitted to `layout`: with one icon a ring of it, with several an icon (no slot). Nil while
    /// nothing is being edited.
    private func selection(in layout: MenuBarLayout) -> (icon: Int, slot: RingSlot?)? {
        guard let ringSelection else { return nil }
        guard layout.icons.count == 1 else { return (min(ringSelection.icon, layout.icons.count - 1), nil) }
        return (0, layout.icons[0].inner == nil ? .outer : ringSelection.slot)
    }

    /// Opens or closes the editing rows, resizing the panel with them.
    private func select(_ selection: RingSelection?) {
        withAnimation(UsagePanelView.resize) { ringSelection = selection }
    }

    private func editIcon(_ index: Int, _ change: (inout MenuBarIcon) -> Void) {
        store.settings.editMenuBarLayout { change(&$0.icons[index]) }
    }

    // MARK: Presets

    /// The presets, and the custom layout when there is one, each as a slice of menu bar with live readings.
    private func ringTiles(tracked: [ProviderID]) -> some View {
        let settings = store.settings
        let layout = settings.menuBarLayout
        let presets = layout.presets(tracked: tracked)
        func isPreset(_ candidate: MenuBarLayout) -> Bool { presets.contains { $0.layout == candidate } }
        let custom = isPreset(layout) ? settings.customMenuBarLayout.flatMap { isPreset($0) ? nil : $0 } : layout
        let tiles: [(label: String, layout: MenuBarLayout)] =
            presets.map { ($0.preset.label, $0.layout) } + (custom.map { [("Custom", $0)] } ?? [])

        return VStack(alignment: .leading, spacing: 0) {
            Text("Rings")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.leading, 12)
                .padding(.top, 8)
            // One row: full size when it fits, a little smaller when it doesn't, and wrapping only when even the
            // smaller tiles are too wide (a wide custom layout).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { ForEach(tiles, id: \.label) { ringTile($0.label, $0.layout, selected: $0.layout == layout) } }
                HStack(spacing: 4) {
                    ForEach(tiles, id: \.label) { ringTile($0.label, $0.layout, selected: $0.layout == layout, scale: 0.8) }
                }
                FlowLayout { ForEach(tiles, id: \.label) { ringTile($0.label, $0.layout, selected: $0.layout == layout) } }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `scale` shrinks the slice of menu bar with its padding, for a row that doesn't fit at full size.
    private func ringTile(_ label: String, _ layout: MenuBarLayout, selected: Bool, scale: CGFloat = 1) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9 * scale)
        let image = StatusIcon.image(store.menuBarIcons(layout))
        return Button {
            store.settings.menuBarLayout = layout
            select(nil)
        } label: {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .frame(width: image.size.width * scale, height: image.size.height * scale)
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 7 * scale)
                .frame(height: 28 * scale)
                .background(shape.fill(Color(red: 40 / 255, green: 40 / 255, blue: 60 / 255).opacity(0.65)))
                .overlay { shape.strokeBorder(.white.opacity(selected ? 0.4 : 0.08), lineWidth: selected ? 1 : 0.5) }
                .opacity(selected ? 1 : 0.6)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pointingHand()
        .help(label)
        .accessibilityLabel("\(label) menu bar rings")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Rings

    /// With one icon its rings, otherwise the icons; then a button to add a ring or an icon.
    private func ringButtons(tracked: [ProviderID]) -> some View {
        let settings = store.settings
        let layout = settings.menuBarLayout
        let selected = selection(in: layout)
        let shape = RoundedRectangle(cornerRadius: 9)

        return FlowLayout(spacing: 5) {
            if layout.icons.count == 1 {
                let icon = layout.icons[0]
                ForEach([RingSlot.outer, .inner].filter { icon[$0] != nil }, id: \.self) { slot in
                    let source = icon[slot]!
                    RingButton(glyph: StatusIcon.glyph(outer: .init(fraction: 0.68, dimmed: slot != .outer),
                                                       inner: icon.inner.map { _ in .init(fraction: 0.42, dimmed: slot != .inner) }),
                               providers: [source.provider], tracked: tracked, label: source.window.label,
                               selected: slot == selected?.slot,
                               help: "\(slot == .outer ? "Outer" : "Inner") ring: \(source.provider.displayName) \(source.window.label.lowercased())",
                               onSelect: { select(selected?.slot == slot ? nil : RingSelection(icon: 0, slot: slot)) },
                               onRemove: icon.inner == nil ? nil : {
                                   editIcon(0) { $0.removeRing(slot) }
                                   select(nil)
                               })
                }
            } else {
                ForEach(layout.icons.indices, id: \.self) { index in
                    let icon = layout.icons[index]
                    let providers = icon.providers
                    RingButton(glyph: StatusIcon.glyph(outer: .init(fraction: 0.68),
                                                       inner: icon.inner.map { _ in .init(fraction: 0.42) }),
                               providers: providers, tracked: tracked, label: nil, selected: index == selected?.icon,
                               help: "Icon \(index + 1): \(providers.map(\.displayName).joined(separator: " and "))",
                               onSelect: { select(selected?.icon == index ? nil : RingSelection(icon: index)) },
                               onRemove: {
                                   settings.editMenuBarLayout { $0.removeIcon(at: index) }
                                   select(nil)
                               })
                }
            }
            if layout.canAdd {
                let addsRing = layout.icons.count == 1 && layout.icons[0].inner == nil
                Button {
                    var added: Int?
                    settings.editMenuBarLayout { added = $0.add(tracked: tracked) }
                    if let added { select(RingSelection(icon: added, slot: addsRing ? .inner : .outer)) }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 26)
                        .background(shape.strokeBorder(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 0.75, dash: [2.5, 2])))
                        .contentShape(shape)
                }
                .buttonStyle(.plain)
                .pointingHand()
                .help(addsRing ? "Add a ring inside" : "Add an icon")
                .accessibilityLabel(addsRing ? "Add a ring inside" : "Add an icon")
            }
        }
        .padding(8)
    }

    // MARK: Picked ring

    /// The picked ring's (or icon's) provider, window, model group and percentage.
    @ViewBuilder
    private func ringInspector(tracked: [ProviderID], icon index: Int, slot: RingSlot?) -> some View {
        let layout = store.settings.menuBarLayout
        let icon = layout.icons[index]
        let source = slot.flatMap { icon[$0] } ?? icon.outer
        let groups = store.state(for: source.provider).snapshot?.groups ?? []

        divider
        row("Provider") {
            HStack(spacing: 4) {
                ForEach(tracked) { provider in
                    let on = provider == source.provider
                    Button {
                        editIcon(index) { icon in
                            if let slot { icon.setProvider(provider, slot: slot) } else { icon.setProvider(provider) }
                        }
                    } label: {
                        ProviderLogo(provider: provider, size: 13)
                            .opacity(on ? 1 : 0.55)
                            .frame(width: 28)
                            .chip(selected: on, outlined: true)
                    }
                    .buttonStyle(.plain)
                    .help(provider.displayName)
                    .accessibilityLabel(provider.displayName)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        divider
        row("Window") {
            if let slot {
                PillPicker(options: RingWindow.allCases.map { ($0, $0.label) }, selection: Binding(
                    get: { source.window },
                    set: { window in editIcon(index) { $0.setWindow(window, slot: slot) } }))
            } else {
                PillPicker(options: IconSpan.allCases.map { (Optional($0), $0.label) }, selection: Binding(
                    get: { icon.span },
                    set: { span in if let span { editIcon(index) { $0.setSpan(span) } } }))
            }
        }
        .help("Week is the month on Codex plans that have one. Closest follows whichever window is nearer its limit.")
        if groups.count > 1 {
            divider
            row("Models") {
                menuPicker([(nil, "Closest to limit")] + groups.map { ($0, $0) }, selection: Binding(
                    get: { source.group.flatMap { groups.contains($0) ? $0 : nil } },
                    set: { group in
                        editIcon(index) { icon in
                            if let slot { icon.setGroup(group, slot: slot) } else { icon.setGroup(group) }
                        }
                    }), help: "The \(source.provider.displayName) model group this ring reads")
            }
        }
        divider
        row("Percentage") {
            menuPicker(percentOptions(icon), selection: Binding(
                get: { icon.percent },
                set: { percent in editIcon(index) { $0.percent = percent } }), help: "The percentage beside this icon")
        }
    }

    /// With one ring, on or off. With two, each ring named by its provider when they differ, else by its window.
    private func percentOptions(_ icon: MenuBarIcon) -> [(value: IconPercent, label: String)] {
        guard let inner = icon.inner else { return [(.off, "Off"), (.highest, "On")] }
        let outer = icon.outer
        let names: (String, String) = if outer.provider != inner.provider {
            (outer.provider.displayName, inner.provider.displayName)
        } else if outer.window != inner.window {
            (outer.window.label, inner.window.label)
        } else {
            ("Outer", "Inner")
        }
        return [(.off, "Off"), (.highest, "Highest"), (.outer, names.0), (.inner, names.1), (.both, "Both")]
    }
}

/// A ring (or an icon) of the menu bar layout: the glyph with it lit, its providers, and its window. Hovering offers
/// an × that takes it away.
private struct RingButton: View {
    let glyph: NSImage
    let providers: [ProviderID]
    let tracked: [ProviderID]
    let label: String?
    let selected: Bool
    let help: String
    let onSelect: () -> Void
    let onRemove: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 5) {
                Image(nsImage: glyph).renderingMode(.template).opacity(selected ? 1 : 0.6)
                ForEach(providers) { provider in
                    // A provider that isn't tracked has nothing to draw; its ring stays empty.
                    ProviderLogo(provider: provider, size: 11).opacity(tracked.contains(provider) ? 1 : 0.4)
                }
                if let label { Text(label) }
            }
            .padding(.leading, 6)
            .padding(.trailing, label == nil ? 7 : 9)
            .chip(selected: selected, outlined: true)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if hovering, let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(.regularMaterial))
                        .overlay(Circle().strokeBorder(Theme.fill2, lineWidth: 0.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointingHand()
                .offset(x: 4, y: -4)
                .help("Remove")
                .transition(.opacity)
            }
        }
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityActions {
            if let onRemove { Button("Remove", action: onRemove) }
        }
    }
}
