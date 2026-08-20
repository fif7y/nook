// SectionModel.swift
// Engine-agnostic domain model: which section every menubar item belongs to,
// and in what order. This is Nook's single source of truth — the engine
// converges the real menubar toward it, never the other way around (except
// when adopting a user's native ⌘-drag).

import Foundation

/// Stable identity for one menubar item, matching MenuBarAgent's tag format:
/// `status:<bundleID>::<title>` for app items, `module:<Name>` for system
/// modules. Raw-value backed so it round-trips the agent plist losslessly.
public struct ItemID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Owning bundle identifier for `status:` items; nil for system modules.
    /// Hiding granularity is per-bundle, so grouping keys off this.
    public var bundleID: String? {
        guard rawValue.hasPrefix("status:") else { return nil }
        let stripped = rawValue.dropFirst("status:".count)
        guard let separator = stripped.range(of: "::") else { return nil }
        return String(stripped[..<separator.lowerBound])
    }

    public var isSystemModule: Bool {
        rawValue.hasPrefix("module:")
    }
}

public enum Section: String, Codable, CaseIterable, Sendable {
    case visible
    case hidden
    case alwaysHidden
}

/// The user's desired layout. Absence from `assignments` means `.visible`.
public struct SectionModel: Codable, Equatable, Sendable {
    public var assignments: [ItemID: Section]
    /// Desired left-to-right order within each section. Items missing from the
    /// order array sort after ordered ones, keeping their relative agent order.
    public var order: [Section: [ItemID]]
    /// Where items never seen before land.
    public var newItemsDestination: Section

    public init(
        assignments: [ItemID: Section] = [:],
        order: [Section: [ItemID]] = [:],
        newItemsDestination: Section = .hidden
    ) {
        self.assignments = assignments
        self.order = order
        self.newItemsDestination = newItemsDestination
    }

    public func section(of item: ItemID) -> Section {
        assignments[item] ?? .visible
    }

    /// Every bundle ID that must stay visible for a given reveal state.
    /// Used to build the assessment allowlist: revealing a section means its
    /// bundles join the allowlist alongside the always-visible ones.
    public func visibleBundleIDs(revealing revealed: Set<Section>) -> Set<String> {
        var bundles = Set<String>()
        for (item, section) in assignments where section != .visible {
            guard revealed.contains(section), let bundle = item.bundleID else { continue }
            bundles.insert(bundle)
        }
        return bundles
    }

    /// Bundle-granularity conflict check against the currently observed items:
    /// a bundle can only be concealed if none of its items must remain visible.
    /// (`observedItems` matters because items absent from `assignments` are
    /// visible by default and still pin their bundle on screen.)
    public func concealableBundleIDs(
        observedItems: [ItemID],
        revealing revealed: Set<Section>
    ) -> Set<String> {
        var mustShow = Set<String>()
        var wantHide = Set<String>()
        for item in observedItems {
            guard let bundle = item.bundleID else { continue }
            let section = self.section(of: item)
            if section == .visible || revealed.contains(section) {
                mustShow.insert(bundle)
            } else {
                wantHide.insert(bundle)
            }
        }
        return wantHide.subtracting(mustShow)
    }
}
