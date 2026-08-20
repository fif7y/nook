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
    /// While the settings window is open, auto-rehide is fully suppressed —
    /// the user is mid-workflow between the editor and the bar, and nothing
    /// should collapse under them. Closing the window re-conceals.
    var settingsWindowVisible = false {
        didSet {
            guard oldValue != settingsWindowVisible else { return }
            if !settingsWindowVisible {
                concealNow()
            }
        }
    }

    private var rehide = RehideStateMachine()
    private var rehideTimer: Timer?
    private var statusItem: NookStatusItem?
    private var separators: SeparatorManager?
    private var bandMonitor: MenuBarBandMonitor?
    private var hotkey: HotkeyManager?
    private var eventTask: Task<Void, Never>?
    private var applyOrderWork: Task<Void, Never>?

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
        NookLog.log("start: axTrusted=\(AXIsProcessTrusted()) canHide=\(engineCanHide) assignments=\(settings.sectionModel.assignments.count)")

        if !accessibilityGranted || !settings.onboardingCompleted {
            OnboardingController.shared.present(appState: self)
        }

        if settings.showStatusItem {
            statusItem = NookStatusItem(appState: self)
        }
        separators = SeparatorManager(appState: self)
        separators?.sync(with: settings.separators)

        let bandMonitor = MenuBarBandMonitor(appState: self)
        bandMonitor.start()
        self.bandMonitor = bandMonitor

        let hotkey = HotkeyManager { [weak self] in
            self?.toggle(reason: .hotkey)
        }
        hotkey.register(settings.hotkey)
        self.hotkey = hotkey

        eventTask = Task { [weak self] in
            guard let events = self?.engine.events else { return }
            for await event in events {
                self?.handle(engineEvent: event)
            }
        }

        Task {
            await engine.start()
            await engine.setSteadyExtras(settings.hideSystemExtras)
            await engine.setModel(settings.sectionModel)
            snapshot = await engine.snapshot()
            // Startup state: everything the model says is hidden, is hidden.
            dispatch(rehide.handle(.concealRequested))
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
        dispatch(rehide.handle(.concealRequested))
    }

    func rehideTriggered(_ trigger: RehideTrigger) {
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

    func openSettings() {
        SettingsWindowController.shared.show(appState: self)
    }

    func refreshAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    /// Persist + apply a changed settings store.
    func settingsChanged() {
        settings.save()
        rehide.policy = settings.rehidePolicy
        if settings.showStatusItem, statusItem == nil {
            statusItem = NookStatusItem(appState: self)
        } else if !settings.showStatusItem {
            statusItem?.remove()
            statusItem = nil
        }
        hotkey?.register(settings.hotkey)
        separators?.sync(with: settings.separators)
        Task {
            await engine.setSteadyExtras(settings.hideSystemExtras)
            await engine.setModel(settings.sectionModel)
        }
    }

    // MARK: - Layout editor intents

    /// Move an item to `section`, inserted before `beforeID` (nil = append).
    /// Updates assignment + explicit order, then schedules a physical
    /// order-apply (debounced — the agent restart blinks the bar once).
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
        NookLog.log("editor: move \(id.rawValue) → \(section) before=\(beforeID?.rawValue ?? "end")")
        Task {
            await engine.setModel(model)
            // Physically place the icon in its section's zone via a synthetic
            // ⌘-drag — the same native path a human drag takes, so the agent
            // animates and persists it with NO restart. Sections stack
            // left→right as [always-hidden][hidden][chevron][visible].
            await physicallyPlace(id, in: section)
        }
    }

    /// Target zones are computed from live AX frames: always-hidden lands left
    /// of every managed item, hidden lands just left of the chevron, visible
    /// just right of it.
    private func physicallyPlace(_ id: ItemID, in section: NookCore.Section) async {
        let snap = await engine.snapshot()
        snapshot = snap
        let nookBundle = Bundle.main.bundleIdentifier ?? "app.fif7y.Nook"
        guard
            let item = snap.items.first(where: { $0.id == id }),
            let frame = item.frame,
            let chevron = snap.items.first(where: {
                $0.id.bundleID == nookBundle && !$0.id.rawValue.contains("Separator")
            }),
            let chevronFrame = chevron.frame
        else {
            NookLog.log("place: no frame for \(id.rawValue) — skipping physical move (concealed?)")
            return
        }
        let managedMinX = snap.items
            .filter { $0.id.bundleID?.hasPrefix("com.apple.") != true && !$0.id.isSystemModule }
            .compactMap(\.frame?.minX)
            .min() ?? chevronFrame.minX
        let targetX: CGFloat
        switch section {
        case .alwaysHidden: targetX = managedMinX - 20
        case .hidden: targetX = chevronFrame.minX - 15
        case .visible: targetX = chevronFrame.maxX + 25
        }
        let y = frame.midY
        // Already in the right zone? Don't twitch the bar.
        let alreadyPlaced: Bool
        switch section {
        case .alwaysHidden:
            alreadyPlaced = frame.minX <= managedMinX + 2 && frame.maxX < chevronFrame.minX
        case .hidden: alreadyPlaced = frame.maxX < chevronFrame.minX
        case .visible: alreadyPlaced = frame.minX > chevronFrame.maxX
        }
        guard !alreadyPlaced else { return }
        NookLog.log("place: dragging \(id.rawValue) from x=\(frame.midX) to x=\(targetX)")
        await ItemMover.cmdDrag(
            from: CGPoint(x: frame.midX, y: y),
            to: CGPoint(x: targetX, y: y)
        )
        snapshot = await engine.snapshot()
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
    }

    /// The on-screen left-to-right order of a section right now (fallback when
    /// no explicit order exists yet).
    func currentOrder(in section: NookCore.Section) -> [ItemID] {
        editorItems(in: section).map(\.id)
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
        let all = byID.values.filter {
            !$0.id.isSystemModule
                && $0.id.bundleID != Bundle.main.bundleIdentifier
                && $0.id.bundleID?.hasPrefix("com.apple.") != true
                && settings.sectionModel.section(of: $0.id) == section
        }
        let explicit = settings.sectionModel.order[section] ?? []
        return all.sorted { lhs, rhs in
            let li = explicit.firstIndex(of: lhs.id) ?? Int.max
            let ri = explicit.firstIndex(of: rhs.id) ?? Int.max
            if li != ri { return li < ri }
            return (lhs.frame?.minX ?? .greatestFiniteMagnitude)
                < (rhs.frame?.minX ?? .greatestFiniteMagnitude)
        }
    }

    private func scheduleApplyOrder() {
        applyOrderWork?.cancel()
        applyOrderWork = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            NookLog.log("editor: applying order (agent restart)")
            await engine.applyOrder()
            snapshot = await engine.snapshot()
        }
    }

    // MARK: - Effects

    private func dispatch(_ effects: [RehideEffect]) {
        defer { statusItem?.updateSymbol(revealed: isRevealed) }
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
                    dispatch(rehide.handle(.transitionSettled))
                }
            case .conceal:
                Task {
                    NookLog.log("effect conceal → engine")
                    await engine.conceal()
                    snapshot = await engine.snapshot()
                    NookLog.log("effect conceal settled")
                    lastSettleAt = Date()
                    dispatch(rehide.handle(.transitionSettled))
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
                if self.settingsWindowVisible || self.bandMonitor?.shouldDeferRehide() == true {
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
    /// Always-Hidden stays settings-managed for now.
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

    /// Which side of the chevron each item sat on at the last pass (true =
    /// left). Reflows shift every frame but never an item's SIDE — only a real
    /// user drag across the boundary (or moving the chevron itself) does. That
    /// makes side-change the safe adoption trigger: a settings-assigned item
    /// still sitting on its old side is never "corrected" back.
    private var lastAdoptionSides: [String: Bool] = [:]
    /// Set on every reveal/conceal settle; adoption holds off while the bar is
    /// mid-reflow.
    private var lastSettleAt: Date = .distantPast

    private var isTransitioning: Bool {
        if case .transitioning = rehide.state { return true }
        return false
    }

    private func adopt(from snap: EngineSnapshot) {
        guard settings.showStatusItem else { return }
        // adoptSectionsFromBar defers while transitioning/settling; this is
        // the last line of defense if called on a stale path.
        guard !isTransitioning else { return }
        let nookBundle = Bundle.main.bundleIdentifier ?? "app.fif7y.Nook"
        guard
            let chevron = snap.items.first(where: {
                $0.id.bundleID == nookBundle && !$0.id.rawValue.contains("Separator")
            }),
            let chevronX = chevron.frame?.minX
        else { return }

        let isFirstPass = lastAdoptionSides.isEmpty
        NookLog.log("adopt: chevronX=\(chevronX) firstPass=\(isFirstPass) trackedSides=\(lastAdoptionSides.count)")
        var model = settings.sectionModel
        var changed = false
        for item in snap.items {
            guard let bundle = item.id.bundleID,
                  bundle != nookBundle,
                  !bundle.hasPrefix("com.apple."),
                  let frame = item.frame
            else { continue }
            let isLeft = frame.minX < chevronX
            let previousSide = lastAdoptionSides[item.id.rawValue]
            lastAdoptionSides[item.id.rawValue] = isLeft
            // First sighting establishes a baseline; only a side CHANGE adopts.
            guard !isFirstPass, let previousSide, previousSide != isLeft else { continue }
            let current = model.section(of: item.id)
            guard current != .alwaysHidden else { continue }
            let desired: NookCore.Section = isLeft ? .hidden : .visible
            guard desired != current else { continue }
            if desired == .visible {
                model.assignments.removeValue(forKey: item.id)
            } else {
                model.assignments[item.id] = desired
            }
            NookLog.log("adopt: \(item.id.rawValue) → \(desired)")
            changed = true
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
            // Re-converge so a newly appeared bundle joins the allowlist (or
            // gets routed to its configured new-items section later, M4).
            Task {
                await engine.setModel(settings.sectionModel)
                snapshot = await engine.snapshot()
            }
        case .assertionTornDown:
            // Recovery = schedule a converge through the normal path.
            dispatch(rehide.handle(.concealRequested))
        case .availabilityChanged(let available):
            engineCanHide = available
        case .convergeFailed:
            // Surfaced in Settings as a banner; never silently retried in a loop.
            break
        }
    }
}
