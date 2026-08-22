// AppTiming.swift
// App-layer waits and windows tuned live against the agent's restart/reflow
// behavior. Values are load-bearing — rename freely, never retune casually.

import Foundation

enum AppTiming {
    /// Reveal/conceal cover watchdog.
    static let transitionCoverSafety: TimeInterval = 2.5
    /// Adoption deferral while a transition is in flight.
    static let adoptDeferralDelay: Duration = .milliseconds(300)
    static let adoptMaxDeferrals = 10
    /// Precaptured reveal-cover freshness: an appearance/wallpaper change
    /// while idle would flash a stale background.
    static let revealCoverFreshness: TimeInterval = 900
    /// Tidy waits for the full reveal to land before rebuilding.
    static let tidyRevealWait: Duration = .seconds(1.2)
    /// Newly toggled-on extras become hostable before placing.
    static let newExtraPlacementDelay: Duration = .milliseconds(600)
    /// Below ~150ms every swipe-through of the band reads as a hover.
    static let hoverDelayFloor: TimeInterval = 0.15
    /// MenuBarAgent finalizes a ⌘-drag position before adoption reads it.
    static let dragAdoptDelay: TimeInterval = 0.35
    /// Rehide re-arm while deferred (pointer in band / elevated window).
    static let rehideDeferRearm: TimeInterval = 1.5
    /// Termination: max wait for engine.stop() before replying anyway.
    static let terminationStopDeadline: TimeInterval = 2
    /// Physical placement: pre-measure bar settle, then bounded lookup
    /// retries for a freshly-shown item, then post-drag reflow settle.
    static let placementPreSettle: Duration = .milliseconds(450)
    static let placementLookupRetries = 3
    static let placementLookupRetryDelay: Duration = .milliseconds(550)
    static let postDragSettle: Duration = .milliseconds(300)
    /// Precapture waits this long after quiesce so the ghost's fade never
    /// bakes into the snapshot.
    static let precaptureGhostClearance: Duration = .milliseconds(300)
    /// Rescue force-show → measure: the attach + fade + agent reflow must
    /// finish or the frame still reads as a phantom (burned attempt 1 live).
    static let rescueForceShowSettle: Duration = .milliseconds(600)
    /// « expansion → re-measure: the overflow items reflow into the bar.
    static let overflowExpandSettle: Duration = .milliseconds(700)
}
