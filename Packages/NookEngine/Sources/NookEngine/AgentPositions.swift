// AgentPositions.swift
// Read/write access to MenuBarAgent's item ordering. On macOS 27 the menu bar
// host persists trailing-item order in TrailingItemPreferredPositions inside
// com.apple.MenuBarAgent (any-host). Writing well-spaced values + restarting
// the agent applies a new order; watching the plist adopts native ⌘-drags.

import Foundation

public enum AgentPositions {
    public static let domain = "com.apple.MenuBarAgent"
    public static let positionsKey = "TrailingItemPreferredPositions"

    /// Current item → position map, as the agent last persisted it.
    /// Keys are item tags like "com.apple.MenuBarAgent:com.apple.menuextra.wifi"
    /// or "<bundle-id>:Item-0"; values are ordering positions.
    public static func read() -> [String: Double] {
        guard
            let raw = CFPreferencesCopyValue(
                positionsKey as CFString,
                domain as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            ) as? [String: Any]
        else { return [:] }
        return raw.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    /// Items sorted by their persisted position.
    public static func readOrdered() -> [(tag: String, position: Double)] {
        read().sorted { $0.value < $1.value }.map { ($0.key, $0.value) }
    }
}
