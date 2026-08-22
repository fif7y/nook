// PlacementGeometryTests.swift
// Locks the placement choreography constants: neighbor midpoint, ±14
// one-sided offsets, zone fallbacks (−20/−15/+25), corner floor 200 /
// trailing clamp maxX−60, and the chevron ±12 side constraint applied LAST.

import CoreGraphics
import Testing
import NookCore
@testable import Nook

@MainActor
struct PlacementGeometryTests {
    let maxX: CGFloat = 1728
    func rect(_ x: CGFloat, width: CGFloat = 30) -> CGRect {
        CGRect(x: x, y: 0, width: width, height: 24)
    }

    @Test func bothNeighborsAimAtTheMidpoint() {
        let x = PlacementGeometry.targetX(
            leftNeighbor: rect(400), rightNeighbor: rect(500),
            chevron: nil, section: .hidden, managedMinX: nil, screenMaxX: maxX
        )
        #expect(x == 465)
    }

    @Test func oneSidedNeighborsUsePlusMinusFourteen() {
        let left = PlacementGeometry.targetX(
            leftNeighbor: rect(400), rightNeighbor: nil,
            chevron: nil, section: .hidden, managedMinX: nil, screenMaxX: maxX
        )
        #expect(left == 444)
        let right = PlacementGeometry.targetX(
            leftNeighbor: nil, rightNeighbor: rect(500),
            chevron: nil, section: .hidden, managedMinX: nil, screenMaxX: maxX
        )
        #expect(right == 486)
    }

    @Test func zoneFallbacksAnchorOnChevronAndManagedEdge() {
        let chevron = rect(1000)
        #expect(PlacementGeometry.targetX(
            leftNeighbor: nil, rightNeighbor: nil, chevron: chevron,
            section: .alwaysHidden, managedMinX: 600, screenMaxX: maxX
        ) == 580)
        #expect(PlacementGeometry.targetX(
            leftNeighbor: nil, rightNeighbor: nil, chevron: chevron,
            section: .hidden, managedMinX: nil, screenMaxX: maxX
        ) == 985)
        #expect(PlacementGeometry.targetX(
            leftNeighbor: nil, rightNeighbor: nil, chevron: chevron,
            section: .visible, managedMinX: nil, screenMaxX: maxX
        ) == 1055)
    }

    @Test func nothingToAnchorAgainstIsNil() {
        #expect(PlacementGeometry.targetX(
            leftNeighbor: nil, rightNeighbor: nil, chevron: nil,
            section: .hidden, managedMinX: nil, screenMaxX: maxX
        ) == nil)
    }

    @Test func cornerFloorAndTrailingClampApply() {
        // Far-left midpoint gets floored to 200.
        #expect(PlacementGeometry.targetX(
            leftNeighbor: rect(40), rightNeighbor: rect(120),
            chevron: nil, section: .hidden, managedMinX: nil, screenMaxX: maxX
        ) == 200)
        // Far-right one-sided target clamps to maxX − 60.
        #expect(PlacementGeometry.targetX(
            leftNeighbor: rect(maxX - 40), rightNeighbor: nil,
            chevron: nil, section: .visible, managedMinX: nil, screenMaxX: maxX
        ) == maxX - 60)
    }

    @Test func chevronSideConstraintOutranksTheCornerFloor() {
        // A far-left chevron: the 200 floor would push a hidden-section
        // target right of it — the ±12 side clamp applied LAST wins.
        let chevron = rect(150)
        let x = PlacementGeometry.targetX(
            leftNeighbor: nil, rightNeighbor: nil, chevron: chevron,
            section: .hidden, managedMinX: nil, screenMaxX: maxX
        )
        #expect(x == 138)
    }

    @Test func systemClusterClampAppliesLast() {
        // Midpoint (1465) sits inside the protected trailing cluster —
        // clamp to just left of it (1450 − 12).
        let x = PlacementGeometry.targetX(
            leftNeighbor: rect(1400), rightNeighbor: rect(1500),
            chevron: nil, section: .hidden, managedMinX: nil,
            systemMinX: 1450, screenMaxX: maxX
        )
        #expect(x == 1438)
    }

    @Test func inSlotChecksOrderAgainstPresentNeighborsOnly() {
        #expect(PlacementGeometry.inSlot(x: 450, leftMidX: 400, rightMidX: 500))
        #expect(!PlacementGeometry.inSlot(x: 390, leftMidX: 400, rightMidX: 500))
        #expect(!PlacementGeometry.inSlot(x: 510, leftMidX: 400, rightMidX: 500))
        #expect(PlacementGeometry.inSlot(x: 510, leftMidX: 400, rightMidX: nil))
        #expect(PlacementGeometry.inSlot(x: 390, leftMidX: nil, rightMidX: nil))
    }

    @Test func rawRetryUsesMidpointWithCornerClamps() {
        #expect(PlacementGeometry.rawRetryX(left: rect(400), right: rect(500), screenMaxX: maxX)
            == 465)
        #expect(PlacementGeometry.rawRetryX(left: rect(40), right: rect(120), screenMaxX: maxX)
            == 200)
    }
}
