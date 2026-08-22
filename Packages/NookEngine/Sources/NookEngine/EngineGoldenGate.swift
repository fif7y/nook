// EngineGoldenGate.swift
// The macOS 27 engine: converges the real menubar toward the desired
// SectionModel using assessment-mode assertions (hide), positions-plist writes
// (order), and AX (observe/click). One actor — every mutation is serialized,
// recovery is just another scheduled converge.

import AppKit
import Foundation
import NookCore

public actor EngineGoldenGate: MenuBarEngine {
    public nonisolated let capabilities = EngineCapabilities(
        canHide: AssessmentMode.isAvailable,
        hideGranularity: .bundleID,
        canReorder: true
    )

    public nonisolated var events: AsyncStream<EngineEvent> { eventStream }
    private nonisolated let eventStream: AsyncStream<EngineEvent>
    private nonisolated let eventContinuation: AsyncStream<EngineEvent>.Continuation

    private let enumerator = ItemEnumerator()
    private var prefsWatcher: AgentPrefsWatcher?

    /// Called on the main actor at the exact moment an assertion swap is
    /// issued (and on assertion drop), passing the revealed sections. App-side
    /// items that hide by their own width use this to change size in the SAME
    /// agent reflow — separate passes animate separately and read as sliding.
    public var reflowCompanion: (@MainActor @Sendable (Set<Section>) -> Void)?

    public func setReflowCompanion(_ companion: @MainActor @Sendable @escaping (Set<Section>) -> Void) {
        reflowCompanion = companion
    }

    private func notifyReflowCompanion() {
        guard let reflowCompanion else { return }
        let revealed = revealedSections
        Task { @MainActor in reflowCompanion(revealed) }
    }

    private var model = SectionModel()
    private var revealedSections: Set<Section> = []
    /// Steady-assertion mode: hold an assertion even when nothing is
    /// concealable (allowlist = every observed bundle). Keeps macOS's
    /// collateral-hidden extras (Now Playing, camera pill, AirDrop, Focus)
    /// consistently gone, so the bar never reflows around them.
    private var steadyExtras = true
    private var assertion: AssessmentAssertion?
    /// The allowlist/concealable pair the active assertion was built with.
    /// Converging to an equivalent state is a NO-OP — without this,
    /// converge→reflow→itemsChanged→converge oscillates forever.
    private var activeAllowlist: Set<String>?
    private var activeConcealable: Set<String>?
    private var activeSystemAllow: Set<Int>?

    /// MenuBarPolicy.identityExemptBundles bound to the running app's bundle
    /// id, computed once.
    public static let identityExemptBundles: Set<String> =
        MenuBarPolicy.identityExemptBundles(
            nookBundleID: Bundle.main.bundleIdentifier ?? NookBundle.fallbackID
        )

    private var lastSnapshot: EngineSnapshot?
    private var started = false
    /// Actor reentrancy guard: converge() suspends several times, and a stale
    /// converge resuming after a newer one must not activate an outdated
    /// assertion or stamp an outdated concealed set. Each converge takes a
    /// ticket; any resume point where the ticket is no longer current aborts.
    private var convergeEpoch = 0
    /// When the last assertion swap was issued — teardown detection ignores
    /// the settle window right after a swap (items take a beat to drop out).
    private var lastSwapAt = Date.distantPast
    /// Bounded retries for converges that find an EMPTY AX walk. A real bar
    /// always contains system items, so empty means the agent tree isn't
    /// readable yet (launch, locked screen) — planning from it swaps in an
    /// allow-all assertion that un-hides everything for a beat.
    private var emptyAXRetriesRemaining = EngineTiming.emptyAXRetries

    public init() {
        var continuation: AsyncStream<EngineEvent>.Continuation!
        self.eventStream = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    // MARK: - Lifecycle

    public func start() async {
        guard !started else { return }
        started = true
        let watcher = AgentPrefsWatcher { [weak self] in
            Task { await self?.handleExternalPrefsChange() }
        }
        watcher.start()
        prefsWatcher = watcher
        _ = await refreshSnapshot()
    }

    public func stop() async {
        prefsWatcher?.stop()
        prefsWatcher = nil
        invalidateAssertion()
        started = false
        // Ends any `for await` over `events` instead of hanging it forever.
        eventContinuation.finish()
    }

    // MARK: - MenuBarEngine

    public func snapshot() async -> EngineSnapshot {
        if let lastSnapshot, Date().timeIntervalSince(lastSnapshot.takenAt) < EngineTiming.snapshotTTL {
            return lastSnapshot
        }
        return await refreshSnapshot()
    }

    public func setModel(_ model: SectionModel) async {
        self.model = model
        await converge()
    }

    public func setSteadyExtras(_ enabled: Bool) async {
        guard steadyExtras != enabled else { return }
        steadyExtras = enabled
        await converge()
    }

    public func reveal(_ sections: Set<Section>) async {
        revealedSections.formUnion(sections)
        await converge()
    }

    public func conceal() async {
        revealedSections = []
        await converge()
    }

    public func quiesced(for interval: TimeInterval) -> Bool {
        Date().timeIntervalSince(lastSwapAt) > interval
    }

    /// Returns the written tags so callers can detect a post-restart re-mint
    /// (a live tag absent from the written set never got a slot).
    @discardableResult
    public func applyOrder() async -> [String] {
        let snapshot = await refreshSnapshot()
        // Desired left-to-right order: model order per section, sections laid
        // out as [alwaysHidden][hidden][visible] (hidden sections collapse
        // toward the left of the status area, matching the classic layout).
        // Concealed items drop out of AX but are exactly the ones being
        // ordered — union them in (frame nil sorts by explicit order only).
        let liveIDs = Set(snapshot.items.map(\.id))
        let concealedItems = snapshot.concealed.subtracting(liveIDs).map {
            ObservedItem(id: $0, frame: nil, appName: nil)
        }
        let allItems = snapshot.items + concealedItems
        var orderedTags: [String] = []
        for section in [Section.alwaysHidden, .hidden, .visible] {
            let sectionItems = allItems
                .filter { model.section(of: $0.id) == section && !$0.id.isSystemModule }
            let explicit = model.order[section] ?? []
            let ranked = sectionItems.sorted { lhs, rhs in
                // Order arrays hold canonical section keys — rank real items
                // through the same lens.
                let li = explicit.firstIndex(of: lhs.id.sectionKey) ?? Int.max
                let ri = explicit.firstIndex(of: rhs.id.sectionKey) ?? Int.max
                if li != ri { return li < ri }
                // Fall back to current on-screen order (agent order).
                return (lhs.frame?.minX ?? 0) < (rhs.frame?.minX ?? 0)
            }
            orderedTags.append(contentsOf: ranked.map(\.id.rawValue))
        }
        prefsWatcher?.suppress()
        // Return every written position KEY (the spread covers known tag
        // variants) — callers detect a re-mint precisely: a live tag missing
        // from this set truly got no slot. Returning only orderedTags made
        // covered variants look unslotted → gratuitous second restarts.
        let written = AgentPositionStore.writeOrder(orderedTags)
        AgentPositionStore.restartAgent()
        // The agent takes a moment to come back; settle before re-observing.
        try? await Task.sleep(for: .seconds(EngineTiming.agentRestartSettle))
        _ = await refreshSnapshot()
        // A freshly-booted agent lays live items back out where they sat — it
        // re-slots from the plist only when an item (re)enters layout. While
        // revealed (settings preview, hover) nothing re-enters, so the rebuild
        // lands invisibly and the bar keeps its old order until the next
        // conceal/reveal cycle. Pulse that cycle now, under the caller's
        // cover, so the new order shows immediately.
        if !revealedSections.isEmpty {
            let sections = revealedSections
            NookLog.log("applyOrder: revealed during rebuild — conceal/reveal pulse to re-slot")
            await conceal()
            // Let the hide swap actually land before re-revealing — swaps can
            // land after the transaction returns (settle≠swap).
            let pulseDeadline = Date().addingTimeInterval(EngineTiming.reSlotPulseDeadline)
            while Date() < pulseDeadline, !quiesced(for: EngineTiming.reSlotPulseQuiesce) {
                try? await Task.sleep(for: EngineTiming.reSlotPulsePoll)
            }
            await reveal(sections)
        }
        return Array(written.keys)
    }

    public func click(_ item: ItemID, rightClick: Bool) async -> Bool {
        // Concealed left-click: AXPress the source app's own status element —
        // no reveal, no flicker. (M5 wires this to the notch bar.)
        guard let bundleID = item.bundleID else { return false }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, EngineTiming.axAppTimeout)
        var extras: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, "AXExtrasMenuBar" as CFString, &extras)
        guard let extrasBar = extras, CFGetTypeID(extrasBar) == AXUIElementGetTypeID() else {
            return false
        }
        var childrenValue: CFTypeRef?
        AXUIElementCopyAttributeValue(
            extrasBar as! AXUIElement, kAXChildrenAttribute as CFString, &childrenValue
        )
        guard let children = childrenValue as? [AXUIElement], let target = children.first else {
            return false
        }
        let action = rightClick ? "AXShowMenu" : kAXPressAction
        return AXUIElementPerformAction(target, action as CFString) == .success
    }

    // MARK: - Convergence

    /// The one path that changes hide state. Idempotent: computes the full
    /// allowlist from (model, revealedSections) and swaps the assertion in a
    /// single transition.
    private func converge() async {
        convergeEpoch += 1
        let epoch = convergeEpoch
        let snapshot = await refreshSnapshot()
        guard epoch == convergeEpoch else { return }
        // An empty AX walk can't be trusted: a real bar always has system
        // items, so this is the agent tree not being readable yet (launch,
        // locked screen). A plan computed from it has concealable=[] and
        // would swap in an allow-all assertion — a momentary un-hide flash
        // followed by a second animated swap when AX populates. Defer with a
        // bounded retry; past the bound, the itemsChanged fired by the first
        // successful re-walk re-converges us.
        if snapshot.items.isEmpty {
            NookLog.log("converge: AX walk empty — deferring (retries left \(emptyAXRetriesRemaining))")
            if emptyAXRetriesRemaining > 0 {
                emptyAXRetriesRemaining -= 1
                Task {
                    try? await Task.sleep(for: EngineTiming.emptyAXRetryDelay)
                    await self.converge()
                }
            }
            return
        }
        emptyAXRetriesRemaining = EngineTiming.emptyAXRetries
        // Running-app set: consulted by the stale prune below (quit apps) and
        // the allowlist build. Fetched once, up front.
        let runningBundles = await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }
        guard epoch == convergeEpoch else { return }
        // The pure decision step — "existing" set (observed ∪ carried
        // concealed, drift-pruned), concealable bundles, system allowlist,
        // bundle allowlist, resulting concealed set. Logic + rationale live
        // in ConvergePlan.compute (unit-tested); this actor only executes.
        let plan = ConvergePlan.compute(
            model: model,
            liveIDs: Set(snapshot.items.map(\.id)),
            carriedConcealed: lastSnapshot?.concealed ?? [],
            runningBundles: runningBundles,
            revealedSections: revealedSections,
            steadyExtras: steadyExtras,
            exemptBundles: Self.identityExemptBundles
        )
        for (id, reason) in plan.stale {
            NookLog.log("converge: pruned concealed \(reason == .staleAlias ? "stale alias" : "entry for quit app") \(id.rawValue)")
        }
        let concealable = plan.concealable
        let allowedSystem = plan.allowedSystem
        let allowedBundles = plan.allowedBundles

        guard AssessmentMode.isAvailable else {
            if assertion != nil { invalidateAssertion() }
            eventContinuation.yield(.availabilityChanged(false))
            return
        }

        if plan.dropAssertion {
            // Nothing to hide and extras are allowed back: drop the assertion.
            invalidateAssertion()
            notifyReflowCompanion()
            let after = await refreshSnapshot()
            guard epoch == convergeEpoch else { return }
            // Nothing is concealed now — clearing the carried set here stops
            // observers from reporting phantom concealment until the next swap.
            lastSnapshot = EngineSnapshot(
                items: after.items,
                concealed: [],
                takenAt: after.takenAt
            )
            return
        }
        // With steadyExtras on, an empty concealable set still holds an
        // assertion allowing every observed bundle — only the OS extras hide.

        // Teardown detection: a concealable bundle observed LIVE while our
        // bookkeeping claims a matching assertion means macOS dropped the
        // assertion externally — without this, the itemsChanged the
        // reappearance triggers converges straight into the no-op guard and
        // the wedge is permanent. Only trust the signal once the post-swap
        // settle window (verify covers 3s) has passed, or the normal AX
        // drop-out latency right after a swap would read as a violation.
        let assertionLost = Date().timeIntervalSince(lastSwapAt) > EngineTiming.teardownSettleWindow
            && snapshot.items.contains { item in
                guard let bundle = item.id.bundleID else { return false }
                return concealable.contains(bundle)
            }

        // Idempotence: an equivalent state under a live assertion = already
        // converged. Skip the swap — this is what breaks event feedback loops.
        // Superset check (not equality): an app quitting leaves a harmless
        // stale allow entry and must not cause a swap; a NEW bundle missing
        // from the active allowlist must.
        if assertion != nil, !assertionLost,
           activeConcealable == concealable,
           activeSystemAllow == Set(allowedSystem.map(\.rawValue)),
           let activeAllowlist, activeAllowlist.isSuperset(of: allowedBundles) {
            NookLog.log("converge: no-op (concealable=\(concealable.count), allow=\(allowedBundles.count))")
            return
        }
        if assertionLost {
            NookLog.log("converge: concealable items visible under live bookkeeping — assertion lost, re-swapping")
            eventContinuation.yield(.assertionTornDown)
        }
        NookLog.log("converge: swapping — concealable=\(concealable.sorted()), allow=\(allowedBundles.count), revealed=\(revealedSections.count), live=\(snapshot.items.count), carried=\(lastSnapshot?.concealed.count ?? -1), assigns=\(model.assignments.count)")

        let previous = assertion
        // Bounded wait: the completion is async (and can be a dud) — a stuck
        // activation must never wedge the converge path. 3s is generous; the
        // observed completion latency is <100ms.
        let activationBox = ActivationBox()
        let handle = AssessmentMode.activate(allowing: allowedSystem, bundleIDs: Array(allowedBundles)) { error in
            activationBox.resolve(error == nil)
        }
        // Companion items change size NOW so the agent coalesces their reflow
        // with the assertion swap it's about to animate.
        notifyReflowCompanion()

        guard let handle else {
            // No handle at all: keep the previous assertion alive (it still
            // holds SOME hide state) and leave bookkeeping pointing at it —
            // the next converge toward this target won't match the no-op
            // guard, so retrying stays possible. Invalidating `previous` here
            // used to kill the still-current assertion and wedge the state.
            NookLog.log("converge: activation returned nil handle — keeping previous assertion")
            eventContinuation.yield(.convergeFailed("assertion activation failed"))
            return
        }
        assertion = handle
        activeAllowlist = allowedBundles
        activeConcealable = concealable
        activeSystemAllow = Set(allowedSystem.map(\.rawValue))
        lastSwapAt = Date()
        var activated = false
        let deadline = Date().addingTimeInterval(EngineTiming.activationDeadline)
        while Date() < deadline {
            if let result = activationBox.result {
                activated = result
                break
            }
            try? await Task.sleep(for: EngineTiming.activationPoll)
        }
        // Swap order matters: activate the new state, then drop the old
        // assertion so there is no flash of everything-visible in between.
        previous?.invalidate()
        guard epoch == convergeEpoch else { return }

        if !activated {
            NookLog.log("converge: assertion activation FAILED (dud completion)")
            // The handle exists but activation never confirmed — the real hide
            // state is unknown. Drop the allowlist bookkeeping so the next
            // converge fails the no-op guard and re-swaps instead of wedging.
            activeAllowlist = nil
            eventContinuation.yield(.convergeFailed("assertion activation failed"))
        } else {
            NookLog.log("converge: assertion active")
        }
        // Stamp the concealed set NOW — observers must union it from the
        // moment the swap is issued. The slow part (polling AX until the
        // concealed bundles actually drop out) moves OFF the critical path:
        // holding converge (and therefore the settle report) hostage to up to
        // 3s of verify polling made every queued transition — hover right
        // after a conceal, rapid toggles — wait a visible beat before moving.
        let after = await refreshSnapshot()
        guard epoch == convergeEpoch else { return }
        lastSnapshot = EngineSnapshot(
            items: after.items,
            concealed: plan.concealed,
            takenAt: after.takenAt
        )
        if !concealable.isEmpty {
            Task { await self.verifyConcealment(of: concealable) }
        }
    }

    /// Background verify-after-apply: bounded poll until the concealed
    /// bundles drop out of the AX tree. Bails silently when a newer converge
    /// has superseded this one — that converge owns the state now.
    private func verifyConcealment(of concealable: Set<String>) async {
        let deadline = Date().addingTimeInterval(EngineTiming.verifyWindow)
        while Date() < deadline {
            try? await Task.sleep(for: EngineTiming.verifyPoll)
            guard activeConcealable == concealable else { return }
            let check = await refreshSnapshot()
            let stillVisible = check.items.contains { item in
                guard let bundle = item.id.bundleID else { return false }
                return concealable.contains(bundle)
            }
            if !stillVisible { return }
        }
        guard activeConcealable == concealable else { return }
        NookLog.log("converge: STILL VISIBLE after verify window")
        // The assertion claims these bundles are hidden but reality disagrees
        // (dud activation, or macOS tore the assertion down externally). Drop
        // the allowlist bookkeeping so the next converge re-swaps instead of
        // no-op'ing against bookkeeping that no longer reflects the bar.
        activeAllowlist = nil
        eventContinuation.yield(.convergeFailed("concealed items still visible after verify window"))
    }

    /// Thread-safe one-shot result for the assertion completion (delivered on
    /// an arbitrary queue by the private framework).
    private final class ActivationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool?
        var result: Bool? {
            lock.withLock { value }
        }
        func resolve(_ success: Bool) {
            lock.withLock { if value == nil { value = success } }
        }
    }

    private func invalidateAssertion() {
        assertion?.invalidate()
        assertion = nil
        activeAllowlist = nil
        activeConcealable = nil
        activeSystemAllow = nil
    }

    private func refreshSnapshot() async -> EngineSnapshot {
        let raw = await enumerator.snapshotItems()
        let previousIDs = lastSnapshot.map { Set($0.items.map(\.id)) }
        let snapshot = EngineSnapshot(
            items: raw.map { ObservedItem(id: $0.id, frame: $0.frame, appName: $0.appName) },
            concealed: lastSnapshot?.concealed ?? [],
            takenAt: Date()
        )
        if let previousIDs, previousIDs != Set(raw.map(\.id)) {
            eventContinuation.yield(.itemsChanged)
        }
        lastSnapshot = snapshot
        return snapshot
    }

    private func handleExternalPrefsChange() async {
        // Adopt, don't correct: notify the app layer so it can pull the new
        // order into the model. No engine-side counter-writes.
        eventContinuation.yield(.externalOrderChange)
        _ = await refreshSnapshot()
    }
}
