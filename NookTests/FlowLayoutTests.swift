// FlowLayoutTests.swift
// The editor strip's row packing: greedy fill, wrap on overflow, and the
// first-item-of-a-row never wraps (even when wider than the row).

import CoreGraphics
import Testing
@testable import Nook

@MainActor
struct FlowLayoutTests {
    func sizes(_ widths: [CGFloat]) -> [CGSize] {
        widths.map { CGSize(width: $0, height: 24) }
    }

    @Test func itemsThatFitStayOnOneRow() {
        let rows = FlowLayout.computeRows(sizes: sizes([100, 100, 100]), width: 400, spacing: 6)
        #expect(rows.count == 1)
        #expect(rows[0].map(\.index) == [0, 1, 2])
    }

    @Test func overflowWrapsToANewRow() {
        let rows = FlowLayout.computeRows(sizes: sizes([200, 200, 200]), width: 450, spacing: 6)
        #expect(rows.map { $0.map(\.index) } == [[0, 1], [2]])
    }

    @Test func oversizedFirstItemNeverWraps() {
        let rows = FlowLayout.computeRows(sizes: sizes([500, 100]), width: 400, spacing: 6)
        #expect(rows.map { $0.map(\.index) } == [[0], [1]])
    }

    @Test func spacingCountsTowardOverflow() {
        // Two 200pt items fit a 400pt row only without spacing.
        let rows = FlowLayout.computeRows(sizes: sizes([200, 200]), width: 400, spacing: 6)
        #expect(rows.map { $0.map(\.index) } == [[0], [1]])
    }
}
