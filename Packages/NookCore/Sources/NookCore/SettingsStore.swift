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
        hoverDelay: TimeInterval = 0.1,
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
    /// Glyph opacity in the bar (invisible spacers ignore it).
    public var opacity: Double

    public init(id: UUID = UUID(), style: SeparatorStyle, opacity: Double = 0.55) {
        self.id = id
        self.style = style
        self.opacity = opacity
    }

    // Resilient decode: specs saved before `opacity` existed keep the old look.
    private enum CodingKeys: String, CodingKey { case id, style, opacity }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        style = try c.decode(SeparatorStyle.self, forKey: .style)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.55
    }
}

public enum ExtraKind: String, Codable, CaseIterable, Sendable {
    case mediaControls
    case cameraMicIndicator
    case airdrop
    case shortcut
}

public struct ExtraItemSpec: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ExtraKind
    /// Shortcuts-app shortcut name (kind == .shortcut).
    public var shortcutName: String?
    /// SF Symbol for shortcut items.
    public var symbol: String?

    public init(id: UUID = UUID(), kind: ExtraKind, shortcutName: String? = nil, symbol: String? = nil) {
        self.id = id
        self.kind = kind
        self.shortcutName = shortcutName
        self.symbol = symbol
    }

    /// Stable ItemID title. Singleton kinds keep fixed titles (section
    /// assignments survive re-toggling); shortcut items key by UUID.
    public var itemTitle: String {
        switch kind {
        case .mediaControls: "Nook.MediaControls"
        case .cameraMicIndicator: "Nook.CameraMic"
        case .airdrop: "Nook.AirDrop"
        case .shortcut: "Nook.Shortcut.\(id.uuidString)"
        }
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

    /// Hold the hide-assertion even while revealed (allowlist just widens).
    /// Keeps macOS's collateral extras (Now Playing, camera pill, AirDrop…)
    /// consistently hidden instead of jumping in and out on every transition.
    public var hideSystemExtras: Bool = true

    /// Nook's own media-controls item (play/pause/next/prev via media keys).
    /// Superseded by `extraItems`; kept for migration of early builds.
    public var showMediaControls: Bool = false

    /// Nook-owned proxy items ("Nook items"): section-manageable replacements
    /// for the collateral-hidden system extras, plus user shortcut buttons.
    public var extraItems: [ExtraItemSpec] = []

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

    // MARK: - Codable (resilient: new fields fall back to defaults instead of
    // failing the whole decode and silently resetting the user's settings)

    private enum CodingKeys: String, CodingKey {
        case onboardingCompleted, launchAtLogin, showStatusItem, hotkey
        case revealTriggers, autoRehide, rehideDelay, rehideOnClickElsewhere
        case hideSystemExtras, showMediaControls, extraItems, sectionModel, separators
        case displayTemplate, displayOverrides
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SettingsStore()
        // `try?` per field, not just decodeIfPresent: a present-but-invalid
        // value (unknown enum case after a downgrade, hand-edited blob) throws
        // out of decodeIfPresent, and one bad field must reset THAT field —
        // not silently nuke every preference via load()'s outer `try?`.
        func field<T: Decodable>(_ type: T.Type, _ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(type, forKey: key)) ?? nil) ?? fallback
        }
        onboardingCompleted = field(Bool.self, .onboardingCompleted, defaults.onboardingCompleted)
        launchAtLogin = field(Bool.self, .launchAtLogin, defaults.launchAtLogin)
        showStatusItem = field(Bool.self, .showStatusItem, defaults.showStatusItem)
        hotkey = ((try? c.decodeIfPresent(HotkeySpec.self, forKey: .hotkey)) ?? nil) ?? defaults.hotkey
        revealTriggers = field(RevealTriggers.self, .revealTriggers, defaults.revealTriggers)
        autoRehide = field(Bool.self, .autoRehide, defaults.autoRehide)
        rehideDelay = field(TimeInterval.self, .rehideDelay, defaults.rehideDelay)
        rehideOnClickElsewhere = field(Bool.self, .rehideOnClickElsewhere, defaults.rehideOnClickElsewhere)
        hideSystemExtras = field(Bool.self, .hideSystemExtras, defaults.hideSystemExtras)
        showMediaControls = field(Bool.self, .showMediaControls, defaults.showMediaControls)
        extraItems = field([ExtraItemSpec].self, .extraItems, defaults.extraItems)
        sectionModel = field(SectionModel.self, .sectionModel, defaults.sectionModel)
        separators = field([SeparatorSpec].self, .separators, defaults.separators)
        displayTemplate = field(DisplayBehavior.self, .displayTemplate, defaults.displayTemplate)
        displayOverrides = field([String: DisplayBehavior].self, .displayOverrides, defaults.displayOverrides)
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
