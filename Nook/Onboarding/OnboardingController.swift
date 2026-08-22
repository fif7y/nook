// OnboardingController.swift
// Presents the onboarding window on first launch / missing permissions.
// The full cinematic flow is M6; this controller owns the window either way.

import AppKit
import SwiftUI

final class OnboardingController {
    static let shared = OnboardingController()
    private var window: NSWindow?

    func present(appState: AppState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let view = OnboardingFlow(
            appState: appState,
            onFinished: { [weak self] in self?.dismiss() }
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .fullSizeContentView, .closable]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0.055, green: 0.05, blue: 0.045, alpha: 1)
        window.setContentSize(NSSize(width: 720, height: 540))
        window.center()
        window.isReleasedWhenClosed = false
        // Onboarding must not get lost behind other apps' windows — an
        // LSUIElement app has no dock icon to recover it from.
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        // Floating again once the user clicks back — pairs with
        // lowerForSystemPrompt(), which must let system dialogs in front.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { window.level = .floating }
        }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private var keyObserver: NSObjectProtocol?

    /// The system permission dialog (tccd) comes up at normal window level —
    /// a floating onboarding buries it. Drop to normal before triggering any
    /// system prompt; the key observer restores floating on the next click.
    func lowerForSystemPrompt() {
        window?.level = .normal
    }

    func dismiss() {
        window?.close()
        window = nil
    }
}
