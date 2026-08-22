// AppTiming.swift
// App-layer waits and windows tuned live against the agent's restart/reflow
// behavior. Values are load-bearing — rename freely, never retune casually.

import Foundation

enum AppTiming {
    /// Order-apply cover must outlive the whole rebuild: restart settle
    /// (~1.5s) + a possibly launchd-THROTTLED respawn (up to ~12s when the
    /// re-mint second pass restarts twice) + the re-slot pulse + quiesce.
    /// Watchdog only — the cover normally drops at quiesce, long before this.
    static let orderApplyCoverSafety: TimeInterval = 16
    /// Reveal/conceal cover watchdog.
    static let transitionCoverSafety: TimeInterval = 2.5
    /// Coalesces an editor-drop burst into ONE agent restart.
    static let orderApplyDebounce: Duration = .milliseconds(1200)
    /// Never restart the agent mid-transition: bounded settle wait.
    static let transitionSettleDeadline: TimeInterval = 5
    static let transitionSettlePoll: Duration = .milliseconds(150)
    /// Adoption deferral while a transition is in flight.
    static let adoptDeferralDelay: Duration = .milliseconds(300)
    static let adoptMaxDeferrals = 10
    /// Skip adoption this long after a machine order-apply — the restart
    /// fires the same externalOrderChange as a manual drag.
    static let orderApplyAdoptWindow: TimeInterval = 8
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
    /// Physical placement: pre-measure bar settle, then bounded lookup
    /// retries for a freshly-shown item, then post-drag reflow settle.
    static let placementPreSettle: Duration = .milliseconds(450)
    static let placementLookupRetries = 3
    static let placementLookupRetryDelay: Duration = .milliseconds(550)
    static let postDragSettle: Duration = .milliseconds(300)
    /// Precapture waits this long after quiesce so the ghost's fade never
    /// bakes into the snapshot.
    static let precaptureGhostClearance: Duration = .milliseconds(300)
}
