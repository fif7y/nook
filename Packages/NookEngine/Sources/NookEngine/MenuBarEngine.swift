// MenuBarEngine.swift
// The macOS-28 seam: everything above this protocol is version-agnostic.
// One implementation exists today (EngineGoldenGate, macOS 27).

import Foundation
import NookCore

public struct ObservedItem: Equatable, Sendable {
    public let id: ItemID
    /// Screen-coordinate frame on the main menubar instance; nil when concealed
    /// (concealed items drop out of the AX tree entirely).
    public let frame: CGRect?
    public let appName: String?

    public init(id: ItemID, frame: CGRect?, appName: String?) {
        self.id = id
        self.frame = frame
        self.appName = appName
    }
}

public struct EngineSnapshot: Equatable, Sendable {
    public let items: [ObservedItem]
    /// Items currently concealed by our assertion (kept from the last converge;
    /// AX can no longer see them).
    public let concealed: Set<ItemID>
    public let nativeOverflowActive: Bool
    public let takenAt: Date

    public init(items: [ObservedItem], concealed: Set<ItemID>, nativeOverflowActive: Bool, takenAt: Date) {
        self.items = items
        self.concealed = concealed
        self.nativeOverflowActive = nativeOverflowActive
        self.takenAt = takenAt
    }
}

public enum EngineEvent: Equatable, Sendable {
    /// The set of menubar items changed (app launched/quit, item added/removed).
    case itemsChanged
    /// The user (or the OS) reordered items outside Nook — adopt, don't correct.
    case externalOrderChange
    /// Our hide assertion was torn down externally (DND/assessment churn).
    case assertionTornDown
    /// MenuBarClientCore availability flipped (e.g. after an OS update).
    case availabilityChanged(Bool)
    /// A converge attempt failed after bounded retries; surface to the user.
    case convergeFailed(String)
}

public enum HideGranularity: Sendable {
    case bundleID
    case item
}

public struct EngineCapabilities: Sendable {
    public let canHide: Bool
    public let hideGranularity: HideGranularity
    public let canReorder: Bool

    public init(canHide: Bool, hideGranularity: HideGranularity, canReorder: Bool) {
        self.canHide = canHide
        self.hideGranularity = hideGranularity
        self.canReorder = canReorder
    }
}

/// The engine converges the real menubar toward a desired `SectionModel` +
/// reveal state. All mutating calls are serialized internally; callers never
/// see interleaved half-states.
public protocol MenuBarEngine: Actor {
    var capabilities: EngineCapabilities { get }
    var events: AsyncStream<EngineEvent> { get }

    func start() async
    func stop() async

    func snapshot() async -> EngineSnapshot

    /// Update the desired layout and converge toward it.
    func setModel(_ model: SectionModel) async
    /// Reveal the given sections (relax the assertion accordingly).
    func reveal(_ sections: Set<Section>) async
    /// Conceal everything the model says is non-visible.
    func conceal() async
    /// Apply the model's per-section order to the real menubar.
    @discardableResult
    func applyOrder() async -> [String]
    /// Click a (possibly concealed) item without changing reveal state.
    func click(_ item: ItemID, rightClick: Bool) async -> Bool
    /// True when no assertion swap has been issued for `interval` seconds —
    /// the agent's animation passes ride each swap, so swap-quiet means the
    /// bar has stopped moving. Overlay covers hold until this turns true.
    func quiesced(for interval: TimeInterval) async -> Bool
}
