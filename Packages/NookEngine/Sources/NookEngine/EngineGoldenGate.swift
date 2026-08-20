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
    private var lastSnapshot: EngineSnapshot?
    private var started = false

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
    }

    // MARK: - MenuBarEngine

    public func snapshot() async -> EngineSnapshot {
        if let lastSnapshot, Date().timeIntervalSince(lastSnapshot.takenAt) < 0.5 {
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

    public func applyOrder() async {
        let snapshot = await refreshSnapshot()
        // Desired left-to-right order: model order per section, sections laid
        // out as [alwaysHidden][hidden][visible] (hidden sections collapse
        // toward the left of the status area, matching the classic layout).
        var orderedTags: [String] = []
        for section in [Section.alwaysHidden, .hidden, .visible] {
            let sectionItems = snapshot.items
                .filter { model.section(of: $0.id) == section && !$0.id.isSystemModule }
            let explicit = model.order[section] ?? []
            let ranked = sectionItems.sorted { lhs, rhs in
                let li = explicit.firstIndex(of: lhs.id) ?? Int.max
                let ri = explicit.firstIndex(of: rhs.id) ?? Int.max
                if li != ri { return li < ri }
                // Fall back to current on-screen order (agent order).
                return (lhs.frame?.minX ?? 0) < (rhs.frame?.minX ?? 0)
            }
            orderedTags.append(contentsOf: ranked.map(\.id.rawValue))
        }
        prefsWatcher?.suppress()
        AgentPositionStore.writeOrder(orderedTags)
        AgentPositionStore.restartAgent()
        // The agent takes a moment to come back; settle before re-observing.
        try? await Task.sleep(for: .seconds(1.5))
        _ = await refreshSnapshot()
    }

    public func click(_ item: ItemID, rightClick: Bool) async -> Bool {
        // Concealed left-click: AXPress the source app's own status element —
        // no reveal, no flicker. (M5 wires this to the notch bar.)
        guard let bundleID = item.bundleID else { return false }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
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
        let snapshot = await refreshSnapshot()
        let observedIDs = snapshot.items.map(\.id)
        let concealable = model.concealableBundleIDs(
            observedItems: observedIDs,
            revealing: revealedSections
        )

        guard AssessmentMode.isAvailable else {
            if assertion != nil { invalidateAssertion() }
            eventContinuation.yield(.availabilityChanged(false))
            return
        }

        if concealable.isEmpty, !steadyExtras {
            // Nothing to hide and extras are allowed back: drop the assertion.
            invalidateAssertion()
            _ = await refreshSnapshot()
            return
        }
        // With steadyExtras on, an empty concealable set still holds an
        // assertion allowing every observed bundle — only the OS extras hide.

        // Allowlist = every third-party bundle except the concealable. Built
        // from ALL running apps, not just observed items — a bundle without a
        // status item is a harmless allow, and it means an app launched after
        // this converge shows its new icon instead of being swallowed.
        var allowedBundles = Set<String>()
        for id in observedIDs {
            if let bundle = id.bundleID, !concealable.contains(bundle) {
                allowedBundles.insert(bundle)
            }
        }
        let runningBundles = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        }
        for bundle in runningBundles where !concealable.contains(bundle) {
            allowedBundles.insert(bundle)
        }

        // Idempotence: an equivalent state under a live assertion = already
        // converged. Skip the swap — this is what breaks event feedback loops.
        // Superset check (not equality): an app quitting leaves a harmless
        // stale allow entry and must not cause a swap; a NEW bundle missing
        // from the active allowlist must.
        if assertion != nil,
           activeConcealable == concealable,
           let activeAllowlist, activeAllowlist.isSuperset(of: allowedBundles) {
            return
        }

        let previous = assertion
        // Bounded wait: the completion is async (and can be a dud) — a stuck
        // activation must never wedge the converge path. 3s is generous; the
        // observed completion latency is <100ms.
        let activationBox = ActivationBox()
        let handle = AssessmentMode.activate(bundleIDs: Array(allowedBundles)) { error in
            activationBox.resolve(error == nil)
        }
        var activated = false
        if let handle {
            assertion = handle
            activeAllowlist = allowedBundles
            activeConcealable = concealable
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if let result = activationBox.result {
                    activated = result
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        // Swap order matters: activate the new state, then drop the old
        // assertion so there is no flash of everything-visible in between.
        previous?.invalidate()

        if !activated {
            eventContinuation.yield(.convergeFailed("assertion activation failed"))
        }
        let concealed = Set(observedIDs.filter { id in
            guard let bundle = id.bundleID else { return false }
            return concealable.contains(bundle)
        })
        // Verify-after-apply: poll until the concealed bundles actually drop
        // out of the AX tree (reflow propagation is not instant), bounded.
        // Nothing to verify on a reveal/extras-only converge — keep it snappy.
        if !concealable.isEmpty {
            let verifyDeadline = Date().addingTimeInterval(3)
            while Date() < verifyDeadline {
                try? await Task.sleep(for: .milliseconds(100))
                let check = await refreshSnapshot()
                let stillVisible = check.items.contains { item in
                    guard let bundle = item.id.bundleID else { return false }
                    return concealable.contains(bundle)
                }
                if !stillVisible { break }
            }
        }
        let after = await refreshSnapshot()
        let stillVisible = after.items.contains { item in
            guard let bundle = item.id.bundleID else { return false }
            return concealable.contains(bundle)
        }
        if stillVisible {
            eventContinuation.yield(.convergeFailed("concealed items still visible after verify window"))
        }
        lastSnapshot = EngineSnapshot(
            items: after.items,
            concealed: concealed,
            nativeOverflowActive: after.nativeOverflowActive,
            takenAt: after.takenAt
        )
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
    }

    private func refreshSnapshot() async -> EngineSnapshot {
        let raw = await enumerator.snapshotItems()
        let overflow = await enumerator.nativeOverflowVisible()
        let previousIDs = lastSnapshot.map { Set($0.items.map(\.id)) }
        let snapshot = EngineSnapshot(
            items: raw.map { ObservedItem(id: $0.id, frame: $0.frame, appName: $0.appName) },
            concealed: lastSnapshot?.concealed ?? [],
            nativeOverflowActive: overflow,
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
