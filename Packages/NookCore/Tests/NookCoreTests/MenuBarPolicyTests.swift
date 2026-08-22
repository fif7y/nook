// MenuBarPolicyTests.swift
// The full systemItem suffix table (including negatives), the exempt set, and
// the Nook-extra/unmanaged-Apple predicates.

import CoreGraphics
import Testing
import NookCore

struct MenuBarPolicyTests {
    private func menuExtra(_ suffix: String) -> ItemID {
        .status(bundle: NookBundle.agentID, title: "com.apple.menuextra.\(suffix)")
    }

    @Test func systemItemTableCoversControllableExtras() {
        #expect(MenuBarPolicy.systemItem(for: menuExtra("sound")) == .volume)
        #expect(MenuBarPolicy.systemItem(for: menuExtra("battery")) == .battery)
        #expect(MenuBarPolicy.systemItem(for: menuExtra("wifi")) == .wifi)
        #expect(MenuBarPolicy.systemItem(for: menuExtra("clock")) == .clock)
        #expect(MenuBarPolicy.systemItem(for: menuExtra("bluetooth")) == .bluetooth)
        #expect(MenuBarPolicy.systemItem(for: menuExtra("display")) == .displays)
        #expect(MenuBarPolicy.systemItem(for: menuExtra("displays")) == .displays)
        #expect(MenuBarPolicy.systemItem(for: menuExtra("textinput")) == .keyboard)
        #expect(MenuBarPolicy.systemItem(for: menuExtra("keyboard")) == .keyboard)
        #expect(MenuBarPolicy.systemItem(for: menuExtra("screen-mirroring")) == .screenMirroring)
    }

    @Test func systemItemTableRejectsNonControllableIDs() {
        // The camera pill is a menuextra but NOT individually controllable.
        #expect(MenuBarPolicy.systemItem(for: menuExtra("audiovideo")) == nil)
        // A third-party title that merely ends in a matching suffix is not a
        // system item — the menuextra marker gates the table.
        #expect(MenuBarPolicy.systemItem(for: .status(bundle: "com.example.App", title: "sound")) == nil)
        #expect(MenuBarPolicy.systemItem(for: .bundleKey("com.example.App")) == nil)
    }

    @Test func exemptBundlesAreNookAndAgent() {
        #expect(
            MenuBarPolicy.identityExemptBundles(nookBundleID: "app.fif7y.Nook")
                == ["app.fif7y.Nook", NookBundle.agentID]
        )
    }

    @Test func nookExtraIDMatchesOwnedExtrasNotChevron() {
        #expect(MenuBarPolicy.isNookExtraID(.status(bundle: NookBundle.fallbackID, title: "Nook.Extra.media")))
        #expect(MenuBarPolicy.isNookExtraID(.status(bundle: NookBundle.fallbackID, title: "Nook.Separator.X")))
        #expect(!MenuBarPolicy.isNookExtraID(.status(bundle: NookBundle.fallbackID, title: "Nook.StatusItem")))
        #expect(!MenuBarPolicy.isNookExtraID(.status(bundle: "com.example.App", title: "Item-0")))
    }

    @Test func unmanagedAppleBundleIsApplePrefixOnly() {
        #expect(MenuBarPolicy.isUnmanagedAppleBundle("com.apple.Siri"))
        #expect(!MenuBarPolicy.isUnmanagedAppleBundle("com.example.App"))
        #expect(!MenuBarPolicy.isUnmanagedAppleBundle(nil))
    }

    @Test func bandPredicateAcceptsMainBarBandOnly() {
        #expect(MenuBarGeometry.isInBand(CGRect(x: 100, y: 0, width: 30, height: 24)))
        #expect(!MenuBarGeometry.isInBand(CGRect(x: 100, y: 800, width: 30, height: 24)))
        #expect(!MenuBarGeometry.isInBand(CGRect(x: 100, y: -30, width: 30, height: 24)))
    }
}
