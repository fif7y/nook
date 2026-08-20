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

    public init(id: UUID = UUID(), style: SeparatorStyle) {
        self.id = id
        self.style = style
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

public enum EditorIconStyle: String, Codable, CaseIterable, Sendable {
    /// Owning app's icon — no permissions needed.
    case appIcons
    /// The actual menubar glyphs, captured live — needs Screen Recording.
    case barIcons
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

    public var editorIconStyle: EditorIconStyle = .appIcons

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
        case hideSystemExtras, showMediaControls, extraItems, editorIconStyle, sectionModel, separators
        case displayTemplate, displayOverrides
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SettingsStore()
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? defaults.onboardingCompleted
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        showStatusItem = try c.decodeIfPresent(Bool.self, forKey: .showStatusItem) ?? defaults.showStatusItem
        hotkey = try c.decodeIfPresent(HotkeySpec.self, forKey: .hotkey) ?? defaults.hotkey
        revealTriggers = try c.decodeIfPresent(RevealTriggers.self, forKey: .revealTriggers) ?? defaults.revealTriggers
        autoRehide = try c.decodeIfPresent(Bool.self, forKey: .autoRehide) ?? defaults.autoRehide
        rehideDelay = try c.decodeIfPresent(TimeInterval.self, forKey: .rehideDelay) ?? defaults.rehideDelay
        rehideOnClickElsewhere = try c.decodeIfPresent(Bool.self, forKey: .rehideOnClickElsewhere) ?? defaults.rehideOnClickElsewhere
        hideSystemExtras = try c.decodeIfPresent(Bool.self, forKey: .hideSystemExtras) ?? defaults.hideSystemExtras
        showMediaControls = try c.decodeIfPresent(Bool.self, forKey: .showMediaControls) ?? defaults.showMediaControls
        extraItems = try c.decodeIfPresent([ExtraItemSpec].self, forKey: .extraItems) ?? defaults.extraItems
        editorIconStyle = try c.decodeIfPresent(EditorIconStyle.self, forKey: .editorIconStyle) ?? defaults.editorIconStyle
        sectionModel = try c.decodeIfPresent(SectionModel.self, forKey: .sectionModel) ?? defaults.sectionModel
        separators = try c.decodeIfPresent([SeparatorSpec].self, forKey: .separators) ?? defaults.separators
        displayTemplate = try c.decodeIfPresent(DisplayBehavior.self, forKey: .displayTemplate) ?? defaults.displayTemplate
        displayOverrides = try c.decodeIfPresent([String: DisplayBehavior].self, forKey: .displayOverrides) ?? defaults.displayOverrides
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
