// AppTiming.swift
// App-layer waits and windows tuned live against the agent's restart/reflow
// behavior. Values are load-bearing — rename freely, never retune casually.

import Foundation

enum AppTiming {
    /// Order-apply cover must outlive the whole rebuild: restart settle
    /// (~1.5s) + the engine's re-slot pulse (~1s when revealed) + quiesce.
    static let orderApplyCoverSafety: TimeInterval = 7
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
}
