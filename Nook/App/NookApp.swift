// NookApp.swift
// Agent app (LSUIElement): no dock icon; lives in the menubar. Settings and
// onboarding windows activate the app transiently.

import SwiftUI

@main
struct NookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Placeholder scene: the App protocol needs one, but Nook presents its
        // real windows (settings, onboarding) through its own controllers.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        appState.beginTermination()
        return .terminateLater
    }

    /// Relaunching Nook (Finder/Spotlight) while it runs opens Settings —
    /// one of the iconless-mode entry points.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        appState.openSettings()
        return true
    }
}
