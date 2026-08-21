// RehideStateMachine.swift
// Pure reveal/rehide state machine. All timing is injected (deadlines are
// data, not timers), so every transition is unit-testable and the engine can
// never be toggled mid-flight: callers apply the returned effect, and only
// report completion back via `.transitionSettled`.

import Foundation

public enum RevealReason: Hashable, Sendable {
    case hover
    /// Pointer is on a display configured "always show everything".
    case displayPolicy
    case click
    case doubleClick
    case hotkey
    case statusItem
    case barPanel
    case settingsPreview
}

public enum RehideTrigger: Hashable, Sendable {
    case delayExpired
    case clickedElsewhere
    case pointerLeftBand
    case displayBehaviorChanged
}

public struct RehidePolicy: Equatable, Sendable {
    public var autoRehide: Bool
    public var delay: TimeInterval
    public var rehideOnClickElsewhere: Bool

    public init(autoRehide: Bool = true, delay: TimeInterval = 5, rehideOnClickElsewhere: Bool = true) {
        self.autoRehide = autoRehide
        self.delay = delay
        self.rehideOnClickElsewhere = rehideOnClickElsewhere
    }
}

/// What the caller must do after feeding an event in.
public enum RehideEffect: Equatable, Sendable {
    case none
    /// Ask the engine to reveal these sections. Report back with `.transitionSettled`.
    case reveal(Set<Section>)
    /// Ask the engine to conceal everything non-visible. Report back with `.transitionSettled`.
    case conceal
    /// (Re)arm the rehide timer for this deadline.
    case armTimer(Date)
    case cancelTimer
}

public enum RehideEvent: Equatable, Sendable {
    case revealRequested(Set<Section>, RevealReason)
    case concealRequested
    case toggleRequested(Set<Section>, RevealReason)
    case trigger(RehideTrigger)
    /// The engine finished applying the last reveal/conceal.
    case transitionSettled
    /// The pointer re-entered the menubar band (pauses pending rehide).
    case pointerReturned
    /// The pointer left the band: (re)arm the rehide countdown — never an
    /// immediate conceal, the user may be heading to a popover.
    case pointerLeft
}

public struct RehideStateMachine: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case concealed
        /// Engine is applying a transition; queued intent (if any) runs after settle.
        case transitioning(target: Target, queued: Target?)
        case revealed(sections: Set<Section>, reason: RevealReason)

        public enum Target: Equatable, Sendable {
            case reveal(Set<Section>, RevealReason)
            case conceal
        }
    }

    public private(set) var state: State = .concealed
    public var policy: RehidePolicy

    public init(policy: RehidePolicy = RehidePolicy()) {
        self.policy = policy
    }

    public mutating func handle(_ event: RehideEvent, now: Date = Date()) -> [RehideEffect] {
        switch (state, event) {
        // ── Reveal ───────────────────────────────────────────────────────────
        case (.concealed, .revealRequested(let sections, let reason)),
             (.concealed, .toggleRequested(let sections, let reason)):
            state = .transitioning(target: .reveal(sections, reason), queued: nil)
            return [.reveal(sections)]

        case (.revealed(let current, _), .revealRequested(let sections, let reason))
            where !sections.subtracting(current).isEmpty:
            // Widen the reveal (e.g. hidden already out, now always-hidden too).
            let union = current.union(sections)
            state = .transitioning(target: .reveal(union, reason), queued: nil)
            return [.cancelTimer, .reveal(union)]

        case (.revealed, .revealRequested(let sections, let reason)):
            // Already showing these sections — just refresh the timer.
            state = .revealed(sections: sections, reason: reason)
            return armIfNeeded(now: now)

        case (.revealed, .toggleRequested):
            state = .transitioning(target: .conceal, queued: nil)
            return [.cancelTimer, .conceal]

        // ── Conceal ──────────────────────────────────────────────────────────
        case (.revealed, .concealRequested):
            state = .transitioning(target: .conceal, queued: nil)
            return [.cancelTimer, .conceal]

        case (.revealed(_, _), .trigger(let trigger)):
            guard shouldRehide(on: trigger) else { return [.none] }
            state = .transitioning(target: .conceal, queued: nil)
            return [.cancelTimer, .conceal]

        // ── Mid-flight: queue, never interleave ──────────────────────────────
        case (.transitioning(let target, _), .revealRequested(let sections, let reason)):
            state = .transitioning(target: target, queued: .reveal(sections, reason))
            return [.none]

        case (.transitioning(let target, _), .toggleRequested(let sections, let reason)):
            // A toggle means "the opposite of where we're heading" — clicking
            // the chevron during a hover-triggered reveal must queue a conceal,
            // not reinforce the reveal (which reads as a dead click).
            let queued: State.Target = {
                if case .reveal = target { return .conceal }
                return .reveal(sections, reason)
            }()
            state = .transitioning(target: target, queued: queued)
            return [.none]

        case (.transitioning(let target, _), .concealRequested),
             (.transitioning(let target, _), .trigger):
            state = .transitioning(target: target, queued: .conceal)
            return [.none]

        // ── Settle ───────────────────────────────────────────────────────────
        case (.transitioning(let target, let queued), .transitionSettled):
            switch (target, queued) {
            case (.reveal(let sections, let reason), nil):
                state = .revealed(sections: sections, reason: reason)
                return armIfNeeded(now: now)
            case (.conceal, nil):
                state = .concealed
                return [.none]
            case (_, .reveal(let sections, let reason)):
                state = .transitioning(target: .reveal(sections, reason), queued: nil)
                return [.reveal(sections)]
            case (.reveal, .conceal):
                state = .transitioning(target: .conceal, queued: nil)
                return [.conceal]
            case (.conceal, .conceal):
                state = .concealed
                return [.none]
            }

        // ── Pointer pause/resume ─────────────────────────────────────────────
        case (.revealed, .pointerReturned):
            return [.cancelTimer]

        case (.revealed(_, let reason), .pointerLeft):
            // Hover-out after a hover reveal rehides quickly — the user only
            // glanced. Same for a display-policy reveal once the pointer is
            // back on a collapse display. Deliberate reveals (click, hotkey,
            // chevron) keep the full configured delay.
            guard policy.autoRehide else { return [.none] }
            let quick = reason == .hover || reason == .displayPolicy
            let interval = quick ? min(policy.delay, 1.0) : policy.delay
            return [.armTimer(now.addingTimeInterval(interval))]

        default:
            return [.none]
        }
    }

    private func shouldRehide(on trigger: RehideTrigger) -> Bool {
        switch trigger {
        case .delayExpired, .pointerLeftBand:
            return policy.autoRehide
        case .clickedElsewhere:
            return policy.rehideOnClickElsewhere
        case .displayBehaviorChanged:
            return true
        }
    }

    private func armIfNeeded(now: Date) -> [RehideEffect] {
        // Floor the settle-time arm: with the rehide delay dialed to 0, a
        // reveal whose pointer isn't parked in the band concealed within
        // milliseconds of settling — an unreadable open-shut flash (hotkey
        // reveals especially). Pointer-driven rehide stays instant via
        // `.pointerLeft`; only the "never entered the band" case gets a
        // minimum readable window.
        policy.autoRehide
            ? [.armTimer(now.addingTimeInterval(max(policy.delay, 0.75)))]
            : [.none]
    }
}
