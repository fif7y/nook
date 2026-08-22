// ItemEnumerator.swift
// AX snapshot of MenuBarAgent's item tree. Verified structure (M1 findings):
// AXApplication → AXWindow (one per display) → `?`-role groups, one per item.
// Third-party groups nest the owning app's AXApplication node; system items are
// AXMenuBarItem leaves with a com.apple.menuextra.* identifier.

import AppKit
import ApplicationServices
import Foundation
import NookCore

public struct RawItem: Equatable, Sendable {
    public let id: ItemID
    public let frame: CGRect
    public let appName: String?
}

/// Runs off the main actor: AX calls into busy apps can block, so snapshots are
/// taken on a background executor with short messaging timeouts.
public actor ItemEnumerator {
    public init() {}
    static let agentBundleID = NookBundle.agentID

    private var agentElement: AXUIElement?
    private var agentPID: pid_t = 0

    /// Correlates each observed item group to a stable agent tag. Tags come
    /// from the positions plist domain (`status:<bundle>::<title>`); we build
    /// the same shape from the AX tree so both sources agree.
    public func snapshotItems() -> [RawItem] {
        guard let agent = resolveAgent() else { return [] }
        guard let windows = copyAttribute(agent, kAXChildrenAttribute) as? [AXUIElement] else {
            return []
        }
        var byID: [ItemID: RawItem] = [:]
        var order: [ItemID] = []
        for window in windows {
            guard role(of: window) == "AXWindow" else { continue }
            guard let groups = copyAttribute(window, kAXChildrenAttribute) as? [AXUIElement] else {
                continue
            }
            for group in groups {
                guard let item = describeGroup(group) else { continue }
                if let existing = byID[item.id] {
                    // The same item appears once per display. Prefer the
                    // main-display occurrence (y ≈ 0 in CG top-left coords) so
                    // every frame lives in one coordinate space — boundary
                    // comparisons break across mixed display spaces.
                    if !isMainDisplayFrame(existing.frame), isMainDisplayFrame(item.frame) {
                        byID[item.id] = item
                    }
                } else {
                    byID[item.id] = item
                    order.append(item.id)
                }
            }
        }
        return order.compactMap { byID[$0] }
    }

    private func isMainDisplayFrame(_ frame: CGRect) -> Bool {
        MenuBarGeometry.isInBand(frame)
    }

    // MARK: - Internals

    private func resolveAgent() -> AXUIElement? {
        if let cached = agentElement,
           NSRunningApplication(processIdentifier: agentPID)?.bundleIdentifier == Self.agentBundleID {
            return cached
        }
        guard let agent = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == Self.agentBundleID
        }) else { return nil }
        let element = AXUIElementCreateApplication(agent.processIdentifier)
        // A stuck app must never wedge a snapshot.
        AXUIElementSetMessagingTimeout(element, EngineTiming.axAgentTimeout)
        agentElement = element
        agentPID = agent.processIdentifier
        return element
    }

    private func describeGroup(_ group: AXUIElement) -> RawItem? {
        guard let frame = frame(of: group) else { return nil }
        for child in children(of: group) {
            switch role(of: child) {
            case "AXApplication":
                // Third-party item: owning app nested right in the tree.
                let appName = copyAttribute(child, kAXTitleAttribute) as? String
                var appPID: pid_t = 0
                AXUIElementGetPid(child, &appPID)
                let bundleID = NSRunningApplication(processIdentifier: appPID)?.bundleIdentifier
                guard let bundleID else { return nil }
                let title = statusItemTitle(in: child) ?? "Item-0"
                return RawItem(
                    id: .status(bundle: bundleID, title: title),
                    frame: frame,
                    appName: appName
                )
            case "AXGroup":
                // System item: AXGroup wrapping an AXMenuBarItem.
                for leaf in children(of: child) where role(of: leaf) == "AXMenuBarItem" {
                    guard let identifier = copyAttribute(leaf, kAXIdentifierAttribute) as? String else {
                        continue
                    }
                    return RawItem(
                        id: .status(bundle: Self.agentBundleID, title: identifier),
                        frame: frame,
                        appName: nil
                    )
                }
            case "AXButton":
                // Plain NSStatusItem buttons (Nook's own chevron/separators,
                // Thaw's dividers) sit in the tree as bare AXButtons — no
                // nested AXApplication. Attribute by the button's owning pid.
                var pid: pid_t = 0
                AXUIElementGetPid(child, &pid)
                guard
                    pid > 0,
                    let app = NSRunningApplication(processIdentifier: pid),
                    let bundleID = app.bundleIdentifier
                else { continue }
                let candidates = [
                    copyAttribute(child, kAXTitleAttribute) as? String,
                    copyAttribute(child, kAXIdentifierAttribute) as? String,
                    copyAttribute(child, kAXDescriptionAttribute) as? String,
                ]
                let title = candidates.compactMap { $0?.isEmpty == false ? $0 : nil }.first ?? "Item-0"
                return RawItem(
                    id: .status(bundle: bundleID, title: title),
                    frame: frame,
                    appName: app.localizedName
                )
            default:
                continue
            }
        }
        return nil
    }

    /// Best-effort title of the app's status item button (used in the agent
    /// tag). An app node exposes both its MAIN menu bar (wide: Apple, File,
    /// Edit…) and its status-extras bar (narrow) — pick the narrowest bar so
    /// we never read "Apple" off the main menu. Falls back to Item-0.
    private func statusItemTitle(in appNode: AXUIElement) -> String? {
        let menuBars = children(of: appNode).filter { role(of: $0) == "AXMenuBar" }
        let extrasBar = menuBars.min { lhs, rhs in
            (frame(of: lhs)?.width ?? .greatestFiniteMagnitude)
                < (frame(of: rhs)?.width ?? .greatestFiniteMagnitude)
        }
        guard let extrasBar, let width = frame(of: extrasBar)?.width, width < 500 else {
            return nil
        }
        for item in children(of: extrasBar) {
            if let title = copyAttribute(item, kAXTitleAttribute) as? String, !title.isEmpty {
                return title
            }
        }
        return nil
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private func role(of element: AXUIElement) -> String {
        copyAttribute(element, kAXRoleAttribute) as? String ?? ""
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let value = copyAttribute(element, "AXFrame"),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }
}
