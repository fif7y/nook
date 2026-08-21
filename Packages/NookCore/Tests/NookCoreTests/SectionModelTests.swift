import Foundation
import Testing
@testable import NookCore

@Suite struct SectionModelRegisterTests {
    private func id(_ bundle: String, _ title: String = "Item") -> ItemID {
        ItemID(rawValue: "status:\(bundle)::\(title)")
    }

    @Test func emptyKnownSetIsSilentBaseline() {
        var model = SectionModel(newItemsDestination: .hidden)
        let changed = model.registerObservedItems([id("com.figma.Desktop"), id("com.herd.app")])
        #expect(changed)
        #expect(model.knownBundles == ["com.figma.Desktop", "com.herd.app"])
        #expect(model.assignments.isEmpty)
    }

    @Test func newBundleRoutesToDestination() {
        var model = SectionModel(newItemsDestination: .hidden, knownBundles: ["com.herd.app"])
        let figma = id("com.figma.Desktop")
        let changed = model.registerObservedItems([figma, id("com.herd.app")])
        #expect(changed)
        #expect(model.section(of: figma) == .hidden)
        #expect(model.order[.hidden]?.contains(figma) == true)
        #expect(model.knownBundles.contains("com.figma.Desktop"))
    }

    @Test func visibleDestinationLeavesNewItemUnassigned() {
        var model = SectionModel(newItemsDestination: .visible, knownBundles: ["com.herd.app"])
        let figma = id("com.figma.Desktop")
        let changed = model.registerObservedItems([figma])
        #expect(changed)
        #expect(model.assignments[figma] == nil)
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
            assignments: [figma: .alwaysHidden],
            newItemsDestination: .hidden,
            knownBundles: ["com.herd.app"]
        )
        let changed = model.registerObservedItems([figma])
        #expect(changed)
        #expect(model.section(of: figma) == .alwaysHidden)
    }

    @Test func preKnownBundlesBlobDecodesWithEmptySet() throws {
        let old = SectionModel(assignments: [id("com.herd.app"): .hidden])
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
