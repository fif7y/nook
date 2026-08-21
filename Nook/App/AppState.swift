// AppState.swift
// Root composition: owns the engine, the rehide state machine, settings, and
// the status item. All UI-facing state is @Observable.

import AppKit
import NookCore
import NookEngine
import SwiftUI

@Observable
final class AppState {
    let engine = EngineGoldenGate()
    var settings = SettingsStore.load()
    private(set) var snapshot: EngineSnapshot? {
        didSet { healAliasIDs() }
    }
    private(set) var accessibilityGranted = AXIsProcessTrusted()
    /// Bumped when the bar-glyph capture cache gains fresh entries —
    /// ItemImageCache is not observable, so editor tiles read this to
    /// re-render once better captures land.
    var iconCacheVersion = 0
    private(set) var engineCanHide = true
    /// While the settings window is open, auto-rehide is fully suppressed —
    /// the user is mid-workflow between the editor and the bar, and nothing
    /// should collapse under them. Closing the window re-conceals.
    var settingsWindowVisible = false {
        didSet {
            guard oldValue != settingsWindowVisible else { return }
            if !settingsWindowVisible {
                // Closing settings re-applies the pointer display's policy —
                // an unconditional conceal here collapsed the bar even on
                // "always show everything" displays.
                if pointerDisplayBehavior == .alwaysShowAll {
                    reveal([.hidden], reason: .displayPolicy)
                } else {
                    concealNow()
                }
            }
        }
    }

    /// Per-display behavior is "the display the pointer is on wins" — this is
    /// that display's setting. Every path that could conceal the bar must
    /// consult it; reveal-side crossings live in MenuBarBandMonitor.
    var pointerDisplayBehavior: DisplayBehavior {
        settings.behavior(forDisplayUUID: NSScreen.underPointer?.displayUUIDString)
    }

    private var rehide = RehideStateMachine()
    private var rehideTimer: Timer?
    private var statusItem: NookStatusItem?
    private var separators: SeparatorManager?
    private var extras: ExtrasManager?
    private var bandMonitor: MenuBarBandMonitor?
    private var hotkey: HotkeyManager?
    private var eventTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func start() {
        // One-shot: snappier hover default (0.2 → 0.1) for stores saved
        // before the default changed.
        if !UserDefaults.standard.bool(forKey: "nook.migratedHoverDelay01"),
           abs(settings.revealTriggers.hoverDelay - 0.2) < 0.011 {
            settings.revealTriggers.hoverDelay = 0.1
            settings.save()
        }
        UserDefaults.standard.set(true, forKey: "nook.migratedHoverDelay01")

        rehide.policy = settings.rehidePolicy
        engineCanHide = engine.capabilities.canHide
        ItemImageCache.preferBarIcons = settings.editorIconStyle == .barIcons
        NookLog.log("start: axTrusted=\(AXIsProcessTrusted()) canHide=\(engineCanHide) assignments=\(settings.sectionModel.assignments.count)")
        SparkleController.shared.start()

        if !accessibilityGranted || !settings.onboardingCompleted {
            OnboardingController.shared.present(appState: self)
        }

        if settings.showStatusItem {
            statusItem = NookStatusItem(appState: self)
        }
        ConcealGhostOverlay.prewarmDisplay()
        separators = SeparatorManager(appState: self)
        separators?.sync(with: settings.separators)
        // Migration: early builds had a bare media-controls bool.
        if settings.showMediaControls, !settings.extraItems.contains(where: { $0.kind == .mediaControls }) {
            settings.extraItems.append(ExtraItemSpec(kind: .mediaControls))
            settings.showMediaControls = false
            settings.save()
        }
        extras = ExtrasManager(appState: self)
        extras?.sync(with: settings.extraItems)

        let bandMonitor = MenuBarBandMonitor(appState: self)
        bandMonitor.start()
        self.bandMonitor = bandMonitor

        let hotkey = HotkeyManager { [weak self] in
            self?.toggle(reason: .hotkey)
        }
        hotkey.register(settings.hotkey)
        registeredHotkey = settings.hotkey
        self.hotkey = hotkey

        eventTask = Task { [weak self] in
            guard let events = self?.engine.events else { return }
            for await event in events {
                self?.handle(engineEvent: event)
            }
        }

        Task {
            await engine.start()
            // Extras change size inside the same agent reflow as assertion
            // swaps — the only way their motion matches everything else's.
            await engine.setReflowCompanion { [weak self] revealed in
                guard let self else { return }
                NookLog.log("companion: fired revealed=\(revealed.map(\.rawValue).sorted())")
                self.extras?.apply(
                    model: self.settings.sectionModel,
                    revealed: revealed,
                    systemCameraPillVisible: self.systemCameraPillVisible
                )
                self.separators?.apply(
                    model: self.settings.sectionModel,
                    revealed: revealed
                )
            }
            await engine.setSteadyExtras(settings.hideSystemExtras)
            // Apps that first appeared while Nook wasn't running route to the
            // new-items section before the first converge. VISIBLE newcomers
            // get their placement drag now (still live-framed); concealed
            // destinations queue until a reveal makes them measurable.
            let launchNewItems = registerNewItems(from: await engine.snapshot())
            for id in launchNewItems {
                if settings.sectionModel.section(of: id) == .visible {
                    await physicallyPlace(id, in: .visible)
                } else {
                    pendingPlacements.insert(id)
                }
            }
            await engine.setModel(settings.sectionModel)
            snapshot = await engine.snapshot()
            // Startup state: everything the model says is hidden, is hidden.
            dispatch(rehide.handle(.concealRequested))
            // Launch baseline: the band monitor only applies display behavior
            // on crossings, so the display Nook launches under gets its
            // policy applied here (queued behind the conceal's settle).
            if pointerDisplayBehavior == .alwaysShowAll {
                reveal([.hidden], reason: .displayPolicy)
            }
        }
    }

    /// Synchronous best-effort teardown for app termination: dropping the
    /// assertion restores the user's menubar.
    func stopBlocking() {
        rehideTimer?.invalidate()
        eventTask?.cancel()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached { [engine] in
            await engine.stop()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    // MARK: - Intents (UI + monitors call these)

    func toggle(reason: RevealReason) {
        let effects = rehide.handle(.toggleRequested([.hidden], reason))
        NookLog.log("toggle(\(reason)) state=\(rehide.state) effects=\(effects)")
        dispatch(effects)
    }

    func reveal(_ sections: Set<NookCore.Section>, reason: RevealReason) {
        dispatch(rehide.handle(.revealRequested(sections, reason)))
    }

    func concealNow() {
        NookLog.log("concealNow state=\(rehide.state)")
        dispatch(rehide.handle(.concealRequested))
    }

    func rehideTriggered(_ trigger: RehideTrigger) {
        NookLog.log("rehideTrigger(\(trigger)) state=\(rehide.state)")
        dispatch(rehide.handle(.trigger(trigger)))
    }

    func pointerReturnedToBand() {
        dispatch(rehide.handle(.pointerReturned))
    }

    func pointerLeftBand() {
        dispatch(rehide.handle(.pointerLeft))
    }

    var isRevealed: Bool {
        if case .revealed = rehide.state { return true }
        return false
    }

    /// Revealed OR heading there — what the chevron should show.
    private var isRevealedOrRevealing: Bool {
        switch rehide.state {
        case .revealed: return true
        case .transitioning(_, queued: .reveal): return true
        case .transitioning(target: .reveal, queued: nil): return true
        default: return false
        }
    }

    /// Union of the on-screen frames about to conceal (main-display band
    /// only): everything assigned to a non-visible section that currently has
    /// a frame. Nil when nothing concealable is showing. Re-snapshots: AX
    /// lists freshly revealed items progressively, and the settle-time
    /// snapshot can be missing half the strip.
    private func concealStripFrames() async -> CGRect? {
        let snap = await engine.snapshot()
        var union: CGRect?
        var count = 0
        for item in snap.items {
            guard let frame = item.frame,
                  frame.minY > -5, frame.minY < 50,
                  settings.sectionModel.section(of: item.id) != .visible
            else { continue }
            count += 1
            union = union.map { $0.union(frame) } ?? frame
        }
        NookLog.log("strip: \(count) items → \(union.map { "\(Int($0.minX))..\(Int($0.maxX))" } ?? "nil")")
        return union
    }

    /// Post-settle catch-up: re-run the companion apply so anything that
    /// changed DURING the transition (media presence, camera pill, a converge
    /// that no-opped and never fired the companion) lands now. lastVisible
    /// guards make this a no-op when the companion already got it right.
    private func settleCatchUp() {
        extras?.apply(
            model: settings.sectionModel,
            revealed: currentRevealedSections,
            systemCameraPillVisible: systemCameraPillVisible
        )
        separators?.apply(model: settings.sectionModel, revealed: currentRevealedSections)
    }

    func openSettings() {
        SettingsWindowController.shared.show(appState: self)
    }

    func refreshAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    private var settingsApplyWork: Task<Void, Never>?
    private var registeredHotkey: HotkeySpec?

    /// Persist + apply a changed settings store. Cheap, latency-sensitive
    /// bits apply immediately; the save and the engine converge are debounced
    /// — slider drags call this per tick, and each un-debounced tick paid a
    /// JSON save plus a full AX-walking converge that concluded "no-op".
    func settingsChanged() {
        rehide.policy = settings.rehidePolicy
        if settings.showStatusItem, statusItem == nil {
            statusItem = NookStatusItem(appState: self)
        } else if !settings.showStatusItem {
            statusItem?.remove()
            statusItem = nil
        }
        // Re-registering unregisters first — a per-tick re-register left the
        // shortcut momentarily dead. Only touch it when it actually changed.
        if settings.hotkey != registeredHotkey {
            hotkey?.register(settings.hotkey)
            registeredHotkey = settings.hotkey
        }
        ItemImageCache.preferBarIcons = settings.editorIconStyle == .barIcons
        if settings.editorIconStyle == .barIcons {
            if !CGPreflightScreenCaptureAccess() {
                // System prompt (once); the style degrades to app icons until
                // granted — and macOS often applies the grant only after the
                // app relaunches.
                CGRequestScreenCaptureAccess()
            } else {
                captureStableBarGlyphs()
            }
        }
        separators?.sync(with: settings.separators)
        // Newly toggled-on extras get hosted wherever macOS pleases (left end
        // of the trailing area) — physically place them into their section
        // like any editor move would.
        let previousExtraIDs = Set(extras?.managedItemIDs ?? [])
        extras?.sync(with: settings.extraItems)
        let newExtraIDs = Set(extras?.managedItemIDs ?? []).subtracting(previousExtraIDs)
        if !newExtraIDs.isEmpty {
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                for id in newExtraIDs {
                    await physicallyPlace(id, in: settings.sectionModel.section(of: id))
                }
            }
        }
        settingsApplyWork?.cancel()
        settingsApplyWork = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.settings.save()
            await self.engine.setSteadyExtras(self.settings.hideSystemExtras)
            await self.engine.setModel(self.settings.sectionModel)
        }
    }

    /// A Displays-tab picker changed: apply the pointer display's new policy
    /// live. Only the reveal side acts here — while the settings window is
    /// open nothing collapses under the user (existing rule); the collapse
    /// side lands on window close or the next display crossing.
    func displayBehaviorEdited() {
        NookLog.log("displays: behavior edited, pointer display=\(pointerDisplayBehavior)")
        if pointerDisplayBehavior == .alwaysShowAll {
            reveal([.hidden], reason: .displayPolicy)
        }
    }

    // MARK: - Layout editor intents

    /// Move an item to `section`, inserted before `beforeID` (nil = append).
    /// Updates assignment + explicit order, then physically places the icon
    /// via a synthetic ⌘-drag (no agent restart).
    func moveItem(_ id: ItemID, to section: NookCore.Section, before beforeID: ItemID?) {
        var model = settings.sectionModel
        if section == .visible {
            model.assignments.removeValue(forKey: id)
        } else {
            model.assignments[id] = section
        }
        for key in model.order.keys {
            model.order[key]?.removeAll { $0 == id }
        }
        var order = model.order[section] ?? currentOrder(in: section)
        order.removeAll { $0 == id }
        if let beforeID, let index = order.firstIndex(of: beforeID) {
            order.insert(id, at: index)
        } else {
            order.append(id)
        }
        model.order[section] = order
        settings.sectionModel = model
        settings.save()
        // A deliberate editor drop supersedes any queued newcomer placement.
        pendingPlacements.remove(id)
        NookLog.log("editor: move \(id.rawValue) → \(section) before=\(beforeID?.rawValue ?? "end")")
        // Extras visibility applies via the engine's reflow companion during
        // the converge below — same reflow, same motion as everything else.
        Task {
            await engine.setModel(model)
            // Physically place the icon in its section's zone via a synthetic
            // ⌘-drag — the same native path a human drag takes, so the agent
            // animates and persists it with NO restart. Sections stack
            // left→right as [always-hidden][hidden][chevron][visible].
            await physicallyPlace(id, in: section)
        }
    }

    /// Places the icon at its exact slot: between its new neighbors in the
    /// section's order (midpoint of their real frames), falling back to the
    /// section zone edge when it has no neighbors. Waits for the bar to settle
    /// first — measuring mid-reflow grabs stale coordinates, and a synthetic
    /// ⌘-drag released in the wrong place can fire system gestures.
    /// Returns true when the icon was dragged into place (or verified already
    /// there) — false when placement had to be skipped (no frame, nothing to
    /// measure against), so callers can keep it queued for a retry.
    @discardableResult
    private func physicallyPlace(_ id: ItemID, in section: NookCore.Section) async -> Bool {
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

    /// Routed-but-not-yet-placed newcomers. A new icon spawns at the far left
    /// of the VISIBLE-at-that-moment items — but concealed cluster members
    /// rematerialize around it on reveal, stranding it mid-cluster (Figma
    /// landed between always-hidden icons). Placement into a concealed
    /// section can't be measured, so it waits here until a reveal gives the
    /// section live frames.
    private var pendingPlacements: Set<ItemID> = []

    /// Called on every reveal settle: place pending newcomers whose section
    /// is now measurable. Items meanwhile moved by the user (editor drop
    /// places immediately) just drop out of the queue.
    private var flushingPlacements = false

    private func flushPendingPlacements() {
        guard !pendingPlacements.isEmpty, !flushingPlacements else { return }
        let revealed = currentRevealedSections
        let ready = pendingPlacements.filter {
            let section = settings.sectionModel.section(of: $0)
            if section == .visible { return true }
            // Concealed-cluster slots are only trustworthy under a FULL
            // reveal — a drop between visible neighbors while a cluster is
            // concealed can land on the wrong side of its invisible members.
            return revealed.isSuperset(of: [.hidden, .alwaysHidden])
        }
        guard !ready.isEmpty else { return }
        flushingPlacements = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.flushingPlacements = false }
            // AX latency: concealed items regain frames hundreds of ms AFTER
            // the settle (a partial walk once produced a degenerate midpoint
            // exactly on the item's own center — "already at slot", queue
            // lost). Require two fresh walks to agree before measuring; if
            // the bar never stabilizes, keep the queue for the next settle.
            var walk = await engine.freshSnapshot()
            var stable = false
            for _ in 0..<5 {
                try? await Task.sleep(for: .milliseconds(180))
                let next = await engine.freshSnapshot()
                stable = next.items.count == walk.items.count
                    && next.items.allSatisfy { item in
                        walk.items.contains { $0.id == item.id && $0.frame == item.frame }
                    }
                walk = next
                if stable { break }
            }
            guard stable else {
                NookLog.log("place: bar never stabilized — pending queue kept")
                return
            }
            snapshot = walk
            for id in ready.sorted(by: { $0.rawValue < $1.rawValue }) {
                if await physicallyPlace(id, in: settings.sectionModel.section(of: id)) {
                    pendingPlacements.remove(id)
                }
            }
        }
    }

    private func physicallyPlaceNow(_ id: ItemID, in section: NookCore.Section) async -> Bool {
        try? await Task.sleep(for: .milliseconds(450))
        // Freshly-shown extras take a beat to be hosted — retry the lookup
        // briefly instead of giving up on the first stale snapshot.
        var snap = await engine.snapshot()
        snapshot = snap
        for _ in 0..<3 where !snap.items.contains(where: { $0.id == id && $0.frame != nil }) {
            try? await Task.sleep(for: .milliseconds(550))
            snap = await engine.snapshot()
            snapshot = snap
        }
        let nookBundle = Bundle.main.bundleIdentifier ?? "app.fif7y.Nook"
        guard
            let item = snap.items.first(where: { $0.id == id }),
            let frame = item.frame
        else {
            NookLog.log("place: no frame for \(id.rawValue) — skipping physical move (concealed?)")
            return false
        }
        guard let screen = NSScreen.screens.first else { return false }
        // Chevron is OPTIONAL: with the Nook icon hidden, live neighbor
        // frames alone anchor the target — only the no-neighbor fallbacks
        // and the final side clamp need the chevron.
        let chevronFrame = snap.items.first(where: {
            $0.id.bundleID == nookBundle
                && !Self.isNookExtraID($0.id)
                && !$0.id.rawValue.contains("Separator")
        })?.frame

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
        let globalOrder = editorItems(in: .alwaysHidden)
            + editorItems(in: .hidden)
            + editorItems(in: .visible)
        let index = globalOrder.firstIndex(where: { $0.id == id }) ?? globalOrder.count
        let leftNeighbor = globalOrder[..<index].reversed().compactMap(\.frame).first.map(lifted)
        let rightNeighbor = globalOrder[(min(index + 1, globalOrder.count))...].compactMap(\.frame).first.map(lifted)

        var targetX: CGFloat
        switch (leftNeighbor, rightNeighbor) {
        case (let left?, let right?) where left.maxX < right.minX:
            targetX = (left.maxX + right.minX) / 2
        case (let left?, _):
            targetX = left.maxX + 14
        case (_, let right?):
            targetX = right.minX - 14
        default:
            guard let chevronFrame else {
                NookLog.log("place: no live neighbors and no chevron for \(id.rawValue) — skipping")
                return false
            }
            let managedMinX = snap.items
                .filter { $0.id.bundleID?.hasPrefix("com.apple.") != true && !$0.id.isSystemModule }
                .compactMap(\.frame?.minX)
                .min() ?? chevronFrame.minX
            switch section {
            case .alwaysHidden: targetX = managedMinX - 20
            case .hidden: targetX = chevronFrame.minX - 15
            case .visible: targetX = chevronFrame.maxX + 25
            }
        }
        // Never approach screen corners (hot corners: Mission Control) or
        // leave the trailing status area.
        targetX = min(max(targetX, 200), screen.frame.maxX - 60)
        // The section's side of the chevron is a hard constraint — neighbor
        // midpoints can land across the boundary (e.g. first-of-Visible aims
        // "just left of its right neighbor", which is the chevron's far side).
        // Applied LAST: the corner floor once pushed a hidden-section target
        // right of a far-left chevron, dropping the item into the wrong side.
        if let chevronFrame {
            switch section {
            case .visible:
                targetX = max(targetX, chevronFrame.maxX + 12)
            case .hidden, .alwaysHidden:
                targetX = min(targetX, chevronFrame.minX - 12)
            }
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
        guard frame.minY > -5, frame.minY < 50,
              frame.midX > 0, frame.midX < screen.frame.maxX else {
            NookLog.log("place: source frame outside menu bar band (\(frame)) — skipping drag")
            return false
        }
        NookLog.log("place: dragging \(id.rawValue) x=\(frame.midX) → \(targetX) (section \(section))")
        await ItemMover.cmdDrag(
            from: CGPoint(x: frame.midX, y: 12),
            to: CGPoint(x: targetX, y: 12)
        )
        try? await Task.sleep(for: .milliseconds(300))
        let after = await engine.snapshot()
        snapshot = after
        if let newFrame = after.items.first(where: { $0.id == id })?.frame {
            NookLog.log("place: landed at x=\(newFrame.midX)")
        } else {
            NookLog.log("place: item not observable after drag")
        }
        // The drag clicked outside Nook — hand focus back to the settings
        // window. Retried: the dragged icon's app can win an activation race
        // hundreds of ms later and steal focus back from a single attempt.
        if settingsWindowVisible {
            SettingsWindowController.shared.refocus()
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                SettingsWindowController.shared.refocus()
                try? await Task.sleep(for: .milliseconds(500))
                SettingsWindowController.shared.refocus()
            }
        }
        return true
    }

    /// Capture bar glyphs once the bar is genuinely still: wait out the
    /// agent's slide animation, then require frame stability across two
    /// fresh AX walks — cropping against a moving (or stale-cached) frame
    /// set shifts every glyph one slot over (Velja wearing PopClip's icon).
    /// Unstable items are skipped; a later pass gets them.
    private func captureStableBarGlyphs() {
        Task { [engine, weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            let first = await engine.freshSnapshot()
            try? await Task.sleep(for: .milliseconds(120))
            let second = await engine.freshSnapshot()
            let stable = second.items.filter { item in
                first.items.contains { $0.id == item.id && $0.frame == item.frame }
            }
            await ItemImageCache.prewarmBarCaptures(items: stable)
            self?.iconCacheVersion += 1
        }
    }

    /// The on-screen left-to-right order of a section right now (fallback when
    /// no explicit order exists yet).
    func currentOrder(in section: NookCore.Section) -> [ItemID] {
        editorItems(in: section).map(\.id)
    }

    /// One-shot physical tidy: reveal everything, then walk the sections
    /// left→right and drag every out-of-place icon into its slot so the bar's
    /// physical order matches the sections ([always-hidden][hidden][visible]).
    /// Contiguity is what makes hide/reveal animations uniform — an icon that
    /// toggles mid-bar displaces its neighbors and reads as sliding.
    private(set) var tidying = false

    func tidyBar() {
        guard !tidying else { return }
        tidying = true
        NookLog.log("tidy: starting")
        reveal([.hidden, .alwaysHidden], reason: .settingsPreview)
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            // Two passes: the second verifies — correctly placed items no-op
            // inside the 10pt tolerance, only genuine misses re-drag.
            for pass in 1...2 {
                for section in [NookCore.Section.alwaysHidden, .hidden, .visible] {
                    for item in editorItems(in: section) {
                        await physicallyPlace(item.id, in: section)
                    }
                }
                NookLog.log("tidy: pass \(pass) complete")
            }
            NookLog.log("tidy: done")
            tidying = false
            if !settingsWindowVisible {
                // Same rule as settings-close: the pointer display's policy
                // decides — an unconditional conceal collapsed the bar on
                // "always show everything" displays.
                if pointerDisplayBehavior == .alwaysShowAll {
                    reveal([.hidden], reason: .displayPolicy)
                } else {
                    concealNow()
                }
            }
        }
    }

    /// MenuBarAgent derives item tags from AX titles, and those drift — the
    /// same Velja item has been "Item-0" and "Left and right arrows in a
    /// filled circle" on different days. Hiding is per-bundle, so a bundle is
    /// never half-live: a stored ID whose bundle HAS live items but which
    /// isn't itself live is a stale alias of the live one. Remap it so the
    /// section model (and every write keyed off it) tracks the current tag.
    private func healAliasIDs() {
        guard let snap = snapshot else { return }
        var model = settings.sectionModel
        let storedIDs = Set(model.assignments.keys).union(model.order.values.joined())
        let remaps = ItemIdentityResolver.aliasRemaps(
            storedIDs: storedIDs,
            liveIDs: snap.items.map(\.id),
            exemptBundles: EngineGoldenGate.identityExemptBundles
        )
        guard !remaps.isEmpty else { return }
        for (stored, liveID) in remaps {
            if let section = model.assignments.removeValue(forKey: stored),
               model.assignments[liveID] == nil {
                model.assignments[liveID] = section
            }
            for key in model.order.keys {
                guard var order = model.order[key], let index = order.firstIndex(of: stored) else { continue }
                if order.contains(liveID) {
                    order.remove(at: index)
                } else {
                    order[index] = liveID
                }
                model.order[key] = order
            }
            NookLog.log("heal: alias \(stored.rawValue) → \(liveID.rawValue)")
        }
        settings.sectionModel = model
        settings.save()
        Task { await engine.setModel(model) }
    }

    /// Items the layout editor shows for a section: third-party only (Apple
    /// items are out of scope), Nook's own items excluded, and CONCEALED items
    /// included — they drop out of AX observation but absolutely belong in the
    /// editor (frame nil, icon from the app bundle).
    func editorItems(in section: NookCore.Section) -> [ObservedItem] {
        var byID: [ItemID: ObservedItem] = [:]
        for item in snapshot?.items ?? [] {
            byID[item.id] = item
        }
        for id in snapshot?.concealed ?? [] where byID[id] == nil {
            let appName = id.bundleID.flatMap {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.localizedName
            }
            byID[id] = ObservedItem(id: id, frame: nil, appName: appName)
        }
        // Nook's extras are section-manageable (visibility-based hiding); when
        // hidden they're absent from AX, so ensure they're represented.
        for spec in settings.extraItems {
            let id = ExtrasManager.itemID(for: spec)
            if byID[id] == nil {
                byID[id] = ObservedItem(id: id, frame: nil, appName: spec.shortcutName ?? nil)
            }
        }
        // Separators too — same visibility-based hiding as extras.
        for spec in settings.separators {
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
            settings.sectionModel.assignments.filter { $0.value == section }.map(\.key)
        ).union(settings.sectionModel.order[section] ?? [])
        for id in stored where byID[id] == nil {
            guard let bundle = id.bundleID,
                  bundle != Bundle.main.bundleIdentifier,
                  !bundle.hasPrefix("com.apple."),
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
            else { continue }
            byID[id] = ObservedItem(id: id, frame: nil, appName: app.localizedName)
        }
        // Drop stale twins the concealed set may still remember: a bundle is
        // never half-concealed, so a frame-nil entry whose bundle has a live
        // item is an old alias, not a second icon. (Nook's own extras are
        // exempt — they legitimately mix live and hidden items.)
        let liveBundles = Set(
            (snapshot?.items ?? []).compactMap(\.id.bundleID)
        ).subtracting([Bundle.main.bundleIdentifier ?? ""])
        // Two frame-nil twins of one bundle (both "concealed") are one item
        // under a drifted tag plus its stale alias — the engine can't prune
        // the alias until the item is next observed live, so collapse here.
        let concealedTwinLoser = ItemIdentityResolver.concealedTwinLosers(
            concealedIDs: byID.values.filter { $0.frame == nil }.map(\.id),
            exemptBundles: EngineGoldenGate.identityExemptBundles,
            isAssigned: { settings.sectionModel.assignments[$0] != nil }
        )
        let all = byID.values.filter { item in
            if concealedTwinLoser.contains(item.id) { return false }
            if item.frame == nil,
               let bundle = item.id.bundleID,
               liveBundles.contains(bundle) {
                return false
            }
            guard !item.id.isSystemModule,
                  settings.sectionModel.section(of: item.id) == section
            else { return false }
            if item.id.bundleID == Bundle.main.bundleIdentifier {
                return Self.isNookExtraID(item.id)
            }
            if item.id.bundleID?.hasPrefix("com.apple.") == true {
                // Core system icons the assertion can individually control
                // (Sound, battery, Wi-Fi…) are manageable; the rest stay out.
                return EngineGoldenGate.systemItem(for: item.id) != nil
            }
            return true
        }
        let explicit = settings.sectionModel.order[section] ?? []
        return all.sorted { lhs, rhs in
            // The user's explicit order is authoritative — nothing outranks it.
            // (A left-pin experiment for extras once did, and it broke drag
            // ordering and Tidy alike.)
            let li = explicit.firstIndex(of: lhs.id) ?? Int.max
            let ri = explicit.firstIndex(of: rhs.id) ?? Int.max
            if li != ri { return li < ri }
            return (lhs.frame?.minX ?? .greatestFiniteMagnitude)
                < (rhs.frame?.minX ?? .greatestFiniteMagnitude)
        }
    }

    // MARK: - Effects

    /// True for Nook-owned proxy/extra items (NOT the chevron): they're
    /// section-manageable through their own visibility. Separators included —
    /// they live in sections and hide with them, extras-style.
    static func isNookExtraID(_ id: ItemID) -> Bool {
        let raw = id.rawValue
        return raw.contains("::Nook.")
            && !raw.contains("Nook.StatusItem")
    }

    /// Nook-owned items hide by their OWN visibility, not the assertion —
    /// asserting away Nook's bundle would take the chevron too.
    var revealedSectionsForExtras: Set<NookCore.Section> { currentRevealedSections }

    /// macOS force-shows its camera pill through the assertion while the
    /// camera is live; Nook's indicator defers to it to avoid duplication.
    var systemCameraPillVisible: Bool {
        (snapshot?.items ?? []).contains {
            $0.id.rawValue.contains("menuextra.audiovideo") && $0.frame != nil
        }
    }

    private var currentRevealedSections: Set<NookCore.Section> {
        switch rehide.state {
        case .revealed(let sections, _):
            return sections
        case .transitioning(target: .reveal(let sections, _), _):
            // Track the transition's destination so Nook-owned items appear
            // in the same swap as the assertion-managed ones.
            return sections
        default:
            return []
        }
    }

    private func dispatch(_ effects: [RehideEffect]) {
        // Extras are NOT applied here: the engine's reflow companion applies
        // them inside the converge so their size change shares the assertion
        // swap's reflow. Applying pre-reflow here put them on a second clock.
        // The chevron flips at transition START — settle-time flips read as an
        // unacknowledged click.
        defer { statusItem?.updateSymbol(revealed: isRevealedOrRevealing) }
        for effect in effects {
            switch effect {
            case .none:
                break
            case .reveal(let sections):
                Task {
                    NookLog.log("effect reveal \(sections) → engine")
                    await engine.reveal(sections)
                    snapshot = await engine.snapshot()
                    NookLog.log("effect reveal settled")
                    lastSettleAt = Date()
                    // Reveals are the only window where hidden items are
                    // capturable — refresh the bar-glyph cache opportunistically.
                    // Wait out the agent's slide animation, then require
                    // FRAME STABILITY across two fresh AX walks: the cached
                    // snapshot (or one mid-reflow) crops every glyph one slot
                    // over — Velja wearing PopClip's icon. Unstable items are
                    // skipped; a later pass gets them.
                    captureStableBarGlyphs()
                    dispatch(rehide.handle(.transitionSettled))
                    settleCatchUp()
                    // Newcomers routed into a then-concealed section finally
                    // have measurable neighbors — walk them to their slot.
                    flushPendingPlacements()
                    // Swipe-through hover: the pointer can be long gone by the
                    // time the reveal settles — armIfNeeded gave the FULL delay.
                    // Re-arm as a pointer-out so an accidental hover self-heals
                    // on the short clock. HOVER ONLY: deliberate reveals (click,
                    // hotkey) with the pointer elsewhere must keep the floor,
                    // not conceal instantly at rehideDelay 0.
                    if case .revealed(_, .hover) = rehide.state,
                       bandMonitor?.pointerCurrentlyInBand == false {
                        pointerLeftBand()
                    }
                }
            case .conceal:
                Task {
                    // Cover the strip BEFORE the swap: the agent pops
                    // concealed items with no animation, so the overlay is
                    // the hide animation. Fades once the swap has landed.
                    let ghost = await ConcealGhostOverlay.begin(over: await concealStripFrames())
                    NookLog.log("effect conceal → engine")
                    await engine.conceal()
                    snapshot = await engine.snapshot()
                    ghost?.fadeOut()
                    NookLog.log("effect conceal settled")
                    lastSettleAt = Date()
                    dispatch(rehide.handle(.transitionSettled))
                    settleCatchUp()
                }
            case .armTimer(let deadline):
                scheduleRehideTimer(at: deadline)
            case .cancelTimer:
                rehideTimer?.invalidate()
                rehideTimer = nil
            }
        }
    }

    /// Rehide fires only when the user has actually moved on: while the
    /// pointer is in the menubar band or over an elevated window (an open
    /// status-item menu or popover), the countdown quietly re-arms.
    private func scheduleRehideTimer(at deadline: Date) {
        rehideTimer?.invalidate()
        rehideTimer = Timer.scheduledTimer(
            withTimeInterval: max(0, deadline.timeIntervalSinceNow),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.settingsWindowVisible
                    || self.pointerDisplayBehavior == .alwaysShowAll
                    || self.bandMonitor?.shouldDeferRehide() == true {
                    self.scheduleRehideTimer(at: Date().addingTimeInterval(1.5))
                } else {
                    self.rehideTriggered(.delayExpired)
                }
            }
        }
    }

    /// Menubar-positional sections: Nook's own chevron is the visible/hidden
    /// boundary. Anything sitting LEFT of it (smaller AX x) is adopted into
    /// Hidden; right of it back to Visible. Uses live AX frames — NOT the
    /// agent's positions plist, which lists new items only lazily (M1 finding).
    /// Always-Hidden has no physical marker of its own; its live cluster IS
    /// the boundary — an item dropped among/left of always-hidden members
    /// (only visible during a full reveal) adopts in, one dropped among the
    /// hidden cluster adopts out.
    func adoptSectionsFromBar(retry: Int = 0) {
        Task {
            // Mid-transition bars give false frames — defer briefly. (Only
            // in-flight transitions block; a settled bar has stable frames.
            // The old post-settle quiet window starved adoption entirely.)
            if isTransitioning {
                guard retry < 10 else {
                    NookLog.log("adopt: gave up after \(retry) deferrals")
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
                adoptSectionsFromBar(retry: retry + 1)
                return
            }
            let snap = await engine.snapshot()
            snapshot = snap
            NookLog.log("adopt: pass (retry=\(retry), items=\(snap.items.count))")
            adopt(from: snap)
        }
    }

    /// Which zone each item sat in at the last pass. Reflows shift every
    /// frame but never an item's relative position — only a real user drag
    /// does. That makes zone-CHANGE the safe adoption trigger: a
    /// settings-assigned item still sitting in its old zone is never
    /// "corrected" back.
    private var lastAdoptionZones: [String: NookCore.Section] = [:]
    /// Set on every reveal/conceal settle; adoption holds off while the bar is
    /// mid-reflow.
    private var lastSettleAt: Date = .distantPast

    private var isTransitioning: Bool {
        if case .transitioning = rehide.state { return true }
        return false
    }

    /// New-app routing: any third-party bundle never seen before gets its
    /// items assigned to `newItemsDestination`. Runs BEFORE converge so the
    /// engine never shows a new icon the user asked to have hidden. The very
    /// first pass (empty known set) is a silent baseline — nothing moves.
    /// Returns the new items (empty on baseline) so callers can physically
    /// slot them: macOS spawns new icons at the far left of the status area —
    /// inside the hidden/always-hidden zone — so without a placement drag a
    /// model-visible newcomer flaps sides of the chevron on every reveal.
    @discardableResult
    private func registerNewItems(from snap: EngineSnapshot) -> [ItemID] {
        let nookBundle = Bundle.main.bundleIdentifier ?? "app.fif7y.Nook"
        let candidates = snap.items.map(\.id).filter {
            guard let bundle = $0.bundleID else { return false }
            return bundle != nookBundle && !bundle.hasPrefix("com.apple.")
        }
        var model = settings.sectionModel
        let before = model.knownBundles
        guard model.registerObservedItems(candidates) else { return [] }
        let added = model.knownBundles.subtracting(before)
        NookLog.log(
            before.isEmpty
                ? "register: baseline \(model.knownBundles.count) bundle(s)"
                : "register: new \(added.sorted().joined(separator: ", ")) → \(model.newItemsDestination.rawValue)"
        )
        settings.sectionModel = model
        settings.save()
        guard !before.isEmpty else { return [] }
        return candidates.filter { $0.bundleID.map(added.contains) == true }
    }

    private func adopt(from snap: EngineSnapshot) {
        guard settings.showStatusItem else { return }
        // adoptSectionsFromBar defers while transitioning/settling; this is
        // the last line of defense if called on a stale path.
        guard !isTransitioning else { return }
        let nookBundle = Bundle.main.bundleIdentifier ?? "app.fif7y.Nook"
        guard
            let chevron = snap.items.first(where: {
                $0.id.bundleID == nookBundle
                    && !Self.isNookExtraID($0.id)
                    && !$0.id.rawValue.contains("Separator")
            }),
            let chevronX = chevron.frame?.minX
        else { return }

        let isFirstPass = lastAdoptionZones.isEmpty
        NookLog.log("adopt: chevronX=\(chevronX) firstPass=\(isFirstPass) trackedZones=\(lastAdoptionZones.count)")
        var model = settings.sectionModel
        var changed = false
        // Cluster edges from the PRE-adoption model: the always-hidden and
        // hidden members' live frames (only present during a full reveal).
        // Self-excluded per item below so an item never bounds itself.
        let clusterX: [(id: ItemID, x: CGFloat, section: NookCore.Section)] = snap.items.compactMap {
            guard let x = $0.frame?.minX else { return nil }
            let section = model.section(of: $0.id)
            guard section != .visible else { return nil }
            return ($0.id, x, section)
        }
        for item in snap.items {
            guard let bundle = item.id.bundleID,
                  bundle != nookBundle || Self.isNookExtraID(item.id),
                  !bundle.hasPrefix("com.apple."),
                  let frame = item.frame
            else { continue }
            let current = model.section(of: item.id)
            let zone: NookCore.Section
            var confident = true
            if frame.minX >= chevronX {
                zone = .visible
            } else {
                let ahMax = clusterX
                    .filter { $0.section == .alwaysHidden && $0.id != item.id }
                    .map(\.x).max()
                let hMin = clusterX
                    .filter { $0.section == .hidden && $0.id != item.id }
                    .map(\.x).min()
                if let ahMax, frame.minX < ahMax {
                    zone = .alwaysHidden
                } else if let hMin, frame.minX > hMin {
                    zone = .hidden
                } else {
                    // Between the clusters, or a cluster is concealed and
                    // unmeasurable — ambiguous, so the model's word stands
                    // (an always-hidden item stays; anything else is hidden).
                    zone = current == .alwaysHidden ? .alwaysHidden : .hidden
                    confident = false
                }
            }
            let previousZone = lastAdoptionZones[item.id.rawValue]
            // A guessed zone must never become a baseline: a new app lands
            // far left, reads "hidden" while concealed (ambiguous) and
            // "alwaysHidden" on the next full reveal — that flap would adopt
            // as if the user dragged it. Only measured zones persist.
            if confident { lastAdoptionZones[item.id.rawValue] = zone }
            // First sighting establishes a baseline; only a zone CHANGE adopts.
            guard !isFirstPass, let previousZone, previousZone != zone else { continue }
            guard zone != current else { continue }
            if zone == .visible {
                model.assignments.removeValue(forKey: item.id)
            } else {
                model.assignments[item.id] = zone
            }
            NookLog.log("adopt: \(item.id.rawValue) → \(zone)")
            changed = true
        }
        // Within-section order: the editor treats the explicit stored order as
        // authoritative, so a manual ⌘-drag would otherwise show at its OLD
        // slot forever. Fold the bar's left-to-right reality back in: entries
        // with live frames reorder to match X, frame-nil (concealed) entries
        // hold their slots, entries whose section changed drop out, and
        // newly-adopted members slot in by X. Safe here because adopt only
        // runs on a settled bar — reflows shift frames but preserve X order.
        let liveX: [ItemID: CGFloat] = snap.items.reduce(into: [:]) {
            if let x = $1.frame?.minX { $0[$1.id] = x }
        }
        for (section, order) in model.order {
            var newOrder = order.filter { model.section(of: $0) == section }
            let liveSlots = newOrder.indices.filter { liveX[newOrder[$0]] != nil }
            let sortedLive = liveSlots.map { newOrder[$0] }.sorted { liveX[$0]! < liveX[$1]! }
            for (offset, slot) in liveSlots.enumerated() { newOrder[slot] = sortedLive[offset] }
            let known = Set(newOrder)
            let missing = snap.items.filter {
                $0.frame != nil && !known.contains($0.id)
                    && model.section(of: $0.id) == section
                    && !$0.id.isSystemModule
                    && $0.id.bundleID?.hasPrefix("com.apple.") != true
                    && ($0.id.bundleID != nookBundle || Self.isNookExtraID($0.id))
            }
            for item in missing.sorted(by: { liveX[$0.id]! < liveX[$1.id]! }) {
                let x = liveX[item.id]!
                let insertAfter = newOrder.lastIndex { liveX[$0].map { $0 < x } == true }
                newOrder.insert(item.id, at: insertAfter.map { $0 + 1 } ?? 0)
            }
            if newOrder != order {
                model.order[section] = newOrder
                NookLog.log("adopt: \(section) order reconciled from bar")
                changed = true
            }
        }
        if changed {
            settings.sectionModel = model
            settings.save()
            Task { await engine.setModel(model) }
        }
    }

    private func handle(engineEvent: EngineEvent) {
        switch engineEvent {
        case .externalOrderChange:
            adoptSectionsFromBar()
            Task { snapshot = await engine.snapshot() }
        case .itemsChanged:
            // Route never-seen bundles to the configured new-items section,
            // then re-converge so the change (or a known bundle rejoining the
            // allowlist) takes effect.
            Task {
                let newItems = registerNewItems(from: await engine.snapshot())
                // VISIBLE newcomers get their placement drag immediately —
                // it must happen while they still have live frames, since
                // after the converge a concealed item can't be measured or
                // dragged. Concealed destinations queue for the next reveal:
                // their cluster has no frames to measure against right now.
                for id in newItems {
                    if settings.sectionModel.section(of: id) == .visible {
                        await physicallyPlace(id, in: .visible)
                    } else {
                        pendingPlacements.insert(id)
                    }
                }
                await engine.setModel(settings.sectionModel)
                snapshot = await engine.snapshot()
                // The system camera pill appearing/vanishing is an
                // itemsChanged — Nook's indicator defers to it live. But NOT
                // mid-transition: every reveal/conceal fires itemsChanged
                // (concealed items drop out of AX), and applying here would
                // animate extras on a second clock. The settle catch-up in
                // dispatch covers the transition case.
                guard !isTransitioning else { return }
                extras?.apply(model: settings.sectionModel, revealed: currentRevealedSections, systemCameraPillVisible: systemCameraPillVisible)
                separators?.apply(model: settings.sectionModel, revealed: currentRevealedSections)
            }
        case .assertionTornDown:
            // Recovery: force a real converge. (A `.concealRequested` through
            // the rehide machine was a no-op from `.concealed` — the exact
            // state an external teardown usually finds us in.)
            Task { await engine.setModel(settings.sectionModel) }
        case .availabilityChanged(let available):
            engineCanHide = available
        case .convergeFailed:
            // Surfaced in Settings as a banner; never silently retried in a loop.
            break
        }
    }
}
