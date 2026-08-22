// SmokeTests.swift
// Harness smoke for the NookTests bundle — real app-layer tests land with the
// EditorItemsBuilder/PlacementGeometry extractions.

import Testing
import NookCore
@testable import Nook

struct SmokeTests {
    @Test func appTargetLinksSharedPolicy() {
        #expect(MenuBarPolicy.isNookExtraID(ItemID(rawValue: "status:app.fif7y.Nook::Nook.Extra.media")))
    }
}
