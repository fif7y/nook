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
            if appState.isRevealed {
                appState.rehideTriggered(.pointerLeftBand)
            }
        }
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
            appState.rehideTriggered(.clickedElsewhere)
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
