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
    private(set) var snapshot: EngineSnapshot?
    private(set) var accessibilityGranted = AXIsProcessTrusted()
    private(set) var engineCanHide = true
    /// Settings window tab. Owned here (not view @State) so every window
    /// open can reset it to General — reopening straight onto the Menu Bar
    /// tab fired its full-reveal preview unprompted.
    var settingsTab: SettingsTab = .general
    /// While the settings window is open, auto-rehide is fully suppressed —
    /// the user is mid-workflow between the editor and the bar, and nothing
    /// should collapse under them. Closing the window re-conceals.
    var settingsWindowVisible = false {
        didSet {
            guard oldValue != settingsWindowVisible else { return }
            if !settingsWindowVisible {
                applyPointerDisplayPolicyAfterDismissal()
            }
        }
    }

    /// Per-display behavior is "the display the pointer is on wins" — this is
    /// that display's setting. Every path that could conceal the bar must
    /// consult it; reveal-side crossings live in MenuBarBandMonitor.
    var pointerDisplayBehavior: DisplayBehavior {
        settings.behavior(forDisplayUUID: NSScreen.underPointer?.displayUUIDString)
    }

    @ObservationIgnored private lazy var placement = PlacementController(appState: self, engine: engine)
    @ObservationIgnored private lazy var transitions = TransitionCoordinator(appState: self, engine: engine)
    private var rehide = RehideStateMachine()
    private var rehideTimer: Timer?
    private var statusItem: NookStatusItem?
    private var separators: SeparatorManager?
    private var extras: ExtrasManager?
    private var bandMonitor: MenuBarBandMonitor?
    private var hotkey: HotkeyManager?
    private var eventTask: Task<Void, Never>?

    // MARK: - Lifecycle

    /// Boot sequence. ORDER IS LOAD-BEARING:
    /// migrations → policy/updater → onboarding gate → bar items (separators
    /// before extras; extras sync reads the media-controls migration) →
    /// monitors → event pump → async engine boot. Inside the engine boot:
    /// `waitForOwnItemAdoption` runs BEFORE `engine.start` (items registering
    /// under an active assertion park offscreen), `registerNewItems` before
    /// `setModel` (routing must precede the first converge),
    /// `flushPendingPlacements` after `setModel`, and the launch conceal
    /// precedes the display-policy reveal so the policy lands on a settled bar.
    func start() {
        wireTransitionSettleCallbacks()
        runOneShotMigrations()
        applyPolicyAndStartUpdater()
        presentOnboardingIfNeeded()
        buildBarItems()
        startMonitors()
        startEngineEventPump()
        bootEngine()
    }

    private func wireTransitionSettleCallbacks() {
        transitions.onRevealSettled = { [weak self] in
            guard let self else { return }
            dispatch(rehide.handle(.transitionSettled))
            settleCatchUp()
            // Newcomers routed into a then-concealed section finally
            // have measurable neighbors — walk them to their slot.
            placement.flushPendingPlacements()
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
        transitions.onConcealSettled = { [weak self] in
            guard let self else { return }
            dispatch(rehide.handle(.transitionSettled))
            settleCatchUp()
        }
    }

    private func runOneShotMigrations() {
        // One-shot: snappier hover default (0.2 → 0.1) for stores saved
        // before the default changed.
        if !UserDefaults.standard.bool(forKey: "nook.migratedHoverDelay01"),
           abs(settings.revealTriggers.hoverDelay - 0.2) < 0.011 {
            settings.revealTriggers.hoverDelay = 0.1
            settings.save()
        }
        UserDefaults.standard.set(true, forKey: "nook.migratedHoverDelay01")

        // Migrate the model to canonical (bundle-level) keys — collapses any
        // title-variant twin entries left by older builds.
        settings.sectionModel.canonicalize()
        settings.save()
    }

    private func applyPolicyAndStartUpdater() {
        rehide.policy = settings.rehidePolicy
        engineCanHide = engine.capabilities.canHide
        NookLog.log("start: axTrusted=\(AXIsProcessTrusted()) canHide=\(engineCanHide) assignments=\(settings.sectionModel.assignments.count)")
        SparkleController.shared.start()
    }

    private func presentOnboardingIfNeeded() {
        if !accessibilityGranted || !settings.onboardingCompleted {
            OnboardingController.shared.present(appState: self)
        }
    }

    private func buildBarItems() {
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
    }

    private func startMonitors() {
        let bandMonitor = MenuBarBandMonitor(appState: self)
        bandMonitor.start()
        self.bandMonitor = bandMonitor

        let hotkey = HotkeyManager { [weak self] in
            self?.toggle(reason: .hotkey)
        }
        hotkey.register(settings.hotkey)
        registeredHotkey = settings.hotkey
        self.hotkey = hotkey
    }

    private func startEngineEventPump() {
        eventTask = Task { [weak self] in
            guard let events = self?.engine.events else { return }
            for await event in events {
                self?.handle(engineEvent: event)
            }
        }
    }

    private func bootEngine() {
        Task {
            // The agent DEFERS adopting newly registered status items while
            // an assessment assertion is active (verified live 2026-08-21: a
            // fresh item parks offscreen until no assertion holds, then lands
            // instantly). Nook's own items re-register at every launch, and
            // the first converge would assert before adoption lands — parking
            // them for the whole session.
            await waitForOwnItemAdoption()
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
            placement.pendingPlacements.formUnion(launchNewItems)
            await engine.setModel(settings.sectionModel)
            // Visible-destined newcomers place right away (the flush filter
            // passes them without a reveal); concealed ones wait for one.
            placement.flushPendingPlacements()
            updateSnapshot(await engine.snapshot())
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

    /// Bounded poll until the engine reports swap-quiet for `interval` — the
    /// agent animates each swap, so quiet means the bar has stopped moving.
    func waitUntilQuiesced(
        interval: TimeInterval, deadline: TimeInterval, poll: Duration
    ) async {
        let by = Date().addingTimeInterval(deadline)
        while Date() < by, await !engine.quiesced(for: interval) {
            try? await Task.sleep(for: poll)
        }
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
        separators?.sync(with: settings.separators)
        // Newly toggled-on extras get hosted wherever macOS pleases (left end
        // of the trailing area) — physically place them into their section
        // like any editor move would.
        let previousExtraIDs = Set(extras?.managedItemIDs ?? [])
        extras?.sync(with: settings.extraItems)
        let newExtraIDs = Set(extras?.managedItemIDs ?? []).subtracting(previousExtraIDs)
        if !newExtraIDs.isEmpty {
            Task {
                try? await Task.sleep(for: AppTiming.newExtraPlacementDelay)
                for id in newExtraIDs {
                    await placement.physicallyPlace(id, in: settings.sectionModel.section(of: id))
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

    /// Settings-window close, tidy end, editor-tab close: the pointer
    /// display's policy decides between conceal and reveal — an unconditional
    /// conceal here collapsed the bar even on "always show everything"
    /// displays.
    func applyPointerDisplayPolicyAfterDismissal() {
        if pointerDisplayBehavior == .alwaysShowAll {
            reveal([.hidden], reason: .displayPolicy)
        } else {
            concealNow()
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
        // The model keys on canonical IDs; `id` arrives as a real bar item
        // (drag payload) and may be any title-variant of its bundle.
        let key = id.sectionKey
        var model = settings.sectionModel
        if section == .visible {
            model.assignments.removeValue(forKey: key)
        } else {
            model.assignments[key] = section
        }
        for sectionKey in model.order.keys {
            model.order[sectionKey]?.removeAll { $0 == key }
        }
        var order = model.order[section] ?? currentOrder(in: section)
        order.removeAll { $0 == key }
        if let beforeKey = beforeID?.sectionKey, let index = order.firstIndex(of: beforeKey) {
            order.insert(key, at: index)
        } else {
            order.append(key)
        }
        model.order[section] = order
        settings.sectionModel = model
        settings.save()
        // A deliberate editor drop supersedes any queued newcomer placement.
        placement.pendingPlacements.remove(id)
        NookLog.log("editor: move \(id.rawValue) → \(section) before=\(beforeID?.rawValue ?? "end")")
        // Extras visibility applies via the engine's reflow companion during
        // the converge below — same reflow, same motion as everything else.
        Task {
            await engine.setModel(model)
            // EVERY item moves via the synthetic ⌘-drag — the only mover the
            // agent honors. Live third-party order lives in the client
            // processes' own registrations (proven 2026-08-21: plist rebuilds
            // + agent restarts + conceal/reveal cycles never re-slot a live
            // item; a real ⌘-drag survives restarts with no disk record).
            // The plist hint still seeds slots for FUTURE fresh
            // registrations (app relaunches, brand-new items).
            await engine.writeOrderHint()
            await placement.physicallyPlace(id, in: section)
        }
    }

    /// Places the icon at its exact slot: between its new neighbors in the
    /// section's order (midpoint of their real frames), falling back to the
    /// section zone edge when it has no neighbors. Waits for the bar to settle
    /// first — measuring mid-reflow grabs stale coordinates, and a synthetic
    /// ⌘-drag released in the wrong place can fire system gestures.
    /// Dynamic extras (camera/mic indicator) re-enter layout when their
    /// hardware activates, parked wherever the agent decides — walk them back
    /// to their model slot. Own-process drags freeze the bar (raw-frame
    /// mode), and the placement chain no-ops when already in position.
    func placeDynamicExtra(_ id: ItemID) async {
        await placement.physicallyPlace(id, in: settings.sectionModel.section(of: id))
    }

    /// Nook's chevron item in a snapshot — the visible/hidden boundary marker
    /// (never an extra or separator).
    func nookChevronItem(in snap: EngineSnapshot) -> ObservedItem? {
        let nookBundle = Bundle.main.bundleIdentifier ?? NookBundle.fallbackID
        return snap.items.first(where: {
            $0.id.bundleID == nookBundle
                && !MenuBarPolicy.isNookExtraID($0.id)
                && !$0.id.rawValue.contains("Separator")
        })
    }

    /// The on-screen left-to-right order of a section right now (fallback when
    /// no explicit order exists yet).
    func currentOrder(in section: NookCore.Section) -> [ItemID] {
        // Order arrays hold canonical keys; tiles carry real item IDs.
        editorItems(in: section).map(\.id.sectionKey)
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
            try? await Task.sleep(for: AppTiming.tidyRevealWait)
            // Drag walk, left→right through the desired global order — the
            // synthetic ⌘-drag is the only mover the agent honors for live
            // items (see moveItem). Already-placed items skip cheaply; each
            // drag measures against the items the walk just settled.
            await engine.writeOrderHint()
            for section in [NookCore.Section.alwaysHidden, .hidden, .visible] {
                for item in editorItems(in: section) {
                    await placement.physicallyPlace(item.id, in: section)
                }
            }
            NookLog.log("tidy: done")
            tidying = false
            if !settingsWindowVisible {
                applyPointerDisplayPolicyAfterDismissal()
            }
        }
    }

    // (Alias healing removed: the model keys on ItemID.sectionKey — bundle-
    // level for third parties — so AX title drift can no longer strand
    // assignments or order entries under stale tags.)

    /// The layout editor's board for a section — see EditorItemsBuilder.
    /// Running-app lookups are memoized per call: the builder consults them
    /// per concealed/stored item, and each LaunchServices query is expensive.
    func editorItems(in section: NookCore.Section) -> [ObservedItem] {
        var memo: [String: NSRunningApplication?] = [:]
        func app(_ bundle: String) -> NSRunningApplication? {
            if let cached = memo[bundle] { return cached }
            let found = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
            memo[bundle] = found
            return found
        }
        return EditorItemsBuilder.build(
            section: section,
            snapshotItems: snapshot?.items ?? [],
            concealed: snapshot?.concealed ?? [],
            extraItems: settings.extraItems,
            separators: settings.separators,
            model: settings.sectionModel,
            nookBundleID: Bundle.main.bundleIdentifier ?? NookBundle.fallbackID,
            isRunning: { app($0) != nil },
            appName: { app($0)?.localizedName }
        )
    }

    // MARK: - Effects

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

    var currentRevealedSections: Set<NookCore.Section> {
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
                transitions.performReveal(sections)
            case .conceal:
                transitions.performConceal()
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
                    self.scheduleRehideTimer(at: Date().addingTimeInterval(AppTiming.rehideDeferRearm))
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
                guard retry < AppTiming.adoptMaxDeferrals else {
                    NookLog.log("adopt: gave up after \(retry) deferrals")
                    return
                }
                try? await Task.sleep(for: AppTiming.adoptDeferralDelay)
                adoptSectionsFromBar(retry: retry + 1)
                return
            }
            let snap = await engine.snapshot()
            updateSnapshot(snap)
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

    var isTransitioning: Bool {
        if case .transitioning = rehide.state { return true }
        return false
    }

    /// The band monitor skips drag-end adoption for Nook's own synthetic
    /// drags — see PlacementController.syntheticDragInFlight.
    var syntheticDragInFlight: Bool { placement.syntheticDragInFlight }

    /// The one write path for the engine snapshot mirror (PlacementController
    /// and engine-event handling route through here). Content-gated: every
    /// assignment fires @Observable invalidation (re-running the editor
    /// pipeline while settings is open), and most snapshots differ only by
    /// `takenAt`.
    func updateSnapshot(_ snap: EngineSnapshot) {
        guard snapshot?.contentEquals(snap) != true else { return }
        snapshot = snap
        bundleCounts = snap.items.reduce(into: [:]) { counts, item in
            guard let bundle = item.id.bundleID else { return }
            counts[bundle, default: 0] += 1
        }
    }

    /// Live items per bundle — the editor's sibling badge reads this instead
    /// of scanning the whole snapshot per tile.
    private(set) var bundleCounts: [String: Int] = [:]

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
        let nookBundle = Bundle.main.bundleIdentifier ?? NookBundle.fallbackID
        let candidates = snap.items.map(\.id).filter {
            guard let bundle = $0.bundleID else { return false }
            return bundle != nookBundle && !MenuBarPolicy.isUnmanagedAppleBundle(bundle)
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
        return candidates.filter {
            $0.bundleID.map(added.contains) == true
        }
    }

    private func adopt(from snap: EngineSnapshot) {
        guard settings.showStatusItem else { return }
        // adoptSectionsFromBar defers while transitioning/settling; this is
        // the last line of defense if called on a stale path.
        guard !isTransitioning else { return }
        guard let result = BarAdoption.reconcile(
            items: snap.items.map { (id: $0.id, minX: $0.frame?.minX) },
            model: settings.sectionModel,
            previousZones: lastAdoptionZones,
            nookBundleID: Bundle.main.bundleIdentifier ?? NookBundle.fallbackID
        ) else { return }
        for line in result.log { NookLog.log(line) }
        lastAdoptionZones = result.zones
        if result.changed {
            settings.sectionModel = result.model
            settings.save()
            Task { await engine.setModel(result.model) }
        }
    }

    /// Bounded wait for Nook's own separators/extras to appear in the agent's
    /// AX tree before the engine may assert (see launch Task). All items are
    /// still isVisible at this point — hiding happens via the reflow
    /// companion after the engine starts.
    private func waitForOwnItemAdoption() async {
        // Only visible-section items count: hidden-section separators/extras
        // are width-collapsed at first apply and never enter the AX tree, so
        // expecting them would guarantee the timeout.
        var expected = Set(
            settings.separators.map { SeparatorManager.itemID(for: $0) }
                .filter { settings.sectionModel.section(of: $0) == .visible }
        )
        for spec in settings.extraItems where spec.kind == .mediaControls {
            let id = ExtrasManager.itemID(for: spec)
            if settings.sectionModel.section(of: id) == .visible {
                expected.insert(id)
            }
        }
        guard !expected.isEmpty else { return }
        let deadline = Date.now.addingTimeInterval(8)
        while Date.now < deadline {
            let observed = Set(await engine.snapshot().items.map(\.id))
            if expected.subtracting(observed).isEmpty {
                NookLog.log("start: own items adopted (\(expected.count))")
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        NookLog.log("start: own-item adoption timeout — continuing without \(expected.count) item(s)")
    }

    private func handle(engineEvent: EngineEvent) {
        switch engineEvent {
        case .externalOrderChange:
            adoptSectionsFromBar()
            Task { updateSnapshot(await engine.snapshot()) }
        case .itemsChanged:
            // Route never-seen bundles to the configured new-items section,
            // then re-converge so the change (or a known bundle rejoining the
            // allowlist) takes effect.
            Task {
                let newItems = registerNewItems(from: await engine.snapshot())
                placement.pendingPlacements.formUnion(newItems)
                await engine.setModel(settings.sectionModel)
                // Visible-destined newcomers place right away; concealed
                // destinations stay queued until a full reveal makes their
                // slot deterministic.
                placement.flushPendingPlacements()
                updateSnapshot(await engine.snapshot())
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
