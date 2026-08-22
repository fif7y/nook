// OverflowChevron.swift
// The native overflow toggle («): a MenuBarAgent-owned AXButton, desc
// "Show Hidden Menu Bar Items" collapsed / "Hide Menu Bar Items" expanded.
// It never appears in the agent's AX hierarchy (children, windows, extras
// menu bar all lack it — verified 2026-08-22); only a position hit-test
// resolves it, and ONLY while Nook is frontmost — a regular app's
// full-width AXMenuBar backdrop shadows it from the hit-test otherwise.
// Expanding it materializes overflow-trapped items with real draggable
// frames (a plain synthetic drag then verifies first try), so the editor
// expands it on entry and restores it on exit; the conceal-settle rescue
// stays as the fallback for placements outside the editor.

import AppKit
import ApplicationServices
import NookCore
import NookEngine

enum OverflowChevron {
    /// Set when WE expanded it — editor exit only collapses in that case,
    /// never undoing an expansion the user made themselves.
    @MainActor private static var expandedByUs = false

    // AXUIElement is a thread-safe CF ref — safe to hop actors with.
    nonisolated private struct Toggle: @unchecked Sendable {
        let element: AXUIElement
        let frame: CGRect
        let expanded: Bool
    }

    /// Sweep the band from mid-screen (the « sits just right of the notch)
    /// looking for the agent-owned toggle. ~6pt steps cannot skip the
    /// ~17pt button.
    nonisolated private static func find() -> Toggle? {
        // Primary display by design: synthetic drags (the only mover) run on
        // the primary bar, so its « is the one to expand.
        guard let screen = NSScreen.screens.first else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var x = screen.frame.midX
        while x < screen.frame.maxX - 200 {
            defer { x += 6 }
            var el: AXUIElement?
            guard AXUIElementCopyElementAtPosition(systemWide, Float(x), 19, &el) == .success,
                  let el else { continue }
            var roleV: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleV)
            guard roleV as? String == "AXButton" else { continue }
            var descV: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descV)
            guard let desc = descV as? String, desc.contains("Menu Bar Items") else { continue }
            var pid: pid_t = 0
            AXUIElementGetPid(el, &pid)
            guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == NookBundle.agentID else { continue }
            var frame = CGRect.zero
            var posV: CFTypeRef?
            var sizeV: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posV) == .success,
               AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeV) == .success {
                var p = CGPoint.zero
                var s = CGSize.zero
                AXValueGetValue(posV as! AXValue, .cgPoint, &p)
                AXValueGetValue(sizeV as! AXValue, .cgSize, &s)
                frame = CGRect(origin: p, size: s)
            }
            return Toggle(element: el, frame: frame, expanded: desc.hasPrefix("Hide"))
        }
        return nil
    }

    /// AXPress first (cheap; refused today but may work on a future build),
    /// then a real HID click with the cursor warped straight back. Warp-free
    /// presses were falsified live 2026-08-22: AXPress on the button AND its
    /// parent wrapper both refused, and a postToPid click was delivered but
    /// ignored — the agent only honors real HID clicks. The band monitor
    /// hit-tests clicks and the « is an AXButton — never "empty area" — so
    /// the click cannot toggle a Nook reveal.
    nonisolated private static func pressVerified(_ toggle: Toggle) -> Bool {
        if AXUIElementPerformAction(toggle.element, kAXPressAction as CFString) == .success {
            NookLog.log("chevron«: AXPress ok")
            return true
        }
        guard toggle.frame != .zero else {
            NookLog.log("chevron«: AXPress refused and no frame — cannot press")
            return false
        }
        let point = CGPoint(x: toggle.frame.midX, y: toggle.frame.midY)
        guard
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                               mouseCursorPosition: point, mouseButton: .left),
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                             mouseCursorPosition: point, mouseButton: .left)
        else { return false }
        // The agent only honors real HID clicks (AXPress and postToPid both
        // verified ignored 2026-08-22), so the pointer must warp — but it
        // doesn't have to STAY there. Warp it straight back: ~80ms blip.
        let cursorBefore = CGEvent(source: nil)?.location
        down.post(tap: .cghidEventTap)
        usleep(60_000)
        up.post(tap: .cghidEventTap)
        usleep(20_000)
        if let cursorBefore {
            CGWarpMouseCursorPosition(cursorBefore)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        NookLog.log("chevron«: HID-clicked at x=\(point.x) (cursor restored)")
        return true
    }

    /// Lazily, from the placement path, when a drop hit a trapped item: the
    /// pointer is already committed to synthetic motion there, so the click
    /// folds into motion the user expects — never on editor entry (a warp
    /// mid-mouse-move ambushes the user). Only resolvable while Nook is
    /// frontmost (editor flows); background placements return false and
    /// fall back to the conceal-settle rescue.
    /// Returns true when the « is expanded afterwards (already or by us).
    nonisolated private enum ExpandOutcome: Sendable {
        case notFound, alreadyExpanded, pressed, pressFailed
    }

    @MainActor
    static func expandForPlacement() async -> Bool {
        let outcome = await Task.detached { () -> ExpandOutcome in
            guard let toggle = find() else { return .notFound }
            if toggle.expanded { return .alreadyExpanded }
            return pressVerified(toggle) ? .pressed : .pressFailed
        }.value
        switch outcome {
        case .notFound:
            NookLog.log("chevron«: not resolvable (no overflow, or Nook not frontmost)")
            return false
        case .alreadyExpanded:
            NookLog.log("chevron«: already expanded")
            return true
        case .pressed:
            expandedByUs = true
            NookLog.log("chevron«: expanded for placement")
            return true
        case .pressFailed:
            NookLog.log("chevron«: press FAILED")
            return false
        }
    }

    /// Editor exit: collapse only what we expanded. The exit conceal often
    /// de-crowds the bar first, removing the « entirely — that counts as
    /// collapsed.
    @MainActor
    static func restoreAfterEditing() {
        guard expandedByUs else { return }
        expandedByUs = false
        Task.detached {
            guard let toggle = find(), toggle.expanded else {
                NookLog.log("chevron«: restore — already collapsed/gone")
                return
            }
            _ = pressVerified(toggle)
            NookLog.log("chevron«: restored (collapsed)")
        }
    }
}
