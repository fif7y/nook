// BarAdoptionTests.swift
// Locks the ⌘-drag adoption rules: chevron gating, first-pass baseline,
// zone-change-only adoption, guessed-zone non-persistence, and the
// within-section order fold-in.

import CoreGraphics
import Testing
import NookCore

struct BarAdoptionTests {
    let nook = "app.fif7y.Nook"
    let chevron = ItemID(rawValue: "status:app.fif7y.Nook::Nook.StatusItem")
    let velja = ItemID(rawValue: "status:com.sindresorhus.Velja::Item-0")
    let figma = ItemID(rawValue: "status:com.figma.Desktop::Item-0")
    let anchor = ItemID(rawValue: "status:com.example.Anchor::Item-0")

    @Test func missingChevronMeansNoReconciliation() {
        let result = BarAdoption.reconcile(
            items: [(id: velja, minX: 500)],
            model: SectionModel(),
            previousZones: [:],
            nookBundleID: nook
        )
        #expect(result == nil)
    }

    @Test func firstPassBaselinesZonesWithoutAdopting() {
        let result = BarAdoption.reconcile(
            items: [(id: chevron, minX: 1000), (id: velja, minX: 1100)],
            model: SectionModel(),
            previousZones: [:],
            nookBundleID: nook
        )
        #expect(result?.changed == false)
        #expect(result?.zones[velja.rawValue] == .visible)
        #expect(result?.model.assignments.isEmpty == true)
    }

    @Test func zoneChangeAdoptsIntoHidden() {
        var model = SectionModel()
        model.assignments[anchor.sectionKey] = .hidden
        let result = BarAdoption.reconcile(
            items: [
                (id: chevron, minX: 1000),
                (id: anchor, minX: 400),
                (id: velja, minX: 500),
            ],
            model: model,
            previousZones: [velja.rawValue: .visible, anchor.rawValue: .hidden],
            nookBundleID: nook
        )
        #expect(result?.changed == true)
        #expect(result?.model.assignments[velja.sectionKey] == .hidden)
        #expect(result?.zones[velja.rawValue] == .hidden)
    }

    @Test func zoneChangeAdoptsBackToVisible() {
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        let result = BarAdoption.reconcile(
            items: [(id: chevron, minX: 1000), (id: velja, minX: 1200)],
            model: model,
            previousZones: [velja.rawValue: .hidden],
            nookBundleID: nook
        )
        #expect(result?.changed == true)
        #expect(result?.model.assignments[velja.sectionKey] == nil)
    }

    @Test func ambiguousZoneConservesModelAndDoesNotPersist() {
        // No measurable hidden/always-hidden cluster besides the item itself
        // → ambiguous; the model's word stands and the guess is not tracked.
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        let result = BarAdoption.reconcile(
            items: [(id: chevron, minX: 1000), (id: velja, minX: 300)],
            model: model,
            previousZones: [velja.rawValue: .visible],
            nookBundleID: nook
        )
        #expect(result?.changed == false)
        #expect(result?.zones[velja.rawValue] == .visible)
        #expect(result?.model.assignments[velja.sectionKey] == .hidden)
    }

    @Test func liveOrderFoldsBackIntoExplicitOrder() {
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        model.assignments[figma.sectionKey] = .hidden
        model.order[.hidden] = [velja.sectionKey, figma.sectionKey]
        let result = BarAdoption.reconcile(
            items: [
                (id: chevron, minX: 1000),
                (id: velja, minX: 500),
                (id: figma, minX: 400),
            ],
            model: model,
            previousZones: [velja.rawValue: .hidden, figma.rawValue: .hidden],
            nookBundleID: nook
        )
        #expect(result?.changed == true)
        #expect(result?.model.order[.hidden] == [figma.sectionKey, velja.sectionKey])
        #expect(result?.log.contains("adopt: hidden order reconciled from bar") == true)
    }

    @Test func sectionChangedEntryDropsOutOfOrder() {
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        model.assignments[figma.sectionKey] = .alwaysHidden
        model.order[.hidden] = [velja.sectionKey, figma.sectionKey]
        let result = BarAdoption.reconcile(
            items: [(id: chevron, minX: 1000)],
            model: model,
            previousZones: [velja.rawValue: .hidden],
            nookBundleID: nook
        )
        #expect(result?.changed == true)
        #expect(result?.model.order[.hidden] == [velja.sectionKey])
    }

    @Test func liveNewcomerInsertsByX() {
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        model.assignments[figma.sectionKey] = .hidden
        model.order[.hidden] = [velja.sectionKey]
        let result = BarAdoption.reconcile(
            items: [
                (id: chevron, minX: 1000),
                (id: velja, minX: 500),
                (id: figma, minX: 400),
            ],
            model: model,
            previousZones: [velja.rawValue: .hidden, figma.rawValue: .hidden],
            nookBundleID: nook
        )
        #expect(result?.changed == true)
        #expect(result?.model.order[.hidden] == [figma.sectionKey, velja.sectionKey])
    }
}
