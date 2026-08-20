// SettingsWindowController.swift
// Nook owns its settings window directly — the SwiftUI Settings-scene selector
// (`showSettingsWindow:`) is unreliable from an LSUIElement status-item
// context, and M4's designed settings wants full window control anyway.

import AppKit
import SwiftUI

final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private weak var appState: AppState?

    func show(appState: AppState) {
        self.appState = appState
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            appState.settingsWindowVisible = true
            return
        }
        let hosting = NSHostingController(
            rootView: SettingsView().environment(appState)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Nook Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 520))
        window.center()
        window.delegate = self
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        appState.settingsWindowVisible = true
    }

    func windowWillClose(_ notification: Notification) {
        appState?.settingsWindowVisible = false
    }

    /// Re-front the window after a synthetic menubar drag — the drag's
    /// mouse-down lands outside Nook, so macOS deactivates us mid-edit.
    func refocus() {
        guard let window, window.isVisible else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
