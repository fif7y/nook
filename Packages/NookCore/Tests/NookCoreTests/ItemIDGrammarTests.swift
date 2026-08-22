// ItemIDGrammarTests.swift
// Round-trip and accessor-equivalence tests for the tag grammar. The corpus
// covers every real shape: third-party status tags, agent system tags, Nook's
// own items, canonical bundle keys, modules, and degenerate raw values.

import Testing
import NookCore

struct ItemIDGrammarTests {
    let corpus: [ItemID] = [
        ItemID(rawValue: "status:com.sindresorhus.Velja::Item-0"),
        ItemID(rawValue: "status:com.sindresorhus.Velja::Left and right arrows in a filled circle"),
        ItemID(rawValue: "status:com.apple.MenuBarAgent::com.apple.menuextra.clock"),
        ItemID(rawValue: "status:app.fif7y.Nook::Nook.Separator.ABC-123"),
        ItemID(rawValue: "bundle:com.figma.Desktop"),
        ItemID(rawValue: "module:BentoBox"),
        ItemID(rawValue: "status:degenerate-no-separator"),
        ItemID(rawValue: "garbage"),
    ]

    @Test func formattersRoundTripThroughParser() {
        #expect(ItemID.status(bundle: "com.a.B", title: "T").parsed == .status(bundle: "com.a.B", title: "T"))
        #expect(ItemID.module("X").parsed == .module("X"))
        #expect(ItemID.bundleKey("com.a.B").parsed == .bundleKey("com.a.B"))
    }

    @Test func parserAgreesWithFastAccessors() {
        for id in corpus {
            switch id.parsed {
            case .status(let bundle, _):
                #expect(id.bundleID == bundle, "\(id.rawValue)")
                #expect(!id.isSystemModule, "\(id.rawValue)")
            case .bundleKey(let bundle):
                #expect(id.bundleID == bundle, "\(id.rawValue)")
                #expect(!id.isSystemModule, "\(id.rawValue)")
            case .module:
                #expect(id.isSystemModule, "\(id.rawValue)")
                #expect(id.bundleID == nil, "\(id.rawValue)")
            case .opaque:
                #expect(id.bundleID == nil, "\(id.rawValue)")
                #expect(!id.isSystemModule, "\(id.rawValue)")
            }
        }
    }

    @Test func sectionKeyCollapsesOnlyThirdPartyStatusTags() {
        #expect(
            ItemID.status(bundle: "com.sindresorhus.Velja", title: "Item-0").sectionKey
                == .bundleKey("com.sindresorhus.Velja")
        )
        let nookExtra = ItemID.status(bundle: "app.fif7y.Nook", title: "Nook.Extra.media")
        #expect(nookExtra.sectionKey == nookExtra)
        let agentClock = ItemID.status(bundle: "com.apple.MenuBarAgent", title: "com.apple.menuextra.clock")
        #expect(agentClock.sectionKey == agentClock)
    }

    @Test func statusTagPrefixMatchesEveryTitleVariant() {
        let prefix = ItemID.statusTagPrefix(bundle: "com.sindresorhus.Velja")
        #expect(ItemID.status(bundle: "com.sindresorhus.Velja", title: "A").rawValue.hasPrefix(prefix))
        #expect(ItemID.status(bundle: "com.sindresorhus.Velja", title: "Item-0").rawValue.hasPrefix(prefix))
        #expect(!ItemID.bundleKey("com.sindresorhus.Velja").rawValue.hasPrefix(prefix))
        #expect(!ItemID.status(bundle: "com.sindresorhus.VeljaX", title: "A").rawValue.hasPrefix(prefix))
    }
}
