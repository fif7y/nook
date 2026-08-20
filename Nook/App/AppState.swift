// AppState.swift
// Root composition: owns the engine, the rehide state machine, settings, and
// the status item. All UI-facing state is @Observable.

import AppKit
import NookCore
import NookEngine
import SwiftUI

@Observable
final class AppState {
    let engine = EngineGoldenGate()
    var settings = SettingsStore.load()
    private(set) var snapshot: EngineSnapshot?
    private(set) var accessibilityGranted = AXIsProcessTrusted()
    private(set) var engineCanHide = true

    private var rehide = RehideStateMachine()
    private var rehideTimer: Timer?
    private var statusItem: NookStatusItem?
    private var bandMonitor: MenuBarBandMonitor?
    private var hotkey: HotkeyManager?
    private var eventTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func start() {
        rehide.policy = settings.rehidePolicy
        engineCanHide = engine.capabilities.canHide

        if !accessibilityGranted || !settings.onboardingCompleted {
            OnboardingController.shared.present(appState: self)
        }

        if settings.showStatusItem {
            statusItem = NookStatusItem(appState: self)
        }

        let bandMonitor = MenuBarBandMonitor(appState: self)
        bandMonitor.start()
        self.bandMonitor = bandMonitor

        let hotkey = HotkeyManager { [weak self] in
            self?.toggle(reason: .hotkey)
        }
        hotkey.register(settings.hotkey)
        self.hotkey = hotkey

        eventTask = Task { [weak self] in
            guard let events = self?.engine.events else { return }
            for await event in events {
                self?.handle(engineEvent: event)
            }
        }

        Task {
            await engine.start()
            await engine.setModel(settings.sectionModel)
            snapshot = await engine.snapshot()
            // Startup state: everything the model says is hidden, is hidden.
            dispatch(rehide.handle(.concealRequested))
        }
    }

    /// Synchronous best-effort teardown for app termination: dropping the
    /// assertion restores the user's menubar.
    func stopBlocking() {
        rehideTimer?.invalidate()
        eventTask?.cancel()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached { [engine] in
            await engine.stop()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    // MARK: - Intents (UI + monitors call these)

    func toggle(reason: RevealReason) {
        dispatch(rehide.handle(.toggleRequested([.hidden], reason)))
    }

    func reveal(_ sections: Set<NookCore.Section>, reason: RevealReason) {
        dispatch(rehide.handle(.revealRequested(sections, reason)))
    }

    func concealNow() {
        dispatch(rehide.handle(.concealRequested))
    }

    func rehideTriggered(_ trigger: RehideTrigger) {
        dispatch(rehide.handle(.trigger(trigger)))
    }

    func pointerReturnedToBand() {
        dispatch(rehide.handle(.pointerReturned))
    }

    var isRevealed: Bool {
        if case .revealed = rehide.state { return true }
        return false
    }

    func openSettings() {
        NSApp.activate()
        // SwiftUI Settings scene: standard selector opens/foregrounds it.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func refreshAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    /// Persist + apply a changed settings store.
    func settingsChanged() {
        settings.save()
        rehide.policy = settings.rehidePolicy
        if settings.showStatusItem, statusItem == nil {
            statusItem = NookStatusItem(appState: self)
        } else if !settings.showStatusItem {
            statusItem?.remove()
            statusItem = nil
        }
        hotkey?.register(settings.hotkey)
        Task { await engine.setModel(settings.sectionModel) }
    }

    // MARK: - Effects

    private func dispatch(_ effects: [RehideEffect]) {
        for effect in effects {
            switch effect {
            case .none:
                break
            case .reveal(let sections):
                Task {
                    await engine.reveal(sections)
                    snapshot = await engine.snapshot()
                    dispatch(rehide.handle(.transitionSettled))
                }
            case .conceal:
                Task {
                    await engine.conceal()
                    snapshot = await engine.snapshot()
                    dispatch(rehide.handle(.transitionSettled))
                }
            case .armTimer(let deadline):
                rehideTimer?.invalidate()
                rehideTimer = Timer.scheduledTimer(
                    withTimeInterval: max(0, deadline.timeIntervalSinceNow),
                    repeats: false
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.rehideTriggered(.delayExpired)
                    }
                }
            case .cancelTimer:
                rehideTimer?.invalidate()
                rehideTimer = nil
            }
        }
    }

    private func handle(engineEvent: EngineEvent) {
        switch engineEvent {
        case .itemsChanged, .externalOrderChange:
            Task { snapshot = await engine.snapshot() }
        case .assertionTornDown:
            // Recovery = schedule a converge through the normal path.
            dispatch(rehide.handle(.concealRequested))
        case .availabilityChanged(let available):
            engineCanHide = available
        case .convergeFailed:
            // Surfaced in Settings as a banner; never silently retried in a loop.
            break
        }
    }
}
