// ItemImageCache.swift
// Icon resolution for the layout editor: the chooser shows the REAL thing.
// Without Screen Recording we can't capture live status-item pixels, so the
// next-truest artifact is the owning app's icon (and the system symbol for
// Apple items). SCK live capture upgrades this in a later milestone.

import AppKit
import NookCore

@MainActor
enum ItemImageCache {
    private static var appIcons: [String: NSImage] = [:]

    static func icon(for item: ItemID) -> NSImage? {
        if item.rawValue.hasSuffix("Nook.MediaControls") {
            return NSImage(systemSymbolName: "playpause.fill", accessibilityDescription: "Media Controls")
        }
        if let bundleID = item.bundleID {
            if bundleID == ItemEnumeratorBundle.agent {
                return systemSymbol(for: item)
            }
            if let cached = appIcons[bundleID] {
                return cached
            }
            let icon = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID).first?.icon
            if let icon {
                icon.size = NSSize(width: 20, height: 20)
                appIcons[bundleID] = icon
            }
            return icon
        }
        return nil
    }

    /// com.apple.menuextra.* → the SF Symbol the real item draws.
    private static func systemSymbol(for item: ItemID) -> NSImage? {
        let id = item.rawValue
        let symbol: String
        if id.contains("wifi") { symbol = "wifi" }
        else if id.contains("battery") { symbol = "battery.75percent" }
        else if id.contains("bluetooth") { symbol = "bluetooth" }
        else if id.contains("screen-mirroring") { symbol = "airplayvideo" }
        else if id.contains("clock") { symbol = "clock" }
        else if id.contains("audiovideo") { symbol = "video" }
        else if id.contains("controlcenter") { symbol = "switch.2" }
        else if id.contains("sound") { symbol = "speaker.wave.2" }
        else { symbol = "circle.dashed" }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }
}

enum ItemEnumeratorBundle {
    static let agent = "com.apple.MenuBarAgent"
}
