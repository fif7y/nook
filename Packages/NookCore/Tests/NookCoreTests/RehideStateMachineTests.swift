import Foundation
import Testing
@testable import NookCore

@Suite struct RehideStateMachineTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func revealThenSettleArmsTimer() {
        var machine = RehideStateMachine(policy: .init(autoRehide: true, delay: 5))
        let effects = machine.handle(.revealRequested([.hidden], .hover), now: now)
        #expect(effects == [.reveal([.hidden])])
        let settled = machine.handle(.transitionSettled, now: now)
        #expect(settled == [.armTimer(now.addingTimeInterval(5))])
        #expect(machine.state == .revealed(sections: [.hidden], reason: .hover))
    }

    @Test func noTimerWhenAutoRehideOff() {
        var machine = RehideStateMachine(policy: .init(autoRehide: false))
        _ = machine.handle(.revealRequested([.hidden], .click), now: now)
        let settled = machine.handle(.transitionSettled, now: now)
        #expect(settled == [.none])
    }

    @Test func delayExpiryConceals() {
        var machine = RehideStateMachine()
        _ = machine.handle(.revealRequested([.hidden], .hover), now: now)
        _ = machine.handle(.transitionSettled, now: now)
        let effects = machine.handle(.trigger(.delayExpired), now: now)
        #expect(effects == [.cancelTimer, .conceal])
        _ = machine.handle(.transitionSettled, now: now)
        #expect(machine.state == .concealed)
    }

    @Test func clickElsewhereRespectsPolicy() {
        var machine = RehideStateMachine(policy: .init(rehideOnClickElsewhere: false))
        _ = machine.handle(.revealRequested([.hidden], .click), now: now)
        _ = machine.handle(.transitionSettled, now: now)
        let effects = machine.handle(.trigger(.clickedElsewhere), now: now)
        #expect(effects == [.none])
        #expect(machine.state == .revealed(sections: [.hidden], reason: .click))
    }

    @Test func midFlightTriggerRespectsClickElsewherePolicy() {
        var machine = RehideStateMachine(policy: .init(rehideOnClickElsewhere: false))
        _ = machine.handle(.revealRequested([.hidden], .click), now: now)
        // Click elsewhere while the reveal is still applying: policy says no.
        let effects = machine.handle(.trigger(.clickedElsewhere), now: now)
        #expect(effects == [.none])
        _ = machine.handle(.transitionSettled, now: now)
        #expect(machine.state == .revealed(sections: [.hidden], reason: .click))
    }

    @Test func hoverRefireDoesNotCancelQueuedConceal() {
        var machine = RehideStateMachine()
        _ = machine.handle(.revealRequested([.hidden], .hover), now: now)
        // Chevron click mid-reveal queues a conceal…
        _ = machine.handle(.toggleRequested([.hidden], .click), now: now)
        // …and a hover re-fire must not overwrite it.
        _ = machine.handle(.revealRequested([.hidden], .hover), now: now)
        let effects = machine.handle(.transitionSettled, now: now)
        #expect(effects == [.conceal])
    }

    @Test func subsetRevealKeepsWiderSectionsAndReason() {
        var machine = RehideStateMachine()
        _ = machine.handle(.revealRequested([.hidden, .alwaysHidden], .doubleClick), now: now)
        _ = machine.handle(.transitionSettled, now: now)
        // A routine hover refresh for a subset must not narrow tracking or
        // downgrade the deliberate reveal onto hover's quick clock.
        _ = machine.handle(.revealRequested([.hidden], .hover), now: now)
        #expect(machine.state == .revealed(sections: [.hidden, .alwaysHidden], reason: .doubleClick))
        let left = machine.handle(.pointerLeft, now: now)
        #expect(left == [.armTimer(now.addingTimeInterval(5))])
    }

    @Test func midFlightRequestsQueueInsteadOfToggling() {
        var machine = RehideStateMachine()
        _ = machine.handle(.revealRequested([.hidden], .hover), now: now)
        // Conceal request lands while the reveal is still applying.
        let queued = machine.handle(.concealRequested, now: now)
        #expect(queued == [.none])
        // Settle of the reveal immediately dispatches the queued conceal.
        let effects = machine.handle(.transitionSettled, now: now)
        #expect(effects == [.conceal])
        _ = machine.handle(.transitionSettled, now: now)
        #expect(machine.state == .concealed)
    }

    @Test func wideningRevealUnionsSections() {
        var machine = RehideStateMachine()
        _ = machine.handle(.revealRequested([.hidden], .hover), now: now)
        _ = machine.handle(.transitionSettled, now: now)
        let effects = machine.handle(.revealRequested([.alwaysHidden], .doubleClick), now: now)
        #expect(effects == [.cancelTimer, .reveal([.hidden, .alwaysHidden])])
    }

    @Test func toggleWhileRevealedConceals() {
        var machine = RehideStateMachine()
        _ = machine.handle(.toggleRequested([.hidden], .statusItem), now: now)
        _ = machine.handle(.transitionSettled, now: now)
        let effects = machine.handle(.toggleRequested([.hidden], .statusItem), now: now)
        #expect(effects == [.cancelTimer, .conceal])
    }

    @Test func pointerLeaveAfterHoverArmsQuickTimer() {
        var machine = RehideStateMachine(policy: .init(autoRehide: true, delay: 5))
        _ = machine.handle(.revealRequested([.hidden], .hover), now: now)
        _ = machine.handle(.transitionSettled, now: now)
        _ = machine.handle(.pointerReturned, now: now)
        let effects = machine.handle(.pointerLeft, now: now)
        // Hover reveals rehide fast on hover-out; the 5s delay is for
        // deliberate reveals.
        #expect(effects == [.armTimer(now.addingTimeInterval(1))])
        #expect(machine.state == .revealed(sections: [.hidden], reason: .hover))
    }

    @Test func pointerLeaveAfterDisplayPolicyArmsQuickTimer() {
        var machine = RehideStateMachine(policy: .init(autoRehide: true, delay: 5))
        _ = machine.handle(.revealRequested([.hidden], .displayPolicy), now: now)
        _ = machine.handle(.transitionSettled, now: now)
        // Crossing back to a collapse display arms the quick clock, like a
        // hover-out — the reveal wasn't a deliberate user action.
        let effects = machine.handle(.pointerLeft, now: now)
        #expect(effects == [.armTimer(now.addingTimeInterval(1))])
    }

    @Test func pointerLeaveAfterClickKeepsFullDelay() {
        var machine = RehideStateMachine(policy: .init(autoRehide: true, delay: 5))
        _ = machine.handle(.revealRequested([.hidden], .click), now: now)
        _ = machine.handle(.transitionSettled, now: now)
        let effects = machine.handle(.pointerLeft, now: now)
        #expect(effects == [.armTimer(now.addingTimeInterval(5))])
    }

    @Test func toggleDuringRevealTransitionQueuesConceal() {
        var machine = RehideStateMachine()
        _ = machine.handle(.revealRequested([.hidden], .hover), now: now)
        // Chevron click lands while the hover reveal is still applying.
        _ = machine.handle(.toggleRequested([.hidden], .statusItem), now: now)
        let effects = machine.handle(.transitionSettled, now: now)
        #expect(effects == [.conceal])
        _ = machine.handle(.transitionSettled, now: now)
        #expect(machine.state == .concealed)
    }

    @Test func redundantRevealRefreshesTimer() {
        var machine = RehideStateMachine(policy: .init(autoRehide: true, delay: 5))
        _ = machine.handle(.revealRequested([.hidden], .hover), now: now)
        _ = machine.handle(.transitionSettled, now: now)
        let later = now.addingTimeInterval(3)
        let effects = machine.handle(.revealRequested([.hidden], .hover), now: later)
        #expect(effects == [.armTimer(later.addingTimeInterval(5))])
    }
}

@Suite struct SectionModelTests {
    @Test func bundleIDParsing() {
        #expect(ItemID(rawValue: "status:com.foo.bar::Item-0").bundleID == "com.foo.bar")
        #expect(ItemID(rawValue: "module:Clock").bundleID == nil)
        #expect(ItemID(rawValue: "module:Clock").isSystemModule)
    }

    @Test func concealableRespectsBundleConflicts() {
        // Two items of the same bundle: one visible, one hidden → bundle not concealable.
        let itemA = ItemID(rawValue: "status:com.foo.app::Item-0")
        let itemB = ItemID(rawValue: "status:com.foo.app::Item-1")
        let lonely = ItemID(rawValue: "status:com.bar.app::Item-0")
        let model = SectionModel(assignments: [itemB: .hidden, lonely: .hidden])
        let concealable = model.concealableBundleIDs(
            observedItems: [itemA, itemB, lonely],
            revealing: []
        )
        #expect(concealable == ["com.bar.app"])
    }

    @Test func revealingSectionMovesBundlesToAllowlist() {
        let hidden = ItemID(rawValue: "status:com.a.app::Item-0")
        let always = ItemID(rawValue: "status:com.b.app::Item-0")
        let model = SectionModel(assignments: [hidden: .hidden, always: .alwaysHidden])
        let revealed = model.concealableBundleIDs(
            observedItems: [hidden, always],
            revealing: [.hidden]
        )
        #expect(revealed == ["com.b.app"])
    }
}
