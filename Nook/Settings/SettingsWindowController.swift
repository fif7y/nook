// SettingsWindowController.swift
// Nook owns its settings window directly — the SwiftUI Settings-scene selector
// (`showSettingsWindow:`) is unreliable from an LSUIElement status-item
// context, and M4's designed settings wants full window control anyway.

import AppKit
import SwiftUI

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(appState: AppState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
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
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
