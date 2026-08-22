// EditorItemsBuilder.swift
// Pure derivation of the layout editor's board for one section — extracted
// from AppState so the twin collapse, stand-in synthesis, and ordering rules
// are unit-testable. App lookups (running apps) are injected closures; the
// AppState shim memoizes them per call.

import Foundation
import NookCore
import NookEngine

enum EditorItemsBuilder {
    /// Items the layout editor shows for a section: third-party only (Apple
    /// items are out of scope), Nook's own items excluded, and CONCEALED items
    /// included — they drop out of AX observation but absolutely belong in the
    /// editor (frame nil, icon from the app bundle).
    static func build(
        section: NookCore.Section,
        snapshotItems: [ObservedItem],
        concealed: Set<ItemID>,
        extraItems: [ExtraItemSpec],
        separators: [SeparatorSpec],
        model: SectionModel,
        nookBundleID: String,
        isRunning: (String) -> Bool,
        appName: (String) -> String?
    ) -> [ObservedItem] {
        var byID: [ItemID: ObservedItem] = [:]
        for item in snapshotItems {
            byID[item.id] = item
        }
        for id in concealed where byID[id] == nil {
            byID[id] = ObservedItem(id: id, frame: nil, appName: id.bundleID.flatMap(appName))
        }
        // Nook's extras are section-manageable (visibility-based hiding); when
        // hidden they're absent from AX, so ensure they're represented.
        for spec in extraItems {
            let id = ExtrasManager.itemID(for: spec)
            if byID[id] == nil {
                byID[id] = ObservedItem(id: id, frame: nil, appName: spec.shortcutName ?? nil)
            }
        }
        // Separators too — same visibility-based hiding as extras.
        for spec in separators {
            let id = SeparatorManager.itemID(for: spec)
            if byID[id] == nil {
                byID[id] = ObservedItem(id: id, frame: nil, appName: "Separator")
            }
        }
        // Model members that are momentarily neither observable nor in the
        // engine's concealed set (mid-reveal AX latency, mid-conceal swap)
        // still belong on the board — without this the section flashed empty
        // on every tab revisit. Quit apps stay off (bundle not running).
        let stored = Set(
            model.assignments.filter { $0.value == section }.map(\.key)
        ).union(model.order[section] ?? [])
        for id in stored where byID[id] == nil {
            guard let bundle = id.bundleID,
                  bundle != nookBundleID,
                  !MenuBarPolicy.isUnmanagedAppleBundle(bundle),
                  isRunning(bundle)
            else { continue }
            byID[id] = ObservedItem(id: id, frame: nil, appName: appName(bundle))
        }
        // Drop stale twins the concealed set may still remember: a bundle is
        // never half-concealed, so a frame-nil entry whose bundle has a live
        // item is an old alias, not a second icon. (Nook's own extras are
        // exempt — they legitimately mix live and hidden items.)
        let liveBundles = Set(
            snapshotItems.compactMap(\.id.bundleID)
        ).subtracting([nookBundleID])
        // Two frame-nil twins of one bundle (both "concealed") are one item
        // under a drifted tag plus its stale alias — the engine can't prune
        // the alias until the item is next observed live, so collapse here.
        let concealedTwinLoser = ItemIdentityResolver.concealedTwinLosers(
            concealedIDs: byID.values.filter { $0.frame == nil }.map(\.id),
            exemptBundles: MenuBarPolicy.identityExemptBundles(nookBundleID: nookBundleID),
            isAssigned: { model.assignments[$0.sectionKey] != nil }
        )
        let all = byID.values.filter { item in
            if concealedTwinLoser.contains(item.id) { return false }
            if item.frame == nil,
               let bundle = item.id.bundleID,
               liveBundles.contains(bundle) {
                return false
            }
            guard !item.id.isSystemModule,
                  model.section(of: item.id) == section
            else { return false }
            if item.id.bundleID == nookBundleID {
                return MenuBarPolicy.isNookExtraID(item.id)
            }
            if MenuBarPolicy.isUnmanagedAppleBundle(item.id.bundleID) {
                // Core system icons the assertion can individually control
                // (Sound, battery, Wi-Fi…) are manageable; the rest stay out.
                return MenuBarPolicy.systemItem(for: item.id) != nil
            }
            return true
        }
        // One tile per canonical identity: title-variant twins collapse. The
        // representative is the leftmost live-framed item (placement measures
        // against it), falling back to a concealed stand-in.
        var byKey: [ItemID: ObservedItem] = [:]
        for item in all {
            let key = item.id.sectionKey
            guard let existing = byKey[key] else {
                byKey[key] = item
                continue
            }
            switch (existing.frame, item.frame) {
            case (nil, .some): byKey[key] = item
            case let (e?, i?) where i.minX < e.minX: byKey[key] = item
            default: break
            }
        }
        let explicit = model.order[section] ?? []
        return byKey.values.sorted { lhs, rhs in
            // The user's explicit order is authoritative — nothing outranks it.
            // (A left-pin experiment for extras once did, and it broke drag
            // ordering and Tidy alike.) Order arrays hold canonical keys.
            let li = explicit.firstIndex(of: lhs.id.sectionKey) ?? Int.max
            let ri = explicit.firstIndex(of: rhs.id.sectionKey) ?? Int.max
            if li != ri { return li < ri }
            return (lhs.frame?.minX ?? .greatestFiniteMagnitude)
                < (rhs.frame?.minX ?? .greatestFiniteMagnitude)
        }
    }
}
