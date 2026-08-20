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
        let view = OnboardingView(
            appState: appState,
            onFinished: { [weak self] in self?.dismiss() }
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .fullSizeContentView, .closable]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 640, height: 480))
        window.center()
        window.isReleasedWhenClosed = false
        // Onboarding must not get lost behind other apps' windows — an
        // LSUIElement app has no dock icon to recover it from.
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func dismiss() {
        window?.close()
        window = nil
    }
}

/// M6 replaces this with the designed multi-step flow. Functionally complete:
/// explains Nook, requests Accessibility, completes onboarding.
struct OnboardingView: View {
    let appState: AppState
    let onFinished: () -> Void
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "menubar.arrow.up.rectangle")
                .font(.system(size: 56, weight: .light))
            Text("Welcome to Nook")
                .font(.largeTitle.weight(.semibold))
            Text("Nook tidies your menu bar: hidden items stay a hover away,\nand the ones you never need stay out of sight.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            if appState.accessibilityGranted {
                Button("Get Started") {
                    appState.settings.onboardingCompleted = true
                    appState.settingsChanged()
                    onFinished()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            } else {
                VStack(spacing: 12) {
                    Text("Nook needs Accessibility access to see and arrange your menu bar items.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Grant Accessibility Access") {
                        requestAccessibility()
                    }
                    .controlSize(.large)
                }
            }
            Spacer().frame(height: 24)
        }
        .padding(32)
        .onAppear {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in appState.refreshAccessibility() }
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
        }
    }

    /// First click: the native AX prompt (its own "Open System Settings"
    /// button is the reliable path). The prompt only shows once per app, so
    /// subsequent clicks deep-link to the Accessibility pane directly.
    private func requestAccessibility() {
        NSApp.activate()
        // Literal instead of kAXTrustedCheckOptionPrompt: the global CFString
        // var isn't concurrency-safe to touch under strict isolation.
        let promptKey = "AXTrustedCheckOptionPrompt"
        let alreadyPrompted = UserDefaults.standard.bool(forKey: "nook.axPromptShown")
        if !alreadyPrompted {
            UserDefaults.standard.set(true, forKey: "nook.axPromptShown")
            AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        } else {
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )!
            NSWorkspace.shared.open(url)
        }
    }
}
