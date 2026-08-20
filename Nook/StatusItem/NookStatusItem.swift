// NookStatusItem.swift
// Nook's own (optional) menubar icon. Left-click toggles the hidden section;
// right-click opens the menu. AppKit NSStatusItem — MenuBarExtra can't do
// right-click or imperative button control.

import AppKit
import NookCore
import NookEngine

final class NookStatusItem {
    private let item: NSStatusItem
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "Nook.StatusItem"
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "chevron.compact.left",
                accessibilityDescription: "Nook"
            )
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // Stable engine identity (chevron-boundary lookups key off this).
            button.setAccessibilityTitle("Nook.StatusItem")
        }
    }

    /// Call before releasing (deinit can't touch main-actor AppKit state under
    /// strict concurrency).
    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    func updateSymbol(revealed: Bool) {
        item.button?.image = NSImage(
            systemSymbolName: revealed ? "chevron.compact.right" : "chevron.compact.left",
            accessibilityDescription: "Nook"
        )
    }

    @objc private func clicked() {
        guard let appState else { return }
        // currentEvent is nil for synthetic AX presses (VoiceOver etc.) —
        // treat those as a plain left-click toggle instead of bailing.
        let event = NSApp.currentEvent
        NookLog.log("statusItem clicked: type=\(event?.type.rawValue ?? 0)")
        if event?.type == .rightMouseUp {
            item.menu = Self.contextMenu(appState: appState)
            item.button?.performClick(nil)
            item.menu = nil
        } else if event?.modifierFlags.contains(.option) == true {
            appState.reveal([.hidden, .alwaysHidden], reason: .statusItem)
        } else {
            appState.toggle(reason: .statusItem)
        }
    }

    static func contextMenu(appState: AppState) -> NSMenu {
        let menu = NSMenu()
        let toggle = NSMenuItem(
            title: appState.isRevealed ? "Hide Items" : "Show Hidden Items",
            action: #selector(AppMenuTarget.toggle), keyEquivalent: ""
        )
        let showAll = NSMenuItem(
            title: "Show Always-Hidden Too",
            action: #selector(AppMenuTarget.showAll), keyEquivalent: ""
        )
        let settings = NSMenuItem(
            title: "Nook Settings…",
            action: #selector(AppMenuTarget.openSettings), keyEquivalent: ","
        )
        let quit = NSMenuItem(
            title: "Quit Nook",
            action: #selector(AppMenuTarget.quit), keyEquivalent: "q"
        )
        let target = AppMenuTarget.shared
        target.appState = appState
        for menuItem in [toggle, showAll, settings, quit] {
            menuItem.target = target
        }
        menu.items = [toggle, showAll, .separator(), settings, .separator(), quit]
        return menu
    }
}

/// Shared menu target so context menus built from separators and the status
/// item reuse one implementation.
final class AppMenuTarget: NSObject {
    static let shared = AppMenuTarget()
    weak var appState: AppState?

    @objc func toggle() { appState?.toggle(reason: .statusItem) }
    @objc func showAll() { appState?.reveal([.hidden, .alwaysHidden], reason: .statusItem) }
    @objc func openSettings() { appState?.openSettings() }
    @objc func quit() { NSApp.terminate(nil) }
}
