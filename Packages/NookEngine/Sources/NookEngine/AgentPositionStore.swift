// AgentPositionStore.swift
// Ordering writes. M1 ground truth: MenuBarAgent re-interpolates values on its
// own, so written values are throwaway — what persists is relative order.
// Strategy: whole-order rewrite with wide gaps (no midpoint-collision drift),
// one write + one agent restart per explicit user action, coalesced upstream.

import AppKit
import Foundation
import NookCore

enum AgentPositionStore {
    static let domain = AgentPositions.domain
    static let key = AgentPositions.positionsKey
    /// Wide, collision-proof spacing between managed items.
    static let gap: Double = 100

    /// Rewrites positions so that `orderedTags` appear in the given left-to-
    /// right order. Unmanaged tags keep their existing values. Returns the
    /// written dictionary (for the watcher's self-write suppression).
    @discardableResult
    static func writeOrder(_ orderedTags: [String]) -> [String: Double] {
        var positions = AgentPositions.read()
        // Clock sits at 0 and grows rightward in "position" space; larger
        // values sit further left. Preserve that: assign decreasing positions
        // from a base left of the rightmost managed slot.
        var value = gap * Double(orderedTags.count)
        for tag in orderedTags {
            positions[tag] = value
            // Tag drift: the agent re-mints third-party tags (title timing at
            // agent boot — Figma's slot was once written to '::Item-0' while
            // the live item woke up as '::<UUID>' and kept a far-left ghost
            // slot). Give every known tag variant of the same bundle the same
            // value so whichever tag survives the restart lands on this slot.
            let id = ItemID(rawValue: tag)
            if id.sectionKey != id, let bundle = id.bundleID {
                let prefix = ItemID.statusTagPrefix(bundle: bundle)
                for key in positions.keys where key.hasPrefix(prefix) && key != tag {
                    positions[key] = value
                }
            }
            value -= gap
        }
        CFPreferencesSetValue(
            key as CFString,
            positions as CFDictionary,
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return positions
    }

    /// Applies pending position writes by restarting the agent. launchd
    /// relaunches it immediately; the bar blinks once. Only call from an
    /// explicit, user-initiated converge.
    static func restartAgent() {
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: NookBundle.agentID
        )
        for app in running {
            kill(app.processIdentifier, SIGKILL)
        }
    }
}
