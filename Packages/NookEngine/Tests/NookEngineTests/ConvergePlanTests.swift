import Foundation
import Testing
import NookCore
@testable import NookEngine

@Suite struct ConvergePlanTests {
    let velja = ItemID(rawValue: "status:com.sindresorhus.Velja::Item-0")
    let veljaDrifted = ItemID(rawValue: "status:com.sindresorhus.Velja::Left and right arrows in a filled circle")
    let bitwarden = ItemID(rawValue: "status:com.bitwarden.desktop::Item-0")
    let sound = ItemID(rawValue: "status:com.apple.MenuBarAgent::com.apple.menuextra.sound")
    let exempt: Set<String> = ["app.fif7y.Nook", "com.apple.MenuBarAgent"]

    func model(_ assignments: [ItemID: NookCore.Section]) -> SectionModel {
        SectionModel(assignments: assignments)
    }

    @Test func hiddenAssignmentConcealsObservedBundle() {
        let plan = ConvergePlan.compute(
            model: model([velja: .alwaysHidden, bitwarden: .hidden]),
            liveIDs: [velja, bitwarden],
            carriedConcealed: [],
            runningBundles: ["com.sindresorhus.Velja", "com.bitwarden.desktop", "com.apple.finder"],
            revealedSections: [],
            steadyExtras: true,
            exemptBundles: exempt
        )
        #expect(plan.concealable == ["com.sindresorhus.Velja", "com.bitwarden.desktop"])
        #expect(plan.concealed == [velja, bitwarden])
        #expect(!plan.allowedBundles.contains("com.sindresorhus.Velja"))
        #expect(plan.allowedBundles.contains("com.apple.finder"))
        #expect(!plan.dropAssertion)
    }

    @Test func revealingSectionReleasesItsBundles() {
        let plan = ConvergePlan.compute(
            model: model([velja: .alwaysHidden, bitwarden: .hidden]),
            liveIDs: [velja, bitwarden],
            carriedConcealed: [],
            runningBundles: [],
            revealedSections: [.hidden],
            steadyExtras: true,
            exemptBundles: exempt
        )
        #expect(plan.concealable == ["com.sindresorhus.Velja"])
        #expect(plan.concealed == [velja])
        #expect(plan.allowedBundles.contains("com.bitwarden.desktop"))
    }

    @Test func concealedCarriedItemStaysConcealableWhileUnobservable() {
        // The oscillation case: item concealed → unobservable. The carried
        // set must keep it in the concealable computation.
        let plan = ConvergePlan.compute(
            model: model([velja: .alwaysHidden]),
            liveIDs: [],
            carriedConcealed: [velja],
            runningBundles: ["com.sindresorhus.Velja"],
            revealedSections: [],
            steadyExtras: true,
            exemptBundles: exempt
        )
        #expect(plan.concealable == ["com.sindresorhus.Velja"])
        #expect(plan.concealed == [velja])
    }

    @Test func driftedTagPrunesStaleAliasFromConcealed() {
        // Velja re-enumerated under a new tag while its old tag rode the
        // carried set — the plan keeps ONE concealed entry, the live one.
        let plan = ConvergePlan.compute(
            model: model([veljaDrifted: .alwaysHidden]),
            liveIDs: [veljaDrifted],
            carriedConcealed: [velja],
            runningBundles: ["com.sindresorhus.Velja"],
            revealedSections: [],
            steadyExtras: true,
            exemptBundles: exempt
        )
        #expect(plan.stale == [velja: .staleAlias])
        #expect(plan.concealed == [veljaDrifted])
    }

    @Test func quitAppLeavesConcealedSet() {
        let plan = ConvergePlan.compute(
            model: model([velja: .alwaysHidden]),
            liveIDs: [],
            carriedConcealed: [velja],
            runningBundles: [],
            revealedSections: [],
            steadyExtras: true,
            exemptBundles: exempt
        )
        #expect(plan.stale == [velja: .quitApp])
        #expect(plan.concealed.isEmpty)
    }

    @Test func explicitVisibleSystemAssignmentNeverHides() {
        let plan = ConvergePlan.compute(
            model: model([sound: .visible]),
            liveIDs: [sound],
            carriedConcealed: [],
            runningBundles: [],
            revealedSections: [],
            steadyExtras: true,
            exemptBundles: exempt
        )
        #expect(plan.hiddenSystem.isEmpty)
        #expect(plan.allowedSystem.contains(.volume))
    }

    @Test func hiddenSystemAssignmentLeavesAllowlist() {
        let plan = ConvergePlan.compute(
            model: model([sound: .hidden]),
            liveIDs: [sound],
            carriedConcealed: [],
            runningBundles: [],
            revealedSections: [],
            steadyExtras: true,
            exemptBundles: exempt
        )
        #expect(plan.hiddenSystem == [.volume])
        #expect(!plan.allowedSystem.contains(.volume))
        #expect(plan.concealed == [sound])
    }

    @Test func nothingToHideWithoutSteadyExtrasDropsAssertion() {
        let plan = ConvergePlan.compute(
            model: model([:]),
            liveIDs: [velja],
            carriedConcealed: [],
            runningBundles: ["com.sindresorhus.Velja"],
            revealedSections: [],
            steadyExtras: false,
            exemptBundles: exempt
        )
        #expect(plan.dropAssertion)
        #expect(plan.concealed.isEmpty)
        #expect(plan.allowedBundles.isEmpty)
    }

    @Test func steadyExtrasHoldsAssertionWithNothingConcealable() {
        let plan = ConvergePlan.compute(
            model: model([:]),
            liveIDs: [velja],
            carriedConcealed: [],
            runningBundles: ["com.sindresorhus.Velja"],
            revealedSections: [],
            steadyExtras: true,
            exemptBundles: exempt
        )
        #expect(!plan.dropAssertion)
        #expect(plan.allowedBundles.contains("com.sindresorhus.Velja"))
    }
}
