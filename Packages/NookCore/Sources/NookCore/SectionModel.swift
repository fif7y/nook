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
    /// Every third-party bundle Nook has ever observed in the bar. An app
    /// absent from this set is "new" and routes to `newItemsDestination`.
    /// Bundle-granularity (not ItemID) because titles can be dynamic — a
    /// title change must not re-trigger routing for a known app.
    public var knownBundles: Set<String>

    public init(
        assignments: [ItemID: Section] = [:],
        order: [Section: [ItemID]] = [:],
        newItemsDestination: Section = .hidden,
        knownBundles: Set<String> = []
    ) {
        self.assignments = assignments
        self.order = order
        self.newItemsDestination = newItemsDestination
        self.knownBundles = knownBundles
    }

    // Resilient decode: models saved before `knownBundles` existed load with
    // an empty set, which the next register pass treats as a baseline.
    private enum CodingKeys: String, CodingKey {
        case assignments, order, newItemsDestination, knownBundles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assignments = try c.decode([ItemID: Section].self, forKey: .assignments)
        order = try c.decode([Section: [ItemID]].self, forKey: .order)
        newItemsDestination = try c.decode(Section.self, forKey: .newItemsDestination)
        knownBundles = try c.decodeIfPresent(Set<String>.self, forKey: .knownBundles) ?? []
    }

    /// Folds observed items into `knownBundles`, assigning every item of a
    /// never-seen bundle to `newItemsDestination`. An empty known set is a
    /// silent baseline (fresh install or pre-`knownBundles` upgrade):
    /// everything registers, nothing moves. Callers pre-filter to manageable
    /// items (third-party status items). Returns true if the model changed.
    public mutating func registerObservedItems(_ items: [ItemID]) -> Bool {
        let newBundles = Set(items.compactMap(\.bundleID)).subtracting(knownBundles)
        guard !newBundles.isEmpty else { return false }
        let baseline = knownBundles.isEmpty
        knownBundles.formUnion(newBundles)
        guard !baseline, newItemsDestination != .visible else { return true }
        for item in items {
            guard let bundle = item.bundleID, newBundles.contains(bundle),
                  assignments[item] == nil
            else { continue }
            assignments[item] = newItemsDestination
            order[newItemsDestination, default: []].append(item)
        }
        return true
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
