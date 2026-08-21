// SettingsView.swift
// Sidebar-shell settings: tab list on the left, one scrolling pane on the
// right. De-box throughout — panes are borderless cards on soft fills, the
// amber accent carries selection and controls. About pane included.

import NookCore
import NookEngine
import ServiceManagement
import SwiftUI

/// The nook amber — same accent the onboarding uses.
enum NookAccent {
    static let amber = Color(red: 1.0, green: 0.62, blue: 0.28)
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case menuBar = "Menu Bar"
    case displays = "Displays"
    case about = "About"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .menuBar: "menubar.rectangle"
        case .displays: "display.2"
        case .about: "shippingbox"
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var tab: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(tab: $tab)
            content
        }
        .frame(minWidth: 720, minHeight: 520)
        .tint(NookAccent.amber)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(tab.rawValue)
                    .font(.system(size: 22, weight: .semibold))
                    .padding(.bottom, 2)
                switch tab {
                case .general: GeneralPane()
                case .menuBar: MenuBarTab()
                case .displays: DisplaysPane()
                case .about: AboutPane()
                }
            }
            .padding(24)
            .padding(.top, 14)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var tab: SettingsTab

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.allCases) { item in
                SidebarRow(item: item, selected: tab == item) { tab = item }
            }
            Spacer()
        }
        .padding(10)
        // Clear the traffic lights — the sidebar runs under the titlebar.
        .padding(.top, 42)
        .frame(width: 178, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(.quaternary.opacity(0.35))
    }
}

private struct SidebarRow: View {
    let item: SettingsTab
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(item.rawValue)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? NookAccent.amber : .primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected
                        ? NookAccent.amber.opacity(0.16)
                        : .primary.opacity(hovered ? 0.06 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
    }
}

// MARK: - Card + rows

/// Borderless grouping card: soft fill, no outline (de-box).
struct SettingsCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.35)))
        }
    }
}

/// Title + optional caption on the left, any control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var caption: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            control
        }
    }
}

struct SettingToggleRow: View {
    let title: String
    var caption: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(title: title, caption: caption) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

struct SettingSliderRow: View {
    let title: String
    @Binding var value: TimeInterval
    let range: ClosedRange<Double>
    let format: String
    var zeroLabel: String? = nil

    var body: some View {
        SettingRow(title: title) {
            HStack(spacing: 8) {
                Slider(value: $value, in: range)
                    .frame(width: 160)
                Text(value == 0 ? (zeroLabel ?? String(format: format, value)) : String(format: format, value))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        SettingsCard {
            SettingToggleRow(
                title: "Launch at login",
                isOn: binding(\.launchAtLogin) { enabled in
                    try? enabled
                        ? SMAppService.mainApp.register()
                        : SMAppService.mainApp.unregister()
                }
            )
            SettingToggleRow(
                title: "Show Nook icon in the menu bar",
                caption: "Without it: reopen Nook from Spotlight, or right-click a separator or empty menu bar spot.",
                isOn: binding(\.showStatusItem, onSet: { enabled in
                    if !enabled { Self.showIconlessHint() }
                })
            )
        }

        SettingsCard(title: "Reveal") {
            SettingToggleRow(title: "Reveal on hover", isOn: binding(\.revealTriggers.hoverEnabled))
            if appState.settings.revealTriggers.hoverEnabled {
                SettingSliderRow(
                    title: "Hover delay",
                    value: binding(\.revealTriggers.hoverDelay),
                    range: 0.15...0.75,
                    format: "%.2fs"
                )
            }
            SettingToggleRow(title: "Reveal on click in empty menu bar area", isOn: binding(\.revealTriggers.clickEnabled))
            SettingToggleRow(title: "Double-click reveals always-hidden too", isOn: binding(\.revealTriggers.doubleClickForAlwaysHidden))
        }

        SettingsCard(title: "Auto-rehide") {
            SettingToggleRow(title: "Automatically rehide", isOn: binding(\.autoRehide))
            if appState.settings.autoRehide {
                SettingSliderRow(
                    title: "After",
                    value: binding(\.rehideDelay),
                    range: 0...10,
                    format: "%.2gs",
                    zeroLabel: "Instant"
                )
            }
            SettingToggleRow(title: "Rehide when clicking elsewhere", isOn: binding(\.rehideOnClickElsewhere))
        }

        SettingsCard(title: "System extras") {
            SettingRow(
                title: "Now Playing, camera controls, AirDrop, Focus",
                caption: "macOS hides these whenever any icons are concealed — they can only appear while the whole bar is revealed."
            ) {
                Picker("", selection: binding(\.hideSystemExtras)) {
                    Text("Always hidden").tag(true)
                    Text("Show while revealed").tag(false)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }
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

// MARK: - Displays

private struct DisplaysPane: View {
    var body: some View {
        SettingsCard {
            ForEach(NSScreen.screens, id: \.self) { screen in
                DisplayRow(screen: screen)
            }
        }
    }
}

private struct DisplayRow: View {
    @Environment(AppState.self) private var appState
    let screen: NSScreen

    private var uuid: String? { screen.displayUUIDString }

    private var hasNotch: Bool {
        screen.safeAreaInsets.top > 0
    }

    var body: some View {
        SettingRow(title: screen.localizedName) {
            HStack(spacing: 8) {
                if hasNotch {
                    Text("Notch")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Picker("", selection: Binding(
                    get: { appState.settings.behavior(forDisplayUUID: uuid) },
                    set: { behavior in
                        if let uuid {
                            appState.settings.displayOverrides[uuid] = behavior
                            appState.settingsChanged()
                            appState.displayBehaviorEdited()
                        }
                    }
                )) {
                    Text("Collapse into Nook").tag(DisplayBehavior.collapse)
                    Text("Always show everything").tag(DisplayBehavior.alwaysShowAll)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    @Environment(AppState.self) private var appState

    private var version: String {
        let info = Bundle.main
        let short = info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = info.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(short) (\(build))"
    }

    private var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "© 2026 Gabriel Faucon"
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            Text("Nook")
                .font(.system(size: 30, weight: .semibold))
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(copyright)
                .font(.caption)
                .foregroundStyle(.tertiary)

            VStack(spacing: 10) {
                if SparkleController.shared.isConfigured {
                    Button("Check for Updates…") {
                        SparkleController.shared.checkForUpdates()
                    }
                }
                Button("Replay the intro") {
                    OnboardingController.shared.present(appState: appState)
                }
            }
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
