// DisplayUUID.swift
// Stable per-display identity — the key for behavior overrides. NSScreenNumber
// changes across reconnects; the CG display UUID doesn't.

import AppKit

/// UUID lookup cache. `displayUUIDString` is on the mouse-move hot path
/// (every global pointer move consults the pointer display's behavior), and
/// the uncached lookup allocates two CF objects per call. Display IDs only
/// change on reconfiguration, so cache and invalidate on the notification.
@MainActor
private enum DisplayUUIDCache {
    static var uuids: [UInt32: String] = [:]
    private static var observer: NSObjectProtocol?

    static func uuid(for displayID: UInt32) -> String? {
        installObserverIfNeeded()
        if let cached = uuids[displayID] { return cached }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
        else { return nil }
        let string = CFUUIDCreateString(nil, uuid) as String
        uuids[displayID] = string
        return string
    }

    private static func installObserverIfNeeded() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { uuids.removeAll() }
        }
    }
}

extension NSScreen {
    @MainActor
    var displayUUIDString: String? {
        guard
            let number = deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
        else { return nil }
        return DisplayUUIDCache.uuid(for: number.uint32Value)
    }

    /// The screen currently under the pointer.
    static var underPointer: NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
    }
}
