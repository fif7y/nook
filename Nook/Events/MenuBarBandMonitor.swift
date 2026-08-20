// MenuBarBandMonitor.swift
// Watches the menubar band on every display: hover dwell + empty-area clicks
// reveal; leaving the band / clicking elsewhere feeds the rehide machine.
// Also implements per-display behavior: the display the pointer is on wins.

import AppKit
import NookCore

final class MenuBarBandMonitor {
    private weak var appState: AppState?
    private var mouseMonitor: Any?
    private var clickMonitor: Any?
    private var hoverTimer: Timer?
    private var pointerInBand = false
    private var lastDisplayUUID: String?

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        // Passive global monitors: enough for hover + click detection, no
        // event swallowing (empty-area clicks fall through harmlessly).
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.pointerMoved()
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.clicked(event)
        }
    }

    func stop() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        mouseMonitor = nil
        clickMonitor = nil
        hoverTimer?.invalidate()
    }

    // MARK: - Pointer

    private func pointerMoved() {
        guard let appState else { return }
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
        let inBand = screen.map { isInMenuBarBand(location, of: $0) } ?? false
        let displayUUID = screen.flatMap(displayUUIDString)

        // Per-display behavior: crossing onto an "always show all" display
        // reveals; crossing back to a "collapse" display re-conceals.
        if displayUUID != lastDisplayUUID {
            lastDisplayUUID = displayUUID
            switch appState.settings.behavior(forDisplayUUID: displayUUID) {
            case .alwaysShowAll:
                appState.reveal([.hidden], reason: .hover)
            case .collapse:
                if appState.isRevealed {
                    appState.rehideTriggered(.displayBehaviorChanged)
                }
            }
        }

        guard appState.settings.behavior(forDisplayUUID: displayUUID) == .collapse else { return }

        if inBand, !pointerInBand {
            pointerInBand = true
            appState.pointerReturnedToBand()
            if appState.settings.revealTriggers.hoverEnabled, !appState.isRevealed {
                let delay = appState.settings.revealTriggers.hoverDelay
                hoverTimer?.invalidate()
                hoverTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
                    Task { @MainActor [weak self] in
                        guard let appState = self?.appState, self?.pointerInBand == true else { return }
                        appState.reveal([.hidden], reason: .hover)
                    }
                }
            }
        } else if !inBand, pointerInBand {
            pointerInBand = false
            hoverTimer?.invalidate()
            // Leaving the band arms the countdown (never an instant conceal),
            // and is the moment a finished ⌘-drag gets adopted into sections.
            appState.pointerLeftBand()
            appState.adoptSectionsFromBar()
        }
    }

    /// True while rehide should hold off: pointer in the band, over a
    /// menubar-anchored menu/popover, or interacting with Nook's own windows.
    func shouldDeferRehide() -> Bool {
        if pointerInBand { return true }
        if NSApp.isActive { return true }  // user is in Nook settings/onboarding
        return pointerIsOverElevatedWindow()
    }

    /// Deliberately narrow: only visible, menu/popover-sized windows at
    /// elevated levels count. `layer > 0` alone matches the invisible
    /// always-on-top helper windows half the utilities on a Mac keep around
    /// (PopClip, Unclutter, Raycast…) — that overreach made rehide never fire.
    private func pointerIsOverElevatedWindow() -> Bool {
        let location = NSEvent.mouseLocation
        guard
            let primary = NSScreen.screens.first,
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]]
        else { return false }
        // CG window bounds are top-left-origin global coordinates.
        let cgPoint = CGPoint(x: location.x, y: primary.frame.maxY - location.y)
        for window in windows {
            guard
                let layer = window[kCGWindowLayer as String] as? Int,
                // Status-item popovers and menus live in this level range;
                // floating utility panels (level 3) and the Dock (20) don't count.
                layer >= 24, layer <= 102,
                let alpha = window[kCGWindowAlpha as String] as? CGFloat, alpha > 0.05,
                let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                let x = bounds["X"], let y = bounds["Y"],
                let width = bounds["Width"], let height = bounds["Height"],
                // Menu/popover-sized, not screen-covering overlays.
                width < 900, height < 1200, width > 4, height > 4
            else { continue }
            if CGRect(x: x, y: y, width: width, height: height).contains(cgPoint) {
                return true
            }
        }
        return false
    }

    private func clicked(_ event: NSEvent) {
        guard let appState else { return }
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
        let inBand = screen.map { isInMenuBarBand(location, of: $0) } ?? false

        if inBand {
            guard appState.settings.revealTriggers.clickEnabled else { return }
            guard isEmptyMenuBarArea(location) else { return }
            if event.clickCount >= 2, appState.settings.revealTriggers.doubleClickForAlwaysHidden {
                appState.reveal([.hidden, .alwaysHidden], reason: .doubleClick)
            } else {
                appState.toggle(reason: .click)
            }
        } else if appState.isRevealed {
            // A click inside a status-item menu/popover is part of using the
            // revealed items — only clicks on ordinary content count as
            // "elsewhere".
            if !pointerIsOverElevatedWindow() {
                appState.rehideTriggered(.clickedElsewhere)
            }
        }
    }

    // MARK: - Geometry

    private func isInMenuBarBand(_ point: NSPoint, of screen: NSScreen) -> Bool {
        let bandHeight = screen.frame.maxY - screen.visibleFrame.maxY
        guard bandHeight > 0 else { return false }
        let band = NSRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - bandHeight,
            width: screen.frame.width,
            height: bandHeight
        )
        return NSMouseInRect(point, band, false)
    }

    /// Empty = not over any status item (from the engine snapshot) and right
    /// of the frontmost app's menus (approximated by the leftmost known item).
    private func isEmptyMenuBarArea(_ point: NSPoint) -> Bool {
        guard let snapshot = appState?.snapshot else { return false }
        let itemFrames = snapshot.items.compactMap(\.frame)
        guard let leftmost = itemFrames.map(\.minX).min() else { return false }
        // AX frames are top-left origin; NSEvent.mouseLocation is bottom-left.
        // In the band we only need X to decide emptiness.
        let x = point.x
        for frame in itemFrames where x >= frame.minX && x <= frame.maxX {
            return false
        }
        // Left of every status item = app-menu territory; not "empty".
        return x < leftmost ? false : true
    }

    private func displayUUIDString(_ screen: NSScreen) -> String? {
        guard
            let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber,
            let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
