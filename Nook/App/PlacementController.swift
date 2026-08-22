// PlacementController.swift
// Physical placement + order-apply orchestration, extracted from AppState:
// the synthetic ⌘-drag pipeline (Nook-owned items), the deterministic plist
// rebuild with re-mint recovery (third-party items), the newcomer placement
// queue, and the order-apply cover choreography.

import AppKit
import NookCore
import NookEngine

@MainActor
final class PlacementController {
    private weak var appState: AppState?
    private let engine: EngineGoldenGate

    init(appState: AppState, engine: EngineGoldenGate) {
        self.appState = appState
        self.engine = engine
    }

    // MARK: - Physical placement (synthetic ⌘-drag)

    /// Returns true when the icon was dragged into place (or verified already
    /// there) — false when placement had to be skipped (no frame, nothing to
    /// measure against), so callers can keep it queued for a retry.
    @discardableResult
    func physicallyPlace(_ id: ItemID, in section: NookCore.Section) async -> Bool {
        // Synthetic drags post raw CGEvents with sleeps between them — two
        // interleaved sequences corrupt each other (second mouse-down while
        // the first drag's button is logically down, targets ping-ponging).
        // Serialize every placement through one chain; callers spawn Tasks
        // freely (editor drops, extras toggles, tidy) and each waits its turn.
        let prior = placementChain
        var placed = false
        let task = Task { [weak self] in
            await prior?.value
            placed = await self?.physicallyPlaceNow(id, in: section) ?? false
        }
        placementChain = task
        await task.value
        return placed
    }

    private var placementChain: Task<Void, Never>?

    /// True while a synthetic ⌘-drag sequence is executing. The band monitor
    /// consults this to skip its drag-end adoption for OUR drags: the model
    /// is authoritative in that flow (the editor drop already wrote it), and
    /// adopting a BOUNCED drag would cement the failed order back into the
    /// model, silently reverting the user's arrangement.
    private(set) var activePlacements = 0
    var syntheticDragInFlight: Bool { activePlacements > 0 }

    /// Routed-but-not-yet-placed newcomers. A new icon spawns at the far left
    /// of the VISIBLE-at-that-moment items — but concealed cluster members
    /// rematerialize around it on reveal, stranding it mid-cluster (Figma
    /// landed between always-hidden icons). Placement into a concealed
    /// section can't be measured, so it waits here until a reveal gives the
    /// section live frames.
    var pendingPlacements: Set<ItemID> = []

    /// Called on every reveal settle: place pending newcomers whose section
    /// is now measurable. Items meanwhile moved by the user (editor drop
    /// places immediately) just drop out of the queue.
    private var flushingPlacements = false

    func flushPendingPlacements() {
        guard !pendingPlacements.isEmpty, !flushingPlacements else { return }
        flushingPlacements = true
        let flushed = pendingPlacements
        pendingPlacements.removeAll()
        Task { [weak self] in
            guard let self else { return }
            defer { self.flushingPlacements = false }
            NookLog.log("place: placing \(flushed.count) queued newcomer(s)")
            for id in flushed {
                guard let appState else { return }
                let placed = await physicallyPlace(
                    id, in: appState.settings.sectionModel.section(of: id)
                )
                // Still unmeasurable (section concealed again, no frame) —
                // requeue for the next reveal settle.
                if !placed { pendingPlacements.insert(id) }
            }
        }
    }

    private func physicallyPlaceNow(_ id: ItemID, in section: NookCore.Section) async -> Bool {
        guard let appState else { return false }
        activePlacements += 1
        defer { activePlacements -= 1 }
        try? await Task.sleep(for: AppTiming.placementPreSettle)
        // The payload can be a canonical `bundle:` id (stored/concealed
        // editor tile) or any title-variant — resolve to the live
        // representative by section key, exact id first.
        func liveItem(in snap: EngineSnapshot) -> ObservedItem? {
            snap.items.first(where: { $0.id == id && $0.frame != nil })
                ?? snap.items.first(where: { $0.id.sectionKey == id.sectionKey && $0.frame != nil })
        }
        // Freshly-shown extras take a beat to be hosted — retry the lookup
        // briefly instead of giving up on the first stale snapshot.
        var snap = await engine.snapshot()
        appState.updateSnapshot(snap)
        for _ in 0..<AppTiming.placementLookupRetries where liveItem(in: snap) == nil {
            try? await Task.sleep(for: AppTiming.placementLookupRetryDelay)
            snap = await engine.snapshot()
            appState.updateSnapshot(snap)
        }
        let nookBundle = Bundle.main.bundleIdentifier ?? NookBundle.fallbackID
        guard
            let item = liveItem(in: snap),
            let frame = item.frame
        else {
            NookLog.log("place: no frame for \(id.rawValue) — skipping physical move (concealed?)")
            return false
        }
        // Post-drag verification looks the item up by its LIVE id.
        let liveID = item.id
        guard let screen = NSScreen.screens.first else { return false }
        // Chevron is OPTIONAL: with the Nook icon hidden, live neighbor
        // frames alone anchor the target — only the no-neighbor fallbacks
        // and the final side clamp need the chevron.
        let rawChevronFrame = appState.nookChevronItem(in: snap)?.frame

        // Neighbors in the DESIRED order that have live frames — adjusted into
        // the "lifted" coordinate space: once the drag picks the item up, the
        // gap it leaves closes, shifting everything right of its origin left
        // by one item width. Targets computed in pre-lift coordinates land one
        // slot off (verified: consistent ±itemWidth misses in the logs).
        // EXCEPT for Nook's own items (separators, extras): dragging an
        // own-process item keeps the bar frozen — the gap does NOT close, so
        // lifted targets land one width short and the drop bounces back
        // (verified: raw-frame drop swaps, lifted-frame drop reverts).
        let dragIsNookOwned = item.id.bundleID == nookBundle
        func lifted(_ neighborFrame: CGRect) -> CGRect {
            guard !dragIsNookOwned else { return neighborFrame }
            return neighborFrame.minX > frame.midX
                ? neighborFrame.offsetBy(dx: -frame.width, dy: 0)
                : neighborFrame
        }
        // Neighbors from the GLOBAL desired order, not just the item's own
        // section: at a section boundary the adjacent item belongs to the
        // NEXT cluster, and a one-sided "right.minX - 14" target overshoots
        // into that item's footprint (bar spacing is tighter than 14pt) — the
        // agent then slots the drop one place too far left. Verified: Figma,
        // first-of-Hidden, kept landing left of Always-Hidden's Bitwarden.
        let globalOrder = appState.editorItems(in: .alwaysHidden)
            + appState.editorItems(in: .hidden)
            + appState.editorItems(in: .visible)
        // Canonical comparison: the editor's representative for this bundle
        // may be a different title-variant of the same item.
        let index = globalOrder.firstIndex(where: { $0.id.sectionKey == id.sectionKey })
            ?? globalOrder.count
        // Only frames in the SAME menu-bar band as the dragged item are
        // trustworthy: an AX walk can carry another display's bar (its own
        // coordinate origin), and one foreign neighbor frame aimed a drop at
        // x=268 on a status area that starts around x=1050.
        func inBand(_ f: CGRect) -> Bool {
            MenuBarGeometry.isInBand(f)
                && abs(f.midY - frame.midY) < 30
                && f.midX > 0 && f.midX < screen.frame.maxX
        }
        let chevronFrame = rawChevronFrame.flatMap { inBand($0) ? $0 : nil }
        // Keep the neighbor ITEMS, not just their frames — after the drag the
        // landing is verified against them (x-order), because the lifted-gap
        // assumption is not reliable at cluster boundaries (verified: a
        // one-slot boundary drag bounced back — target fell inside the raw
        // footprint of the left neighbor).
        let leftPair = globalOrder[..<index].reversed().first(where: { $0.frame.map(inBand) == true })
        let rightPair = globalOrder[(min(index + 1, globalOrder.count))...].first(where: { $0.frame.map(inBand) == true })
        let leftNeighbor = leftPair?.frame.map(lifted)
        let rightNeighbor = rightPair?.frame.map(lifted)

        let managedMinX = snap.items
            .filter { !MenuBarPolicy.isUnmanagedAppleBundle($0.id.bundleID) && !$0.id.isSystemModule }
            .compactMap(\.frame?.minX)
            .min()
        guard let targetX = PlacementGeometry.targetX(
            leftNeighbor: leftNeighbor,
            rightNeighbor: rightNeighbor,
            chevron: chevronFrame,
            section: section,
            managedMinX: managedMinX,
            screenMaxX: screen.frame.maxX
        ) else {
            NookLog.log("place: no live neighbors and no chevron for \(id.rawValue) — skipping")
            return false
        }

        // Skip only when the item is genuinely at its slot already — a full
        // icon-width tolerance silently swallowed every one-slot move.
        let alreadyPlaced = abs(frame.midX - targetX) < 10
        guard !alreadyPlaced else {
            NookLog.log("place: \(id.rawValue) already at slot (x=\(frame.midX), target=\(targetX))")
            return true
        }

        // The drag must start inside the main display's menu bar band — a
        // stale or foreign-display frame here would post a ⌘-click into
        // whatever sits at that point on screen.
        guard MenuBarGeometry.isInBand(frame),
              frame.midX > 0, frame.midX < screen.frame.maxX else {
            NookLog.log("place: source frame outside menu bar band (\(frame)) — skipping drag")
            return false
        }
        // The landing is verified by ORDER against the intended neighbors —
        // landing coordinates legitimately shift with the post-drop reflow,
        // but the item must sit right of its left neighbor and left of its
        // right one. A failed first attempt retries once with RAW (unlifted)
        // neighbor frames: whether the gap closes during the drag differs by
        // context, and whichever assumption was wrong the first time, the
        // other target is the correct one.
        func landedInSlot(_ snap: EngineSnapshot) -> Bool {
            guard let x = snap.items.first(where: { $0.id == liveID })?.frame?.midX else { return false }
            let leftMid = leftPair
                .flatMap { l in snap.items.first { $0.id == l.id }?.frame }
                .flatMap { inBand($0) ? $0.midX : nil }
            let rightMid = rightPair
                .flatMap { r in snap.items.first { $0.id == r.id }?.frame }
                .flatMap { inBand($0) ? $0.midX : nil }
            return PlacementGeometry.inSlot(x: x, leftMidX: leftMid, rightMidX: rightMid)
        }
        NookLog.log("place: dragging \(id.rawValue) x=\(frame.midX) → \(targetX) (section \(section))")
        await ItemMover.cmdDrag(
            from: CGPoint(x: frame.midX, y: 12),
            to: CGPoint(x: targetX, y: 12)
        )
        try? await Task.sleep(for: AppTiming.postDragSettle)
        var after = await engine.snapshot()
        appState.updateSnapshot(after)
        if let newFrame = after.items.first(where: { $0.id == liveID })?.frame {
            NookLog.log("place: landed at x=\(newFrame.midX)")
        } else {
            NookLog.log("place: item not observable after drag")
        }
        var placed = landedInSlot(after)
        if !placed,
           let retryFrame = after.items.first(where: { $0.id == liveID })?.frame,
           let rawLeft = leftPair.flatMap({ l in after.items.first { $0.id == l.id }?.frame }),
           let rawRight = rightPair.flatMap({ r in after.items.first { $0.id == r.id }?.frame }),
           inBand(rawLeft), inBand(rawRight),
           rawLeft.midX < rawRight.midX {
            let retryX = PlacementGeometry.rawRetryX(
                left: rawLeft, right: rawRight, screenMaxX: screen.frame.maxX
            )
            NookLog.log("place: retry with raw frames \(id.rawValue) x=\(retryFrame.midX) → \(retryX)")
            await ItemMover.cmdDrag(
                from: CGPoint(x: retryFrame.midX, y: 12),
                to: CGPoint(x: retryX, y: 12)
            )
            try? await Task.sleep(for: AppTiming.postDragSettle)
            after = await engine.snapshot()
            appState.updateSnapshot(after)
            placed = landedInSlot(after)
            NookLog.log("place: retry landed at x=\(after.items.first(where: { $0.id == liveID })?.frame?.midX ?? -1) verified=\(placed)")
        }
        // The drag clicked outside Nook — hand focus back to the settings
        // window. Retried: the dragged icon's app can win an activation race
        // hundreds of ms later and steal focus back from a single attempt.
        if appState.settingsWindowVisible {
            SettingsWindowController.shared.refocus()
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                SettingsWindowController.shared.refocus()
                try? await Task.sleep(for: .milliseconds(500))
                SettingsWindowController.shared.refocus()
            }
        }
        return placed
    }
}
