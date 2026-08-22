import Foundation
import Testing
@testable import NookCore

@Suite struct SectionModelRegisterTests {
    private func id(_ bundle: String, _ title: String = "Item") -> ItemID {
        ItemID(rawValue: "status:\(bundle)::\(title)")
    }

    private func key(_ bundle: String) -> ItemID {
        ItemID(rawValue: "bundle:\(bundle)")
    }

    @Test func emptyKnownSetIsSilentBaseline() {
        var model = SectionModel(newItemsDestination: .hidden)
        let changed = model.registerObservedItems([id("com.figma.Desktop"), id("com.herd.app")])
        #expect(changed)
        #expect(model.knownBundles == ["com.figma.Desktop", "com.herd.app"])
        #expect(model.assignments.isEmpty)
    }

    @Test func newBundleRoutesToDestination() {
        var model = SectionModel(
            order: [.hidden: [key("com.herd.app")]],
            newItemsDestination: .hidden,
            knownBundles: ["com.herd.app"]
        )
        let figma = id("com.figma.Desktop")
        let changed = model.registerObservedItems([figma, id("com.herd.app")])
        #expect(changed)
        #expect(model.section(of: figma) == .hidden)
        // Canonical key, front of the order — new icons spawn at the far left.
        #expect(model.order[.hidden]?.first == key("com.figma.Desktop"))
        #expect(model.knownBundles.contains("com.figma.Desktop"))
    }

    @Test func twoItemsOfNewBundleRouteOnce() {
        var model = SectionModel(newItemsDestination: .hidden, knownBundles: ["com.herd.app"])
        let changed = model.registerObservedItems([
            id("com.figma.Desktop", "A"), id("com.figma.Desktop", "B"),
        ])
        #expect(changed)
        #expect(model.assignments == [key("com.figma.Desktop"): .hidden])
        #expect(model.order[.hidden] == [key("com.figma.Desktop")])
    }

    @Test func visibleDestinationLeavesNewItemUnassigned() {
        var model = SectionModel(newItemsDestination: .visible, knownBundles: ["com.herd.app"])
        let figma = id("com.figma.Desktop")
        let changed = model.registerObservedItems([figma])
        #expect(changed)
        #expect(model.assignments[figma.sectionKey] == nil)
        #expect(model.knownBundles.contains("com.figma.Desktop"))
    }

    @Test func knownBundleNewTitleNotRouted() {
        var model = SectionModel(newItemsDestination: .hidden, knownBundles: ["com.stats.app"])
        let changed = model.registerObservedItems([id("com.stats.app", "13%")])
        #expect(!changed)
        #expect(model.assignments.isEmpty)
    }

    @Test func existingAssignmentNeverOverwritten() {
        let figma = id("com.figma.Desktop")
        var model = SectionModel(
            assignments: [figma.sectionKey: .alwaysHidden],
            newItemsDestination: .hidden,
            knownBundles: ["com.herd.app"]
        )
        let changed = model.registerObservedItems([figma])
        #expect(changed)
        #expect(model.section(of: figma) == .alwaysHidden)
    }

    @Test func preKnownBundlesBlobDecodesWithEmptySet() throws {
        let old = SectionModel(assignments: [id("com.herd.app").sectionKey: .hidden])
        var dict = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any]
        )
        dict.removeValue(forKey: "knownBundles")
        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(SectionModel.self, from: data)
        #expect(decoded.knownBundles.isEmpty)
        #expect(decoded.assignments == old.assignments)
    }
}

@Suite struct SectionKeyTests {
    @Test func thirdPartyCollapsesToBundle() {
        let a = ItemID(rawValue: "status:com.sindresorhus.Velja::Item-0")
        let b = ItemID(rawValue: "status:com.sindresorhus.Velja::Left and right arrows in a filled circle")
        #expect(a.sectionKey == b.sectionKey)
        #expect(a.sectionKey == ItemID(rawValue: "bundle:com.sindresorhus.Velja"))
        #expect(a.sectionKey.bundleID == "com.sindresorhus.Velja")
    }

    @Test func nookAndSystemItemsKeepFullIdentity() {
        let extra = ItemID(rawValue: "status:app.fif7y.Nook::Nook.MediaControls")
        let system = ItemID(rawValue: "status:com.apple.MenuBarAgent::com.apple.menuextra.sound")
        let module = ItemID(rawValue: "module:Clock")
        #expect(extra.sectionKey == extra)
        #expect(system.sectionKey == system)
        #expect(module.sectionKey == module)
    }

    @Test func canonicalizeMergesTitleVariantTwins() {
        let old = ItemID(rawValue: "status:com.sindresorhus.Velja::Left and right arrows in a filled circle")
        let new = ItemID(rawValue: "status:com.sindresorhus.Velja::Item-0")
        var model = SectionModel(
            assignments: [old: .alwaysHidden, new: .hidden],
            order: [.alwaysHidden: [old], .hidden: [new]]
        )
        model.canonicalize()
        let key = old.sectionKey
        // One entry survives; the order-backed section is among the twins'.
        #expect(model.assignments.count == 1)
        let section = model.assignments[key]
        #expect(section == .alwaysHidden || section == .hidden)
        // The winner keeps exactly one order slot, in its own section only.
        let holding = model.order.filter { $0.value.contains(key) }
        #expect(holding.count == 1)
        #expect(holding.first?.key == section)
        #expect(model.section(of: new) == section)
        #expect(model.section(of: old) == section)
    }

    @Test func canonicalizeIsIdempotent() {
        let old = ItemID(rawValue: "status:com.sindresorhus.Velja::Left and right arrows in a filled circle")
        let new = ItemID(rawValue: "status:com.sindresorhus.Velja::Item-0")
        var model = SectionModel(
            assignments: [old: .alwaysHidden, new: .hidden],
            order: [.alwaysHidden: [old], .hidden: [new]]
        )
        model.canonicalize()
        let once = model
        model.canonicalize()
        #expect(model == once)
    }
}
