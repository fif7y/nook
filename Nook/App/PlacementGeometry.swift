// PlacementGeometry.swift
// Pure target math for synthetic ⌘-drag placement. Constants here are
// choreography tuned live against the agent (see PlacementController for the
// measurement/verification context) — locked by PlacementGeometryTests.

import CoreGraphics
import NookCore

enum PlacementGeometry {
    /// Target X for a drop: neighbor-midpoint when both sides are live,
    /// one-sided ±14pt offsets, or chevron-anchored zone fallbacks
    /// (−20/−15/+25) — then the hot-corner floor (200) / trailing clamp
    /// (maxX−60), and the chevron side constraint (±12) applied LAST: the
    /// corner floor once pushed a hidden-section target right of a far-left
    /// chevron, dropping the item into the wrong side. Nil when there is
    /// nothing to anchor against (no neighbors and no chevron).
    static func targetX(
        leftNeighbor: CGRect?,
        rightNeighbor: CGRect?,
        chevron: CGRect?,
        section: NookCore.Section,
        managedMinX: CGFloat?,
        systemMinX: CGFloat? = nil,
        screenMaxX: CGFloat
    ) -> CGFloat? {
        var targetX: CGFloat
        switch (leftNeighbor, rightNeighbor) {
        case (let left?, let right?) where left.maxX < right.minX:
            targetX = (left.maxX + right.minX) / 2
        case (let left?, _):
            targetX = left.maxX + 14
        case (_, let right?):
            targetX = right.minX - 14
        default:
            guard let chevron else { return nil }
            let anchor = managedMinX ?? chevron.minX
            switch section {
            case .alwaysHidden: targetX = anchor - 20
            case .hidden: targetX = chevron.minX - 15
            case .visible: targetX = chevron.maxX + 25
            }
        }
        // Never approach screen corners (hot corners: Mission Control) or
        // leave the trailing status area.
        targetX = min(max(targetX, 200), screenMaxX - 60)
        if let chevron {
            switch section {
            case .visible:
                targetX = max(targetX, chevron.maxX + 12)
            case .hidden, .alwaysHidden:
                targetX = min(targetX, chevron.minX - 12)
            }
        }
        // The trailing system cluster (Control Center, Clock, pinned
        // menuextras) is protected — even a real ⌘-drag can't drop right of
        // it. Model order can still place an item "before" a system member
        // (system items hide/show but never physically move), which computes
        // a target inside the cluster; the closest POSSIBLE slot is just
        // left of it. Verified live 2026-08-21: drops at 1492/1522 (inside
        // the cluster) bounced entirely.
        if let systemMinX {
            targetX = min(targetX, systemMinX - 12)
        }
        return targetX
    }

    /// Post-drag order check: the item must sit right of its left neighbor
    /// and left of its right one (mids pre-filtered to the item's band;
    /// a missing neighbor imposes no bound).
    static func inSlot(x: CGFloat, leftMidX: CGFloat?, rightMidX: CGFloat?) -> Bool {
        if let leftMidX, x < leftMidX { return false }
        if let rightMidX, x > rightMidX { return false }
        return true
    }

    /// Retry target from RAW (unlifted) neighbor frames: the midpoint of the
    /// neighbors' CENTERS, valid even when packed icons leave no edge gap —
    /// the drop only needs to land between the mids for the agent to slot
    /// between them. Same corner clamps.
    static func rawRetryX(left: CGRect, right: CGRect, screenMaxX: CGFloat) -> CGFloat {
        min(max((left.midX + right.midX) / 2, 200), screenMaxX - 60)
    }
}
