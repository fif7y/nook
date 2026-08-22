// AgentPositionStoreTests.swift
// The pure positions merge: descending gap spacing, tag-variant spread,
// unmanaged-tag preservation, and the merged-dict return contract.

import Testing
import NookCore
@testable import NookEngine

struct AgentPositionStoreTests {
    let velja = "status:com.sindresorhus.Velja::Item-0"
    let veljaVariant = "status:com.sindresorhus.Velja::Left arrows"
    let figma = "status:com.figma.Desktop::Item-0"

    @Test func assignsDescendingGapSpacedValues() {
        let positions = AgentPositionStore.positions(applying: [velja, figma], to: [:])
        #expect(positions[velja] == 200)
        #expect(positions[figma] == 100)
    }

    @Test func variantSpreadGivesEveryKnownTwinTheSameSlot() {
        let positions = AgentPositionStore.positions(
            applying: [velja],
            to: [veljaVariant: 950]
        )
        #expect(positions[velja] == 100)
        #expect(positions[veljaVariant] == 100)
    }

    @Test func unmanagedTagsKeepTheirValues() {
        let positions = AgentPositionStore.positions(
            applying: [velja],
            to: ["status:com.apple.MenuBarAgent::com.apple.menuextra.clock": 7]
        )
        #expect(positions["status:com.apple.MenuBarAgent::com.apple.menuextra.clock"] == 7)
    }

    @Test func nookOwnedTagsGetNoVariantSpread() {
        // sectionKey == self for Nook's own items — only the exact tag slots.
        let chevron = "status:app.fif7y.Nook::Nook.StatusItem"
        let extra = "status:app.fif7y.Nook::Nook.MediaControls"
        let positions = AgentPositionStore.positions(
            applying: [chevron],
            to: [extra: 950]
        )
        #expect(positions[chevron] == 100)
        #expect(positions[extra] == 950)
    }

    @Test func returnIsTheEntireMergedDict() {
        // Documents the CURRENT contract: ghost tags from prior sessions ride
        // along in the return value. Re-mint detection upstream treats
        // "tag ∈ returned keys" as "got a slot" — see addendum A3 before
        // narrowing this to per-pass slots.
        let positions = AgentPositionStore.positions(
            applying: [velja],
            to: ["status:com.dead.App::Item-0": 300]
        )
        #expect(Set(positions.keys) == [velja, "status:com.dead.App::Item-0"])
    }
}
