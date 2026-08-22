// BarAdoption.swift
// Pure bar→model reconciliation for a user's native ⌘-drag: menubar-positional
// sections keyed off Nook's chevron (the visible/hidden boundary), zone-CHANGE
// detection against the last pass, and within-section order fold-in.
// Extracted from AppState so the confidence rules and order reconciliation are
// unit-testable; the app shim replays `log` into NookLog and persists `model`.

import CoreGraphics
import Foundation

public enum BarAdoption {
    public struct Result: Sendable {
        public let model: SectionModel
        /// Zone tracking to carry into the next pass (confident measurements
        /// only — a guessed zone must never become a baseline).
        public let zones: [String: Section]
        public let changed: Bool
        public let log: [String]
    }

    /// Reconcile the observed bar against the model. `items` is every
    /// observed item with its frame's minX (nil when concealed/unmeasured),
    /// in snapshot order. Returns nil when Nook's chevron has no measurable
    /// frame — there is no boundary to reason against.
    ///
    /// Anything sitting LEFT of the chevron (smaller AX x) is adopted into
    /// Hidden; right of it back to Visible. Always-Hidden has no physical
    /// marker of its own; its live cluster IS the boundary — an item dropped
    /// among/left of always-hidden members (only visible during a full
    /// reveal) adopts in, one dropped among the hidden cluster adopts out.
    /// Reflows shift every frame but never an item's relative position — only
    /// a real user drag does. That makes zone-CHANGE the safe adoption
    /// trigger: a settings-assigned item still sitting in its old zone is
    /// never "corrected" back.
    public static func reconcile(
        items: [(id: ItemID, minX: CGFloat?)],
        model startModel: SectionModel,
        previousZones: [String: Section],
        nookBundleID: String
    ) -> Result? {
        guard let chevronX = items.first(where: {
            $0.id.bundleID == nookBundleID
                && !MenuBarPolicy.isNookExtraID($0.id)
                && !$0.id.rawValue.contains("Separator")
        })?.minX else { return nil }

        var log: [String] = []
        var zones = previousZones
        var model = startModel
        var changed = false
        let isFirstPass = previousZones.isEmpty
        log.append("adopt: chevronX=\(chevronX) firstPass=\(isFirstPass) trackedZones=\(previousZones.count)")
        // Cluster edges from the PRE-adoption model: the always-hidden and
        // hidden members' live frames (only present during a full reveal).
        // Self-excluded per item below so an item never bounds itself.
        let clusterX: [(id: ItemID, x: CGFloat, section: Section)] = items.compactMap {
            guard let x = $0.minX else { return nil }
            let section = model.section(of: $0.id)
            guard section != .visible else { return nil }
            return ($0.id, x, section)
        }
        for item in items {
            guard let bundle = item.id.bundleID,
                  bundle != nookBundleID || MenuBarPolicy.isNookExtraID(item.id),
                  !MenuBarPolicy.isUnmanagedAppleBundle(bundle),
                  let x = item.minX
            else { continue }
            let current = model.section(of: item.id)
            let zone: Section
            var confident = true
            if x >= chevronX {
                zone = .visible
            } else {
                let ahMax = clusterX
                    .filter { $0.section == .alwaysHidden && $0.id != item.id }
                    .map(\.x).max()
                let hMin = clusterX
                    .filter { $0.section == .hidden && $0.id != item.id }
                    .map(\.x).min()
                if let ahMax, x < ahMax {
                    zone = .alwaysHidden
                } else if let hMin, x > hMin {
                    zone = .hidden
                } else {
                    // Between the clusters, or a cluster is concealed and
                    // unmeasurable — ambiguous, so the model's word stands
                    // (an always-hidden item stays; anything else is hidden).
                    zone = current == .alwaysHidden ? .alwaysHidden : .hidden
                    confident = false
                }
            }
            let previousZone = zones[item.id.rawValue]
            // A guessed zone must never become a baseline: a new app lands
            // far left, reads "hidden" while concealed (ambiguous) and
            // "alwaysHidden" on the next full reveal — that flap would adopt
            // as if the user dragged it. Only measured zones persist.
            if confident { zones[item.id.rawValue] = zone }
            // First sighting establishes a baseline; only a zone CHANGE adopts.
            guard !isFirstPass, let previousZone, previousZone != zone else { continue }
            guard zone != current else { continue }
            if zone == .visible {
                model.assignments.removeValue(forKey: item.id.sectionKey)
            } else {
                model.assignments[item.id.sectionKey] = zone
            }
            log.append("adopt: \(item.id.rawValue) → \(zone)")
            changed = true
        }
        // Within-section order: the editor treats the explicit stored order as
        // authoritative, so a manual ⌘-drag would otherwise show at its OLD
        // slot forever. Fold the bar's left-to-right reality back in: entries
        // with live frames reorder to match X, frame-nil (concealed) entries
        // hold their slots, entries whose section changed drop out, and
        // newly-adopted members slot in by X. Safe here because adopt only
        // runs on a settled bar — reflows shift frames but preserve X order.
        // Keyed canonically (leftmost frame wins for multi-item bundles) —
        // order arrays hold canonical section keys.
        let liveX: [ItemID: CGFloat] = items.reduce(into: [:]) {
            guard let x = $1.minX else { return }
            let key = $1.id.sectionKey
            $0[key] = min($0[key] ?? .greatestFiniteMagnitude, x)
        }
        for (section, order) in model.order {
            var newOrder = order.filter { model.section(of: $0) == section }
            let liveSlots = newOrder.indices.filter { liveX[newOrder[$0]] != nil }
            let sortedLive = liveSlots.map { newOrder[$0] }.sorted { liveX[$0]! < liveX[$1]! }
            for (offset, slot) in liveSlots.enumerated() { newOrder[slot] = sortedLive[offset] }
            var known = Set(newOrder)
            let missing = items.filter {
                $0.minX != nil && !known.contains($0.id.sectionKey)
                    && model.section(of: $0.id) == section
                    && !$0.id.isSystemModule
                    && !MenuBarPolicy.isUnmanagedAppleBundle($0.id.bundleID)
                    && ($0.id.bundleID != nookBundleID || MenuBarPolicy.isNookExtraID($0.id))
            }
            for item in missing.sorted(by: { liveX[$0.id.sectionKey]! < liveX[$1.id.sectionKey]! }) {
                let key = item.id.sectionKey
                guard known.insert(key).inserted else { continue }
                let x = liveX[key]!
                let insertAfter = newOrder.lastIndex { liveX[$0].map { $0 < x } == true }
                newOrder.insert(key, at: insertAfter.map { $0 + 1 } ?? 0)
            }
            if newOrder != order {
                model.order[section] = newOrder
                log.append("adopt: \(section) order reconciled from bar")
                changed = true
            }
        }
        return Result(model: model, zones: zones, changed: changed, log: log)
    }
}
