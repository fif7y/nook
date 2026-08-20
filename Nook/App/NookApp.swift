// NookApp.swift
// Agent app (LSUIElement): no dock icon; lives in the menubar. Settings and
// onboarding windows activate the app transiently.

import SwiftUI

@main
struct NookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(appDelegate.appState)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.stopBlocking()
    }

    /// Relaunching Nook (Finder/Spotlight) while it runs opens Settings —
    /// one of the iconless-mode entry points.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        appState.openSettings()
        return true
    }
}
