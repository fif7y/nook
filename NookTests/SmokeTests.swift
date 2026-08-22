// SmokeTests.swift
// First app-target tests: the pure ItemID predicates on AppState.

import Testing
import NookCore
@testable import Nook

struct SmokeTests {
    @Test func nookExtraIDMatchesOwnedExtrasNotChevron() {
        #expect(AppState.isNookExtraID(ItemID(rawValue: "status:app.fif7y.Nook::Nook.Extra.media")))
        #expect(!AppState.isNookExtraID(ItemID(rawValue: "status:app.fif7y.Nook::Nook.StatusItem")))
        #expect(!AppState.isNookExtraID(ItemID(rawValue: "status:com.example.App::Item-0")))
    }

    @Test func unmanagedAppleBundleIsApplePrefixOnly() {
        #expect(AppState.isUnmanagedAppleBundle("com.apple.Siri"))
        #expect(!AppState.isUnmanagedAppleBundle("com.example.App"))
        #expect(!AppState.isUnmanagedAppleBundle(nil))
    }
}
