// DisplayUUID.swift
// Stable per-display identity — the key for behavior overrides. NSScreenNumber
// changes across reconnects; the CG display UUID doesn't.

import AppKit

extension NSScreen {
    var displayUUIDString: String? {
        guard
            let number = deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber,
            let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// The screen currently under the pointer.
    static var underPointer: NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
    }
}
