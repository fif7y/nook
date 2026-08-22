// FlowLayout.swift
// Wrapping row layout for the editor strips; `trailing` right-anchors each
// row like the real menubar. Row packing is a pure static so it's testable
// without SwiftUI.

import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var trailing: Bool = false

    /// Pure row packing over measured sizes: greedy fill, wrap when the next
    /// item would overflow — but never wrap the first item of a row.
    static func computeRows(
        sizes: [CGSize], width: CGFloat, spacing: CGFloat
    ) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            if x + size.width > width, x > 0 {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((index, size))
            x += size.width + spacing
        }
        return rows
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [[(index: Int, size: CGSize)]] {
        Self.computeRows(
            sizes: subviews.map { $0.sizeThatFits(.unspecified) },
            width: width,
            spacing: spacing
        )
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var height: CGFloat = 0
        for (rowIndex, row) in rows(width: width, subviews: subviews).enumerated() {
            if rowIndex > 0 { height += spacing }
            height += row.map(\.size.height).max() ?? 0
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            let rowWidth = row.map(\.size.width).reduce(0, +)
                + spacing * CGFloat(max(row.count - 1, 0))
            var x = trailing ? max(bounds.maxX - rowWidth, bounds.minX) : bounds.minX
            let rowHeight = row.map(\.size.height).max() ?? 0
            for (index, size) in row {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}
