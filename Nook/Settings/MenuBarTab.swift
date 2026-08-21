// MenuBarTab.swift
// The layout editor: three borderless section regions (de-box — soft fills,
// no 1px borders), populated with the REAL icons (chooser shows the actual
// artifact). Direct manipulation: drag chips between and within sections;
// order applies automatically (smart default — no Apply button).

import NookCore
import NookEngine
import SwiftUI

struct MenuBarTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        // No own ScrollView — the settings shell provides scrolling + padding.
        VStack(alignment: .leading, spacing: 14) {
            if !appState.engineCanHide {
                    Label(
                        "Hiding is unavailable on this macOS build — reordering still works.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                }

                HStack {
                    Picker("", selection: Binding(
                        get: { appState.settings.editorIconStyle },
                        set: { style in
                            appState.settings.editorIconStyle = style
                            appState.settingsChanged()
                        }
                    )) {
                        Text("App icons").tag(EditorIconStyle.appIcons)
                        Text("Menu bar icons").tag(EditorIconStyle.barIcons)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Menu bar icons show the actual glyphs from your bar — requires Screen Recording access, captured only while items are revealed.")
                    Spacer()
                    Button {
                        appState.tidyBar()
                    } label: {
                        Label(
                            appState.tidying ? "Tidying…" : "Tidy bar order",
                            systemImage: "wand.and.stars"
                        )
                        .font(.callout)
                    }
                    .disabled(appState.tidying)
                    .help("Physically arranges the bar to match the sections — icons that sit out of place slide their neighbors on every reveal.")
                }

                EditorSectionView(
                    section: .visible,
                    title: "Visible",
                    caption: "Always in the menu bar",
                    symbol: "eye"
                )
                EditorSectionView(
                    section: .hidden,
                    title: "Hidden",
                    caption: "A hover or click away — or ⌘-drag icons left of the chevron",
                    symbol: "eye.slash"
                )
                EditorSectionView(
                    section: .alwaysHidden,
                    title: "Always Hidden",
                    caption: "Out of sight until you double-click or ⌥-click the chevron",
                    symbol: "moon"
                )

                NookItemsStrip()
                    .padding(.top, 6)

                SeparatorStrip()
        }
        .animation(.spring(duration: 0.3), value: appState.settings.sectionModel)
        // Editing the bar shows the bar: reveal everything while this tab is
        // open so drags in the editor and in the real menubar stay in sync.
        .onAppear {
            appState.reveal([.hidden, .alwaysHidden], reason: .settingsPreview)
        }
        .onDisappear {
            // Same rule as settings-close: the pointer display's policy wins —
            // an unconditional conceal collapsed always-show displays.
            if appState.pointerDisplayBehavior == .alwaysShowAll {
                appState.reveal([.hidden], reason: .displayPolicy)
            } else {
                appState.concealNow()
            }
        }
    }
}

// MARK: - Section region

private struct EditorSectionView: View {
    @Environment(AppState.self) private var appState
    let section: NookCore.Section
    let title: String
    let caption: String
    let symbol: String

    private var items: [ObservedItem] {
        appState.editorItems(in: section)
    }

    @State private var rowTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            FlowLayout(spacing: 6) {
                // iconStyle is passed down so the tiles re-render on toggle —
                // reading it only inside the image cache invalidates nothing.
                ForEach(items, id: \.id.rawValue) { item in
                    ItemTile(
                        item: item,
                        section: section,
                        iconStyle: appState.settings.editorIconStyle
                    )
                }
                // Trailing landing slot: appears while a chip hovers the row
                // itself (append position).
                if rowTargeted {
                    LandingSlot()
                }
                if items.isEmpty, !rowTargeted {
                    Text("Drop icons here")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary.opacity(rowTargeted ? 0.8 : (section == .visible ? 0.35 : 0.55)))
            )
            .animation(.spring(duration: 0.25), value: rowTargeted)
            .dropDestination(for: String.self) { dropped, _ in
                guard let raw = dropped.first else { return false }
                appState.moveItem(ItemID(rawValue: raw), to: section, before: nil)
                return true
            } isTargeted: { targeting in
                rowTargeted = targeting
            }
        }
    }
}

/// Animated placeholder showing where a dragged chip will land.
private struct LandingSlot: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(.tint.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(.tint.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            )
            .frame(width: 34, height: 34)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}

// MARK: - Icon tile

private struct ItemTile: View {
    @Environment(AppState.self) private var appState
    let item: ObservedItem
    let section: NookCore.Section
    let iconStyle: EditorIconStyle
    @State private var hovered = false
    @State private var targeted = false

    private var displayName: String {
        if item.id.rawValue.contains("Nook.Separator") {
            return "Separator"
        }
        if item.id.rawValue.contains("::com.apple.menuextra.") {
            let suffix = item.id.rawValue.components(separatedBy: ".").last ?? "System"
            return suffix.replacingOccurrences(of: "-", with: " ").capitalized
        }
        return item.appName ?? item.id.bundleID?.components(separatedBy: ".").last ?? "?"
    }

    private var isSystemIcon: Bool {
        EngineGoldenGate.systemItem(for: item.id) != nil
    }

    /// Same-bundle siblings hide together (assertion granularity is per
    /// bundle) — surface that with a link badge instead of hiding the fact.
    /// System icons are exempt: they share the agent's bundle but hide
    /// individually via the system allowlist.
    private var hasBundleSiblings: Bool {
        // Nook's own items (extras, separators) hide individually.
        guard !isSystemIcon, let bundle = item.id.bundleID,
              bundle != Bundle.main.bundleIdentifier else { return false }
        return (appState.snapshot?.items ?? []).contains {
            $0.id != item.id && $0.id.bundleID == bundle
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let icon = ItemImageCache.icon(for: item.id) {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "app.dashed")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 20, height: 20)
                .padding(7)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(.background.opacity(hovered ? 1 : 0.65))
                        .shadow(color: .black.opacity(hovered ? 0.18 : 0.08), radius: hovered ? 4 : 2, y: 1)
                )
                if hasBundleSiblings {
                    Image(systemName: "link")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(2)
                        .background(Circle().fill(.background))
                        .offset(x: 4, y: -4)
                        .help("Icons from the same app hide together")
                }
                if isSystemIcon {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(2)
                        .background(Circle().fill(.background))
                        .offset(x: 4, y: -4)
                        .help("System icon — Nook places it; whether it exists in the bar is set in System Settings › Control Center")
                }
            }
            Text(displayName)
                .font(.system(size: 9))
                .foregroundStyle(hovered ? .secondary : .tertiary)
                .lineLimit(1)
                .frame(maxWidth: 52)
        }
        .onHover { hovered = $0 }
        // Insertion gap: the tile slides right and an accent bar marks where
        // the dragged chip will land (before this tile).
        .padding(.leading, targeted ? 16 : 0)
        .overlay(alignment: .leading) {
            if targeted {
                Capsule()
                    .fill(.tint)
                    .frame(width: 3, height: 34)
                    .offset(x: 5, y: -7)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.22), value: targeted)
        .draggable(item.id.rawValue)
        .dropDestination(for: String.self) { dropped, _ in
            guard let raw = dropped.first, raw != item.id.rawValue else { return false }
            appState.moveItem(ItemID(rawValue: raw), to: section, before: item.id)
            return true
        } isTargeted: { targeting in
            targeted = targeting
        }
    }
}

// MARK: - Nook items

/// Nook's own proxy items — they bypass the OS limitation that hides system
/// extras under assertions, because Nook controls their visibility directly.
private struct NookItemsStrip: View {
    @Environment(AppState.self) private var appState
    @State private var shortcutNames: [String] = []

    private func hasKind(_ kind: ExtraKind) -> Bool {
        appState.settings.extraItems.contains { $0.kind == kind }
    }

    private func toggleKind(_ kind: ExtraKind, on: Bool) {
        if on, !hasKind(kind) {
            appState.settings.extraItems.append(ExtraItemSpec(kind: kind))
        } else if !on {
            appState.settings.extraItems.removeAll { $0.kind == kind }
        }
        appState.settingsChanged()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Nook items")
                    .font(.headline)
                Text("Nook-made stand-ins for the system extras — these live in any section")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Menu {
                    if shortcutNames.isEmpty {
                        Text("No shortcuts in your library")
                    }
                    ForEach(shortcutNames, id: \.self) { name in
                        Button(name) {
                            appState.settings.extraItems.append(
                                ExtraItemSpec(kind: .shortcut, shortcutName: name, symbol: "bolt.fill")
                            )
                            appState.settingsChanged()
                        }
                    }
                } label: {
                    Label("Shortcut", systemImage: "plus")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .onAppear {
                    Task.detached {
                        let names = ExtrasManager.availableShortcuts()
                        await MainActor.run { shortcutNames = names }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                NookItemRow(
                    symbol: "playpause.fill", title: "Media controls",
                    caption: "Shows while audio plays (lingers a few minutes after) — click plays/pauses, right-click for tracks",
                    isOn: hasKind(.mediaControls)
                ) { toggleKind(.mediaControls, on: $0) }
                NookItemRow(
                    symbol: "video.fill", title: "Camera & mic indicator",
                    caption: "Exists only while a camera or mic is live — its section just decides where it appears",
                    isOn: hasKind(.cameraMicIndicator)
                ) { toggleKind(.cameraMicIndicator, on: $0) }
                NookItemRow(
                    symbol: ExtrasManager.airdropSymbol, title: "AirDrop",
                    caption: "Opens Finder's AirDrop view",
                    isOn: hasKind(.airdrop)
                ) { toggleKind(.airdrop, on: $0) }
                ForEach(appState.settings.extraItems.filter { $0.kind == .shortcut }) { spec in
                    HStack(spacing: 8) {
                        Image(systemName: spec.symbol ?? "bolt.fill")
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        Text(spec.shortcutName ?? "Shortcut")
                            .font(.callout)
                        Text("Runs your shortcut")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button {
                            appState.settings.extraItems.removeAll { $0.id == spec.id }
                            appState.settingsChanged()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.35)))
        }
    }
}

private struct NookItemRow: View {
    let symbol: String
    let title: String
    let caption: String
    let isOn: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: onToggle))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Separators

private struct SeparatorStrip: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "divide")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Separators")
                    .font(.headline)
                Text("Decorative dividers you can ⌘-drag anywhere in the bar")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    appState.settings.separators.append(SeparatorSpec(style: .dot))
                    appState.settingsChanged()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a separator")
            }

            if !appState.settings.separators.isEmpty {
                HStack(spacing: 8) {
                    ForEach($state.settings.separators) { $separator in
                        SeparatorChip(separator: $separator) {
                            appState.settings.separators.removeAll { $0.id == separator.id }
                            appState.settingsChanged()
                        }
                    }
                    Spacer()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.35)))
            }
        }
    }
}

private struct SeparatorChip: View {
    @Environment(AppState.self) private var appState
    @Binding var separator: SeparatorSpec
    let onDelete: () -> Void
    @State private var showsChooser = false
    @State private var hovered = false

    var body: some View {
        Button {
            showsChooser = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Text(separator.style == .space ? "␣" : separator.style.rawValue)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(separator.style == .space ? .tertiary : .secondary)
                    .opacity(separator.style == .space ? 1 : max(separator.opacity, 0.25))
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(.background.opacity(0.8))
                            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                    )
                if hovered {
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .popover(isPresented: $showsChooser, arrowEdge: .bottom) {
            // The chooser renders the real glyphs, current one ring-selected.
            VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(SeparatorStyle.allCases, id: \.self) { style in
                    Button {
                        separator.style = style
                        appState.settingsChanged()
                    } label: {
                        Text(style == .space ? "␣" : style.rawValue)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.quaternary.opacity(separator.style == style ? 0.8 : 0.3))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.tint, lineWidth: separator.style == style ? 1.5 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(style.displayName)
                }
            }
            if separator.style != .space {
                HStack(spacing: 8) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { separator.opacity },
                        set: { value in
                            separator.opacity = value
                            appState.settingsChanged()
                        }
                    ), in: 0.1...1)
                    Text("\(Int(separator.opacity * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                .help("Separator opacity in the menu bar")
            }
            }
            .padding(10)
            .frame(width: 240)
        }
    }
}

// MARK: - Flow layout

/// Minimal wrapping layout for icon tiles.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
