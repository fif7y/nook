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
        if rawValue.hasPrefix("bundle:") {
            return String(rawValue.dropFirst("bundle:".count))
        }
        guard rawValue.hasPrefix("status:") else { return nil }
        let stripped = rawValue.dropFirst("status:".count)
        guard let separator = stripped.range(of: "::") else { return nil }
        return String(stripped[..<separator.lowerBound])
    }

    public var isSystemModule: Bool {
        rawValue.hasPrefix("module:")
    }

    /// The identity the MODEL keys on. Third-party items collapse to their
    /// bundle (`bundle:<id>`): AX titles are volatile ("Item-0" fallback under
    /// load, dynamic titles), every flap minted a fresh identity, and stale
    /// twins polluted assignments/order/editor alike — while hiding is
    /// per-bundle anyway. Nook's own items (stable Nook-chosen titles) and
    /// Apple/system items (stable agent identifiers) keep full identity.
    public var sectionKey: ItemID {
        guard let bundle = bundleID,
              bundle != "app.fif7y.Nook",
              !bundle.hasPrefix("com.apple.")
        else { return self }
        return ItemID(rawValue: "bundle:\(bundle)")
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
        var routed: [ItemID] = []
        for item in items {
            let key = item.sectionKey
            guard let bundle = item.bundleID, newBundles.contains(bundle),
                  assignments[key] == nil, !routed.contains(key)
            else { continue }
            assignments[key] = newItemsDestination
            routed.append(key)
        }
        // Front of the order: macOS spawns new icons at the far LEFT of the
        // status area, so the model mirrors where they physically land.
        order[newItemsDestination, default: []].insert(contentsOf: routed, at: 0)
        return true
    }

    public func section(of item: ItemID) -> Section {
        // Canonical key first; full-ID fallback keeps pre-migration blobs
        // (and probe tooling) working until canonicalize() rewrites them.
        assignments[item.sectionKey] ?? assignments[item] ?? .visible
    }

    /// One-time migration to canonical keys: collapses every title-variant
    /// twin of a bundle into one `bundle:` entry. Where twins disagree, the
    /// entry backed by that section's order wins; otherwise first encountered.
    public mutating func canonicalize() {
        for (section, list) in order {
            var seen = Set<ItemID>()
            order[section] = list.map(\.sectionKey).filter { seen.insert($0).inserted }
        }
        var merged: [ItemID: Section] = [:]
        for (id, section) in assignments where order[section]?.contains(id.sectionKey) == true {
            merged[id.sectionKey] = section
        }
        for (id, section) in assignments where merged[id.sectionKey] == nil {
            merged[id.sectionKey] = section
        }
        assignments = merged
        // A merged twin leaves its loser's order slot in the wrong section —
        // an entry only belongs in the section the model now assigns it to.
        for (home, list) in order {
            order[home] = list.filter { section(of: $0) == home }
        }
    }

    /// Bundles pinned on screen for the given reveal state: any observed item
    /// in `.visible` or a revealed section pins its whole bundle (hiding is
    /// per-bundle). Items absent from `assignments` are visible by default.
    public func mustShowBundles(
        observedItems: [ItemID],
        revealing revealed: Set<Section>
    ) -> Set<String> {
        var mustShow = Set<String>()
        for item in observedItems {
            guard let bundle = item.bundleID else { continue }
            let section = self.section(of: item)
            if section == .visible || revealed.contains(section) {
                mustShow.insert(bundle)
            }
        }
        return mustShow
    }

    /// Bundle-granularity conflict check against the currently observed items:
    /// a bundle can only be concealed if none of its items must remain visible.
    public func concealableBundleIDs(
        observedItems: [ItemID],
        revealing revealed: Set<Section>
    ) -> Set<String> {
        let mustShow = mustShowBundles(observedItems: observedItems, revealing: revealed)
        var wantHide = Set<String>()
        for item in observedItems {
            guard let bundle = item.bundleID else { continue }
            let section = self.section(of: item)
            if section != .visible, !revealed.contains(section) {
                wantHide.insert(bundle)
            }
        }
        return wantHide.subtracting(mustShow)
    }
}
