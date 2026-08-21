// MenuBarBandMonitor.swift
// Watches the menubar band on every display: hover dwell + empty-area clicks
// reveal; leaving the band / clicking elsewhere feeds the rehide machine.
// Also implements per-display behavior: the display the pointer is on wins.

import AppKit
import NookCore
import NookEngine

final class MenuBarBandMonitor {
    private weak var appState: AppState?
    private var mouseMonitor: Any?
    private var clickMonitor: Any?
    private var dragMonitor: Any?
    private var hoverTimer: Timer?
    private var pointerInBand = false
    private var cmdDragActive = false
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
        // ⌘-drag tracking: rehide must never fire mid-drag, and adoption runs
        // the moment the drag ends — before the next conceal can act on a
        // stale model (which hid everything except the freshly dragged item).
        dragMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.dragEvent(event)
        }
    }

    private func dragEvent(_ event: NSEvent) {
        guard let appState else { return }
        switch event.type {
        case .leftMouseDragged:
            guard event.modifierFlags.contains(.command) else { return }
            let location = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
            guard let screen, isInMenuBarBand(location, of: screen) else { return }
            if !cmdDragActive {
                cmdDragActive = true
                appState.pointerReturnedToBand()  // cancels any rehide countdown
                NookLog.log("band: ⌘-drag started")
            }
        case .leftMouseUp:
            guard cmdDragActive else { return }
            cmdDragActive = false
            NookLog.log("band: ⌘-drag ended → adopting")
            // Give MenuBarAgent a beat to finalize the new position, then
            // adopt before rehide can run a stale conceal.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let appState = self?.appState else { return }
                appState.adoptSectionsFromBar()
                if appState.isRevealed {
                    appState.pointerLeftBand()  // re-arm the countdown
                }
            }
        default:
            break
        }
    }

    func stop() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        mouseMonitor = nil
        clickMonitor = nil
        dragMonitor = nil
        hoverTimer?.invalidate()
    }

    // MARK: - Pointer

    private func pointerMoved() {
        guard let appState else { return }
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
        let inBand = screen.map { isInMenuBarBand(location, of: $0) } ?? false
        let displayUUID = screen?.displayUUIDString

        // Per-display behavior: crossing onto an "always show all" display
        // reveals; crossing back to a "collapse" display arms the countdown.
        // (An instant conceal here flashed the bar open-shut when the pointer
        // crossed displays right after a hover reveal — rehide, don't snap.)
        if displayUUID != lastDisplayUUID {
            // First sighting (nil at launch) is a baseline, not a crossing —
            // treating it as one concealed the bar on the first mouse move
            // after a reveal.
            let crossed = lastDisplayUUID != nil
            lastDisplayUUID = displayUUID
            if crossed {
                switch appState.settings.behavior(forDisplayUUID: displayUUID) {
                case .alwaysShowAll:
                    // Not .hover: a display-policy reveal must not inherit the
                    // hover fast-rehide path, and the rehide timer defers
                    // while the pointer stays on this display.
                    appState.reveal([.hidden], reason: .displayPolicy)
                case .collapse:
                    if appState.isRevealed {
                        appState.pointerLeftBand()
                    }
                }
            }
        }

        guard appState.settings.behavior(forDisplayUUID: displayUUID) == .collapse else { return }

        if inBand, !pointerInBand {
            pointerInBand = true
            appState.pointerReturnedToBand()
            if appState.settings.revealTriggers.hoverEnabled, !appState.isRevealed {
                // Floor: below ~150ms every swipe-through of the band reads as
                // a hover and the bar flaps open on the way to a hot corner.
                let delay = max(appState.settings.revealTriggers.hoverDelay, 0.15)
                hoverTimer?.invalidate()
                hoverTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
                    Task { @MainActor [weak self] in
                        guard let self, let appState = self.appState, self.pointerInBand else { return }
                        // Re-verify against the LIVE pointer, not just the
                        // tracked flag — the flag lags by one event-delivery
                        // latency, which is exactly a fast swipe-through. A
                        // graze must not open the bar.
                        let location = NSEvent.mouseLocation
                        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
                        guard let screen, self.isInMenuBarBand(location, of: screen) else { return }
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

    /// Pointer state for the settle catch-up: a reveal that outlives its hover
    /// re-arms on the short clock.
    var pointerCurrentlyInBand: Bool { pointerInBand }

    private func clicked(_ event: NSEvent) {
        guard let appState else { return }
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
        let inBand = screen.map { isInMenuBarBand(location, of: $0) } ?? false

        if inBand {
            guard isEmptyMenuBarArea(location, on: screen) else { return }
            if event.type == .rightMouseDown {
                // Right-click on empty bar: always-available settings entry.
                let menu = NookStatusItem.contextMenu(appState: appState)
                menu.popUp(positioning: nil, at: location, in: nil)
                return
            }
            guard appState.settings.revealTriggers.clickEnabled else { return }
            NookLog.log("band: empty-area click count=\(event.clickCount)")
            if event.clickCount >= 2 {
                // Second click of a double. With the feature off, ignore it —
                // acting again reads as an open-shut flash.
                if appState.settings.revealTriggers.doubleClickForAlwaysHidden {
                    appState.reveal([.hidden, .alwaysHidden], reason: .doubleClick)
                }
            } else {
                // Single click acts IMMEDIATELY — the old 300ms double-click
                // defer made every plain click feel dead. A double's second
                // click widens the reveal on top (revealRequested unions), so
                // no defer is needed to keep double-click working.
                appState.toggle(reason: .click)
            }
        } else if appState.isRevealed {
            // Clicks inside Nook's own UI or a status-item menu/popover are
            // part of using the revealed items — and while the settings window
            // is open nothing collapses, period. Clicks on an "always show"
            // display never collapse either: the display's policy wins.
            if !appState.settingsWindowVisible, !NSApp.isActive, !pointerIsOverElevatedWindow(),
               appState.settings.behavior(forDisplayUUID: screen?.displayUUIDString) == .collapse {
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

    /// Empty = the AX element under the pointer belongs to the menubar host
    /// but is not an item/menu. A systemwide hit-test works on every display
    /// (the snapshot's frames are main-display-only, which silently broke
    /// empty-click detection on external screens).
    private func isEmptyMenuBarArea(_ point: NSPoint, on screen: NSScreen?) -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        // Convert bottom-left mouse coords → top-left AX coords.
        let axPoint = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(axPoint.x), Float(axPoint.y), &element) == .success,
              let element else {
            // Nothing under the pointer at all — treat as empty bar.
            return true
        }
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let owner = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?"
        // Items, buttons, and app menus are NOT empty; the agent's bare
        // window/group backdrop is.
        let itemRoles: Set<String> = ["AXMenuBarItem", "AXButton", "AXMenuButton", "AXImage"]
        // The frontmost app's bare AXMenuBar element is the backdrop that
        // spans the whole bar — hitting it (not an AXMenuBarItem title) means
        // empty space. The agent's own window/group backdrop counts too.
        let empty = !itemRoles.contains(role)
            && (role == "AXMenuBar"
                || owner == ItemEnumeratorBundle.agent
                || role == "AXWindow" || role == "AXGroup")
        NookLog.log("band: hit-test role=\(role) owner=\(owner) → empty=\(empty)")
        return empty
    }

}
