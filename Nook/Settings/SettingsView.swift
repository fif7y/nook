// SettingsView.swift
// Three tabs, no more: General / Menu Bar / Displays. Functional first pass —
// the full design treatment lands with M4 (layout editor) and M6 (onboarding).

import NookCore
import NookEngine
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            MenuBarSettingsTab()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            DisplaysSettingsTab()
                .tabItem { Label("Displays", systemImage: "display.2") }
        }
        .frame(width: 560)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        Form {
            Section {
                Toggle("Launch at login", isOn: binding(\.launchAtLogin) { enabled in
                    try? enabled
                        ? SMAppService.mainApp.register()
                        : SMAppService.mainApp.unregister()
                })
                Toggle("Show Nook icon in the menu bar", isOn: binding(\.showStatusItem))
            }

            Section("Reveal") {
                Toggle("Reveal on hover", isOn: binding(\.revealTriggers.hoverEnabled))
                if appState.settings.revealTriggers.hoverEnabled {
                    LabeledSlider(
                        title: "Hover delay",
                        value: binding(\.revealTriggers.hoverDelay),
                        range: 0...1,
                        format: "%.1fs"
                    )
                }
                Toggle("Reveal on click in empty menu bar area", isOn: binding(\.revealTriggers.clickEnabled))
                Toggle("Double-click reveals always-hidden too", isOn: binding(\.revealTriggers.doubleClickForAlwaysHidden))
            }

            Section("Auto-rehide") {
                Toggle("Automatically rehide", isOn: binding(\.autoRehide))
                if appState.settings.autoRehide {
                    LabeledSlider(
                        title: "After",
                        value: binding(\.rehideDelay),
                        range: 1...30,
                        format: "%.0fs"
                    )
                }
                Toggle("Rehide when clicking elsewhere", isOn: binding(\.rehideOnClickElsewhere))
            }

            Section("New items") {
                Picker("New menu bar items go to", selection: binding(\.sectionModel.newItemsDestination)) {
                    Text("Visible").tag(NookCore.Section.visible)
                    Text("Hidden").tag(NookCore.Section.hidden)
                    Text("Always hidden").tag(NookCore.Section.alwaysHidden)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding<T>(
        _ keyPath: WritableKeyPath<SettingsStore, T>,
        onSet: ((T) -> Void)? = nil
    ) -> Binding<T> {
        Binding(
            get: { appState.settings[keyPath: keyPath] },
            set: { newValue in
                appState.settings[keyPath: keyPath] = newValue
                onSet?(newValue)
                appState.settingsChanged()
            }
        )
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: TimeInterval
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        HStack {
            Text(title)
            Slider(value: $value, in: range)
            Text(String(format: format, value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

// MARK: - Menu Bar (layout editor — functional skeleton, designed pass in M4)

struct MenuBarSettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !appState.engineCanHide {
                    Label(
                        "Hiding is unavailable on this macOS build. Reordering still works.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
                ForEach([NookCore.Section.visible, .hidden, .alwaysHidden], id: \.self) { section in
                    SectionRow(section: section)
                }
            }
            .padding(20)
        }
    }
}

struct SectionRow: View {
    @Environment(AppState.self) private var appState
    let section: NookCore.Section

    private var title: String {
        switch section {
        case .visible: "Visible"
        case .hidden: "Hidden"
        case .alwaysHidden: "Always Hidden"
        }
    }

    private var items: [ObservedItem] {
        (appState.snapshot?.items ?? []).filter {
            !$0.id.isSystemModule
                && $0.id.bundleID != Bundle.main.bundleIdentifier
                && appState.settings.sectionModel.section(of: $0.id) == section
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            HStack(spacing: 6) {
                if items.isEmpty {
                    Text("Drop items here")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(items, id: \.id.rawValue) { item in
                        ItemChip(item: item)
                            .draggable(item.id.rawValue)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .frame(minHeight: 44)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .dropDestination(for: String.self) { dropped, _ in
                guard let raw = dropped.first else { return false }
                let id = ItemID(rawValue: raw)
                if section == .visible {
                    appState.settings.sectionModel.assignments.removeValue(forKey: id)
                } else {
                    appState.settings.sectionModel.assignments[id] = section
                }
                appState.settingsChanged()
                return true
            }
        }
    }
}

struct ItemChip: View {
    let item: ObservedItem

    var body: some View {
        Text(item.appName ?? item.id.bundleID?.components(separatedBy: ".").last ?? "?")
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.background.secondary, in: Capsule())
    }
}

// MARK: - Displays

struct DisplaysSettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            ForEach(NSScreen.screens, id: \.self) { screen in
                DisplayRow(screen: screen)
            }
        }
        .formStyle(.grouped)
    }
}

struct DisplayRow: View {
    @Environment(AppState.self) private var appState
    let screen: NSScreen

    private var uuid: String? {
        guard
            let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber,
            let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private var hasNotch: Bool {
        screen.safeAreaInsets.top > 0
    }

    var body: some View {
        Picker(selection: Binding(
            get: { appState.settings.behavior(forDisplayUUID: uuid) },
            set: { behavior in
                if let uuid {
                    appState.settings.displayOverrides[uuid] = behavior
                    appState.settingsChanged()
                }
            }
        )) {
            Text("Collapse into Nook").tag(DisplayBehavior.collapse)
            Text("Always show everything").tag(DisplayBehavior.alwaysShowAll)
        } label: {
            HStack {
                Text(screen.localizedName)
                if hasNotch {
                    Text("Notch")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
    }
}
