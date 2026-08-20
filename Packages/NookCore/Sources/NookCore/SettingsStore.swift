// SettingsStore.swift
// All user preferences, one Codable blob in UserDefaults. Tiny data — no files,
// no CoreData. Every option here expresses a real user preference (options that
// exist to work around engine unreliability are banned by design).

import Foundation

public struct HotkeySpec: Codable, Equatable, Sendable {
    /// Carbon key code + modifier flags (stored raw for the recorder).
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum DisplayBehavior: String, Codable, Equatable, Sendable {
    /// Never conceal while the pointer is on this display.
    case alwaysShowAll
    /// Collapse; reveal via the configured triggers.
    case collapse
}

public struct RevealTriggers: Codable, Equatable, Sendable {
    public var hoverEnabled: Bool
    public var hoverDelay: TimeInterval
    public var clickEnabled: Bool
    public var doubleClickForAlwaysHidden: Bool

    public init(
        hoverEnabled: Bool = true,
        hoverDelay: TimeInterval = 0.2,
        clickEnabled: Bool = true,
        doubleClickForAlwaysHidden: Bool = true
    ) {
        self.hoverEnabled = hoverEnabled
        self.hoverDelay = hoverDelay
        self.clickEnabled = clickEnabled
        self.doubleClickForAlwaysHidden = doubleClickForAlwaysHidden
    }
}

public enum SeparatorStyle: String, Codable, CaseIterable, Sendable {
    case pipe = "|"
    case dot = "•"
    case chevronLeft = "‹"
    case chevronRight = "›"
    case dash = "—"
    case space = " "

    public var displayName: String {
        switch self {
        case .pipe: "Pipe"
        case .dot: "Dot"
        case .chevronLeft: "Chevron ‹"
        case .chevronRight: "Chevron ›"
        case .dash: "Dash"
        case .space: "Invisible spacer"
        }
    }
}

public struct SeparatorSpec: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var style: SeparatorStyle

    public init(id: UUID = UUID(), style: SeparatorStyle) {
        self.id = id
        self.style = style
    }
}

public struct SettingsStore: Codable, Equatable, Sendable {
    public var onboardingCompleted: Bool = false
    public var launchAtLogin: Bool = false
    public var showStatusItem: Bool = true
    public var hotkey: HotkeySpec? = nil

    public var revealTriggers = RevealTriggers()
    public var autoRehide: Bool = true
    public var rehideDelay: TimeInterval = 5
    public var rehideOnClickElsewhere: Bool = true

    public var sectionModel = SectionModel()
    public var separators: [SeparatorSpec] = []

    /// Behavior template + per-display overrides, keyed by display UUID string.
    public var displayTemplate: DisplayBehavior = .collapse
    public var displayOverrides: [String: DisplayBehavior] = [:]

    public var rehidePolicy: RehidePolicy {
        RehidePolicy(
            autoRehide: autoRehide,
            delay: rehideDelay,
            rehideOnClickElsewhere: rehideOnClickElsewhere
        )
    }

    public func behavior(forDisplayUUID uuid: String?) -> DisplayBehavior {
        guard let uuid else { return displayTemplate }
        return displayOverrides[uuid] ?? displayTemplate
    }

    // MARK: - Persistence

    private static let defaultsKey = "app.fif7y.Nook.settings.v1"

    public static func load(defaults: UserDefaults = .standard) -> SettingsStore {
        guard
            let data = defaults.data(forKey: defaultsKey),
            let store = try? JSONDecoder().decode(SettingsStore.self, from: data)
        else { return SettingsStore() }
        return store
    }

    public func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    public init() {}
}
