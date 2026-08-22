// EditorItemsBuilderTests.swift
// Locks the editor-board rules: twin collapse, concealed stand-ins, stored
// no-flash members, explicit-order sort with the frame-nil-rightmost
// tiebreak, and extras/separators representation.

import CoreGraphics
import Testing
import NookCore
import NookEngine
@testable import Nook

@MainActor
struct EditorItemsBuilderTests {
    let nook = "app.fif7y.Nook"
    let velja = ItemID(rawValue: "status:com.sindresorhus.Velja::Item-0")
    let veljaTwin = ItemID(rawValue: "status:com.sindresorhus.Velja::Left arrows")
    let figma = ItemID(rawValue: "status:com.figma.Desktop::Item-0")

    func frame(x: CGFloat) -> CGRect {
        CGRect(x: x, y: 0, width: 30, height: 24)
    }

    func build(
        section: NookCore.Section = .hidden,
        items: [ObservedItem] = [],
        concealed: Set<ItemID> = [],
        extras: [ExtraItemSpec] = [],
        separators: [SeparatorSpec] = [],
        model: SectionModel = SectionModel(),
        running: Set<String> = [],
        names: [String: String] = [:]
    ) -> [ObservedItem] {
        EditorItemsBuilder.build(
            section: section,
            snapshotItems: items,
            concealed: concealed,
            extraItems: extras,
            separators: separators,
            model: model,
            nookBundleID: nook,
            isRunning: { running.contains($0) },
            appName: { names[$0] }
        )
    }

    @Test func liveTwinsCollapseToLeftmostFrame() {
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        let result = build(
            items: [
                ObservedItem(id: velja, frame: frame(x: 300), appName: "Velja"),
                ObservedItem(id: veljaTwin, frame: frame(x: 200), appName: "Velja"),
            ],
            model: model
        )
        #expect(result.count == 1)
        #expect(result.first?.id == veljaTwin)
    }

    @Test func concealedItemGetsStandInWithAppName() {
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        let result = build(
            concealed: [velja],
            model: model,
            names: ["com.sindresorhus.Velja": "Velja"]
        )
        #expect(result.map(\.id) == [velja])
        #expect(result.first?.frame == nil)
        #expect(result.first?.appName == "Velja")
    }

    @Test func staleConcealedTwinOfLiveBundleDrops() {
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        let result = build(
            items: [ObservedItem(id: velja, frame: frame(x: 300), appName: "Velja")],
            concealed: [veljaTwin],
            model: model
        )
        #expect(result.map(\.id) == [velja])
    }

    @Test func storedRunningMemberAppearsQuitAppStaysOff() {
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        model.assignments[figma.sectionKey] = .hidden
        let result = build(
            model: model,
            running: ["com.sindresorhus.Velja"],
            names: ["com.sindresorhus.Velja": "Velja"]
        )
        #expect(result.map(\.id) == [velja.sectionKey])
        #expect(result.first?.frame == nil)
    }

    @Test func explicitOrderOutranksFramesAndFrameNilSortsRightmost() {
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        model.assignments[figma.sectionKey] = .hidden
        model.order[.hidden] = [figma.sectionKey]
        let result = build(
            items: [ObservedItem(id: velja, frame: frame(x: 100), appName: nil)],
            concealed: [figma],
            model: model
        )
        // Figma is explicitly ordered first despite Velja's live frame.
        #expect(result.map(\.id) == [figma, velja])

        // Without explicit order, the frame-nil stand-in sorts rightmost.
        model.order[.hidden] = []
        let unordered = build(
            items: [ObservedItem(id: velja, frame: frame(x: 100), appName: nil)],
            concealed: [figma],
            model: model
        )
        #expect(unordered.map(\.id) == [velja, figma])
    }

    @Test func nookExtrasAndSeparatorsAreRepresented() {
        let extra = ExtraItemSpec(kind: .mediaControls)
        let separator = SeparatorSpec(style: .pipe)
        var model = SectionModel()
        model.assignments[ExtrasManager.itemID(for: extra)] = .hidden
        model.assignments[SeparatorManager.itemID(for: separator)] = .hidden
        let result = build(
            extras: [extra],
            separators: [separator],
            model: model
        )
        #expect(Set(result.map(\.id)) == [
            ExtrasManager.itemID(for: extra),
            SeparatorManager.itemID(for: separator),
        ])
    }

    @Test func appleAndSystemModuleItemsStayOffTheBoard() {
        let clock = ItemID(rawValue: "status:com.apple.MenuBarAgent::com.apple.menuextra.clock")
        let siri = ItemID(rawValue: "status:com.apple.Siri::Item-0")
        var model = SectionModel()
        model.assignments[clock] = .hidden
        model.assignments[siri.sectionKey] = .hidden
        let result = build(
            items: [
                ObservedItem(id: clock, frame: frame(x: 100), appName: nil),
                ObservedItem(id: siri, frame: frame(x: 130), appName: "Siri"),
            ],
            model: model
        )
        // The clock is assertion-controllable (SystemItem table) — it stays;
        // Siri (unmanaged Apple bundle, no SystemItem mapping) does not.
        #expect(result.map(\.id) == [clock])
    }
}
