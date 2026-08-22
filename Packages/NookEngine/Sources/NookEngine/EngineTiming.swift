// EngineTiming.swift
// Empirically tuned waits and windows for macOS 27's MenuBarAgent behavior.
// Values are load-bearing (tuned live against agent restart/reflow/AX
// latencies) — rename freely, never retune casually.

import Foundation

enum EngineTiming {
    /// snapshot() cache TTL — sub-500ms repeat reads reuse the last AX walk.
    static let snapshotTTL: TimeInterval = 0.5
    /// Initial wait after SIGKILLing the agent before checking on the respawn.
    static let agentRestartSettle: TimeInterval = 1.5
    /// launchd THROTTLES respawns when two restarts land close together (the
    /// re-mint second pass) — the agent can stay dead for ~7s. Poll for the
    /// new process + a walkable AX tree up to this deadline before pulsing.
    static let agentRespawnDeadline: TimeInterval = 12
    static let agentRespawnPoll: Duration = .milliseconds(200)
    /// applyOrder re-slot pulse: cap, swap-quiet threshold, and poll interval.
    static let reSlotPulseDeadline: TimeInterval = 1.5
    static let reSlotPulseQuiesce: TimeInterval = 0.3
    static let reSlotPulsePoll: Duration = .milliseconds(100)
    /// AX messaging timeouts — a stuck agent/app must never wedge a walk.
    static let axAgentTimeout: Float = 0.25
    static let axAppTimeout: Float = 0.5
    /// Empty-AX-walk deferral: bounded retries while the agent tree is unreadable.
    static let emptyAXRetries = 6
    static let emptyAXRetryDelay: Duration = .milliseconds(500)
    /// Ignore teardown signals inside this window after a swap (AX drop-out lag).
    static let teardownSettleWindow: TimeInterval = 3
    /// Assertion activation completion: bounded wait + poll (observed <100ms).
    static let activationDeadline: TimeInterval = 3
    static let activationPoll: Duration = .milliseconds(50)
    /// verifyConcealment: bounded poll until concealed bundles drop out of AX.
    static let verifyWindow: TimeInterval = 3
    static let verifyPoll: Duration = .milliseconds(150)
}
