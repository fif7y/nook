// ConvergePlan.swift
// The pure decision half of EngineGoldenGate.converge(): everything that can
// be computed from inputs without touching AX, the private API, or actor
// state. The actor gathers inputs, calls `compute`, and executes the plan —
// which is what makes the engine's brain unit-testable.

import Foundation
import NookCore

struct ConvergePlan: Equatable {
    /// Carried concealed IDs that must be dropped, with reasons (for logging).
    var stale: [ItemID: ItemIdentityResolver.StaleReason]
    /// Live ∪ surviving carried — the "existing" set convergence reasons over.
    var observedIDs: [ItemID]
    /// Bundles the assertion must conceal.
    var concealable: Set<String>
    /// System items leaving the system allowlist.
    var hiddenSystem: Set<SystemItem>
    /// System items staying on the allowlist.
    var allowedSystem: [SystemItem]
    /// True when there is nothing to hide and extras may return: drop the
    /// assertion entirely instead of swapping.
    var dropAssertion: Bool
    /// The bundle allowlist for the new assertion (empty when dropping).
    var allowedBundles: Set<String>
    /// The concealed set to stamp on the snapshot after the swap.
    var concealed: Set<ItemID>

    static func compute(
        model: SectionModel,
        liveIDs: Set<ItemID>,
        carriedConcealed: Set<ItemID>,
        runningBundles: Set<String>,
        revealedSections: Set<NookCore.Section>,
        steadyExtras: Bool,
        exemptBundles: Set<String>
    ) -> ConvergePlan {
        let stale = ItemIdentityResolver.staleCarriedIDs(
            carried: carriedConcealed,
            liveIDs: liveIDs,
            runningBundles: runningBundles,
            exemptBundles: exemptBundles
        )
        let carried = carriedConcealed.subtracting(stale.keys)
        let observedIDs = Array(liveIDs.union(carried))
        var concealable = model.concealableBundleIDs(
            observedItems: observedIDs,
            revealing: revealedSections
        )
        // The model's word, independent of observation: a bundle ASSIGNED to
        // a non-revealed section stays concealable while its app runs, even
        // when its item is neither live (it's concealed — that's the point)
        // nor carried (the carried set is bookkeeping and can be lost). An
        // observation-only plan computed concealable=[] whenever carried
        // dropped, swapped in an allow-all assertion, and flashed every
        // hidden section until the correcting converge landed.
        var mustShow = Set<String>()
        for id in observedIDs {
            guard let bundle = id.bundleID else { continue }
            let section = model.section(of: id)
            if section == .visible || revealedSections.contains(section) {
                mustShow.insert(bundle)
            }
        }
        for (id, section) in model.assignments {
            guard section != .visible, !revealedSections.contains(section),
                  let bundle = id.bundleID,
                  runningBundles.contains(bundle),
                  !exemptBundles.contains(bundle),
                  !mustShow.contains(bundle)
            else { continue }
            concealable.insert(bundle)
        }

        // System items assigned to a non-revealed section leave the system
        // allowlist — this is how Sound/battery/etc. become hideable. An
        // explicit `.visible` assignment must never hide (that section is by
        // definition never "revealed" — it's always on screen).
        let hiddenSystem = Set(model.assignments.compactMap { id, section -> SystemItem? in
            guard section != .visible, !revealedSections.contains(section) else { return nil }
            return MenuBarPolicy.systemItem(for: id)
        })
        let allowedSystem = SystemItem.allCases.filter { !hiddenSystem.contains($0) }

        let dropAssertion = concealable.isEmpty && hiddenSystem.isEmpty && !steadyExtras

        // Allowlist = every third-party bundle except the concealable. Built
        // from ALL running apps, not just observed items — a bundle without a
        // status item is a harmless allow, and it means an app launched after
        // this converge shows its new icon instead of being swallowed.
        var allowedBundles = Set<String>()
        if !dropAssertion {
            for id in observedIDs {
                if let bundle = id.bundleID, !concealable.contains(bundle) {
                    allowedBundles.insert(bundle)
                }
            }
            for bundle in runningBundles where !concealable.contains(bundle) {
                allowedBundles.insert(bundle)
            }
        }

        let concealed = Set(observedIDs.filter { id in
            if let system = MenuBarPolicy.systemItem(for: id) {
                return hiddenSystem.contains(system)
            }
            guard let bundle = id.bundleID else { return false }
            return concealable.contains(bundle)
        })

        return ConvergePlan(
            stale: stale,
            observedIDs: observedIDs,
            concealable: concealable,
            hiddenSystem: hiddenSystem,
            allowedSystem: allowedSystem,
            dropAssertion: dropAssertion,
            allowedBundles: allowedBundles,
            concealed: dropAssertion ? [] : concealed
        )
    }
}
