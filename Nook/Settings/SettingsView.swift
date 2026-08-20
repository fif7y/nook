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
            MenuBarTab()
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
                Toggle(isOn: binding(\.showStatusItem, onSet: { enabled in
                    if !enabled { Self.showIconlessHint() }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Nook icon in the menu bar")
                        Text("Without it: reopen Nook from Spotlight, right-click a separator, or right-click an empty spot in the menu bar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Reveal") {
                Toggle("Reveal on hover", isOn: binding(\.revealTriggers.hoverEnabled))
                if appState.settings.revealTriggers.hoverEnabled {
                    LabeledSlider(
                        title: "Hover delay",
                        value: binding(\.revealTriggers.hoverDelay),
                        range: 0...0.5,
                        format: "%.1fs",
                        zeroLabel: "Instant"
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
                        range: 0...10,
                        format: "%.2gs",
                        zeroLabel: "Instant"
                    )
                }
                Toggle("Rehide when clicking elsewhere", isOn: binding(\.rehideOnClickElsewhere))
            }

            Section {
                Picker(selection: binding(\.hideSystemExtras)) {
                    Text("Always hidden — steadiest bar").tag(true)
                    Text("Show while everything is revealed").tag(false)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("System extras")
                        Text("Now Playing, camera controls, AirDrop, Focus")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("macOS hides these whenever any icons are concealed — they can only ever appear while the whole bar is revealed (double-click, or ⌥-click the chevron).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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

    /// One-time orientation when the user goes iconless.
    static func showIconlessHint() {
        let alert = NSAlert()
        alert.messageText = "Nook stays a click away"
        alert.informativeText = "You can always open Nook Settings by:\n\n•  Opening Nook again from Spotlight or Finder\n•  Right-clicking any Nook separator in the menu bar\n•  Right-clicking an empty spot in the menu bar"
        alert.alertStyle = .informational
        alert.runModal()
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: TimeInterval
    let range: ClosedRange<Double>
    let format: String
    var zeroLabel: String? = nil

    var body: some View {
        HStack {
            Text(title)
            Slider(value: $value, in: range)
            Text(value == 0 ? (zeroLabel ?? String(format: format, value)) : String(format: format, value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
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
