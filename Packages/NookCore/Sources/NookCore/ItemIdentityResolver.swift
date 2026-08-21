// ItemIdentityResolver.swift
// The one home for agent-tag-drift reasoning. MenuBarAgent derives item tags
// from AX titles and those DRIFT: the same Velja item has enumerated as
// "status:com.sindresorhus.Velja::Item-0" and
// "…::Left and right arrows in a filled circle" on different days.
//
// The load-bearing invariant everything below leans on: hiding is per-bundle,
// so a bundle is NEVER half-live or half-concealed. Any stored/carried ID
// whose bundle is provably in another state is a stale alias of the real one.
//
// Exempt bundles (Nook's own items, the agent's per-identifier system items)
// legitimately mix live and hidden items and are never touched.
//
// This logic previously existed as three divergent copies (engine converge
// prune, AppState.healAliasIDs, editorItems twin collapse) — each debugged
// separately against the same incident. Change it HERE, with tests.

import Foundation

public enum ItemIdentityResolver {
    public enum StaleReason: Equatable, Sendable {
        /// The bundle re-enumerated live under a different tag.
        case staleAlias
        /// The bundle is no longer running — there is no item at all.
        case quitApp
    }

    /// Which carried concealed IDs are stale and must be dropped.
    /// A concealed item is unobservable, so "carried" entries ride every
    /// snapshot union forever unless pruned by contradiction: the bundle has
    /// a live item under a different ID (tag drifted), or the bundle isn't
    /// running at all (app quit while concealed).
    public static func staleCarriedIDs(
        carried: Set<ItemID>,
        liveIDs: Set<ItemID>,
        runningBundles: Set<String>,
        exemptBundles: Set<String>
    ) -> [ItemID: StaleReason] {
        let liveBundles = Set(liveIDs.compactMap(\.bundleID))
        var stale: [ItemID: StaleReason] = [:]
        for id in carried where !liveIDs.contains(id) {
            guard let bundle = id.bundleID, !exemptBundles.contains(bundle) else { continue }
            if liveBundles.contains(bundle) {
                stale[id] = .staleAlias
            } else if !runningBundles.contains(bundle) {
                stale[id] = .quitApp
            }
        }
        return stale
    }

    /// Remaps for stored model IDs whose bundle has exactly ONE live item
    /// under a different ID — the stored ID is a stale alias of it.
    /// Multi-item bundles are skipped: with several live twins there is no
    /// way to tell which one a stored alias meant.
    public static func aliasRemaps(
        storedIDs: Set<ItemID>,
        liveIDs: some Sequence<ItemID>,
        exemptBundles: Set<String>
    ) -> [ItemID: ItemID] {
        var liveByBundle: [String: [ItemID]] = [:]
        for id in liveIDs {
            guard let bundle = id.bundleID else { continue }
            liveByBundle[bundle, default: []].append(id)
        }
        var remaps: [ItemID: ItemID] = [:]
        for stored in storedIDs {
            guard let bundle = stored.bundleID,
                  !exemptBundles.contains(bundle),
                  let live = liveByBundle[bundle],
                  !live.contains(stored),
                  live.count == 1,
                  let liveID = live.first
            else { continue }
            remaps[stored] = liveID
        }
        return remaps
    }

    /// Among frame-nil (concealed) entries, twins sharing a bundle are one
    /// item plus stale aliases — the engine can't prune an alias until the
    /// item is next observed live, so displays collapse them: the ID the
    /// section model knows wins, then a deterministic pick. Returns the
    /// losers to drop.
    public static func concealedTwinLosers(
        concealedIDs: some Sequence<ItemID>,
        exemptBundles: Set<String>,
        isAssigned: (ItemID) -> Bool
    ) -> Set<ItemID> {
        var byBundle: [String: [ItemID]] = [:]
        for id in concealedIDs {
            guard let bundle = id.bundleID, !exemptBundles.contains(bundle) else { continue }
            byBundle[bundle, default: []].append(id)
        }
        var losers: Set<ItemID> = []
        for (_, twins) in byBundle where twins.count > 1 {
            let ids = twins.sorted { $0.rawValue < $1.rawValue }
            let winner = ids.first(where: isAssigned) ?? ids[0]
            losers.formUnion(ids.filter { $0 != winner })
        }
        return losers
    }
}
