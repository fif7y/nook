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

    /// Core system items ARE controllable via the assertion's system-item
    /// allowlist — map their menuextra identifiers to MBSystemItemIdentifier.
    public static func systemItem(for id: ItemID) -> SystemItem? {
        let raw = id.rawValue
        guard raw.contains("::com.apple.menuextra.") else { return nil }
        if raw.hasSuffix(".sound") { return .volume }
        if raw.hasSuffix(".battery") { return .battery }
        if raw.hasSuffix(".wifi") { return .wifi }
        if raw.hasSuffix(".clock") { return .clock }
        if raw.hasSuffix(".bluetooth") { return .bluetooth }
        if raw.hasSuffix(".display") || raw.hasSuffix(".displays") { return .displays }
        if raw.hasSuffix(".textinput") || raw.hasSuffix(".keyboard") { return .keyboard }
        if raw.hasSuffix(".screen-mirroring") { return .screenMirroring }
        return nil
    }
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
        // "Existing" = observed OR currently concealed by us. Concealed items
        // drop out of the AX tree entirely (macOS 27 single-window), so
        // computing from observation alone concludes "nothing to conceal",
        // re-allows the hidden bundles, they reappear, get re-hidden — an
        // endless visible oscillation.
        let observedIDs = Array(
            Set(snapshot.items.map(\.id)).union(lastSnapshot?.concealed ?? [])
        )
        let concealable = model.concealableBundleIDs(
            observedItems: observedIDs,
            revealing: revealedSections
        )

        guard AssessmentMode.isAvailable else {
            if assertion != nil { invalidateAssertion() }
            eventContinuation.yield(.availabilityChanged(false))
            return
        }

        // System items assigned to a non-revealed section leave the system
        // allowlist — this is how Sound/battery/etc. become hideable.
        let hiddenSystem = Set(model.assignments.compactMap { id, section -> SystemItem? in
            guard !revealedSections.contains(section) else { return nil }
            return Self.systemItem(for: id)
        })
        let allowedSystem = SystemItem.allCases.filter { !hiddenSystem.contains($0) }

        if concealable.isEmpty, hiddenSystem.isEmpty, !steadyExtras {
            // Nothing to hide and extras are allowed back: drop the assertion.
            invalidateAssertion()
            notifyReflowCompanion()
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
           activeSystemAllow == Set(allowedSystem.map(\.rawValue)),
           let activeAllowlist, activeAllowlist.isSuperset(of: allowedBundles) {
            NookLog.log("converge: no-op (concealable=\(concealable.count), allow=\(allowedBundles.count))")
            return
        }
        NookLog.log("converge: swapping — concealable=\(concealable.sorted()), allow=\(allowedBundles.count), revealed=\(revealedSections.count)")

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

        var activated = false
        if let handle {
            assertion = handle
            activeAllowlist = allowedBundles
            activeConcealable = concealable
            activeSystemAllow = Set(allowedSystem.map(\.rawValue))
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
            NookLog.log("converge: assertion activation FAILED (handle=\(handle == nil ? "nil" : "live"))")
            eventContinuation.yield(.convergeFailed("assertion activation failed"))
        } else {
            NookLog.log("converge: assertion active")
        }
        let concealed = Set(observedIDs.filter { id in
            if let system = Self.systemItem(for: id) {
                return hiddenSystem.contains(system)
            }
            guard let bundle = id.bundleID else { return false }
            return concealable.contains(bundle)
        })
        // Stamp the concealed set NOW — observers must union it from the
        // moment the swap is issued. The slow part (polling AX until the
        // concealed bundles actually drop out) moves OFF the critical path:
        // holding converge (and therefore the settle report) hostage to up to
        // 3s of verify polling made every queued transition — hover right
        // after a conceal, rapid toggles — wait a visible beat before moving.
        let after = await refreshSnapshot()
        lastSnapshot = EngineSnapshot(
            items: after.items,
            concealed: concealed,
            nativeOverflowActive: after.nativeOverflowActive,
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
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(150))
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
