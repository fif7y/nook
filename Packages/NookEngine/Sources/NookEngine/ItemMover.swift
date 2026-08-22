// ItemMover.swift
// Physical repositioning WITHOUT restarting MenuBarAgent: synthesize the same
// ⌘-drag a human performs. macOS 27 handles coordinate-based drags natively
// (verified live on this machine) — the agent animates the move and persists
// the position itself. No rebuild, no blink, no relaunch.

import AppKit
import CoreGraphics
import Foundation

public enum ItemMover {
    /// Performs a ⌘-drag from one menubar point to another (top-left-origin
    /// global coordinates, i.e. the same space as AX frames). Saves and
    /// restores the user's cursor so the pointer doesn't visibly teleport.
    ///
    /// Runs OFF the main actor deliberately: when the dragged item is Nook's
    /// OWN, our process runs AppKit's drag tracking — posting from the main
    /// actor interleaved the tracking loop with this function's sleeps and
    /// every own-item drop reverted, while a real ⌘-drag on the same item
    /// worked (verified live 2026-08-21). Third-party items never cared
    /// (their owning app tracks the drag).
    public static func cmdDrag(from: CGPoint, to: CGPoint) async {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let originalPosition = CGEvent(source: nil)?.location

        func post(_ type: CGEventType, at point: CGPoint) {
            guard let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else { return }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }

        post(.leftMouseDown, at: from)
        // Hold briefly so the drag registers as a deliberate grab.
        try? await Task.sleep(for: .milliseconds(180))
        // Ease toward the target — single-jump drags are sometimes ignored,
        // and LONG drags need finer motion for the agent to track slot
        // crossings (a fixed-6-step 440pt drag = 74pt jumps bounced entirely,
        // verified live 2026-08-21).
        let distance = abs(to.x - from.x) + abs(to.y - from.y)
        let steps = min(24, max(6, Int(distance / 40)))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let x = from.x + (to.x - from.x) * t
            let y = from.y + (to.y - from.y) * t
            post(.leftMouseDragged, at: CGPoint(x: x, y: y))
            try? await Task.sleep(for: .milliseconds(30))
        }
        try? await Task.sleep(for: .milliseconds(120))
        post(.leftMouseUp, at: to)

        if let originalPosition {
            try? await Task.sleep(for: .milliseconds(60))
            CGWarpMouseCursorPosition(originalPosition)
        }
    }
}
