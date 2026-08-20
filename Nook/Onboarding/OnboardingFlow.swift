// OnboardingFlow.swift
// M6 — the designed onboarding. Four beats, one signature moment: a live
// miniature menubar that tidies itself, then hands the user the drag.
// Motion rules: springs only (no default easing), choreographed staggers,
// one warm accent. Type is the architecture: display SF at 46pt tight
// tracking against 13pt body.

import NookCore
import ServiceManagement
import SwiftUI

// MARK: - Palette

private enum Ink {
    /// Warm near-black, never pure black.
    static let base = Color(red: 0.055, green: 0.05, blue: 0.045)
    static let raised = Color(red: 0.10, green: 0.095, blue: 0.09)
    /// The nook amber — the one accent, used for the boundary and moments.
    static let amber = Color(red: 1.0, green: 0.62, blue: 0.28)
    static let text = Color(red: 0.96, green: 0.95, blue: 0.93)
    static let textDim = Color(red: 0.96, green: 0.95, blue: 0.93).opacity(0.55)
}

private let springSnappy = Animation.spring(response: 0.45, dampingFraction: 0.82)
private let springSoft = Animation.spring(response: 0.7, dampingFraction: 0.85)

// MARK: - Flow

struct OnboardingFlow: View {
    let appState: AppState
    let onFinished: () -> Void

    @State private var step = 0
    private let stepCount = 4

    var body: some View {
        ZStack {
            Ink.base.ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    switch step {
                    case 0: WelcomeStep()
                        .transition(stepTransition)
                    case 1: AccessStep(appState: appState)
                        .transition(stepTransition)
                    case 2: TryItStep()
                        .transition(stepTransition)
                    default: ReadyStep(appState: appState)
                        .transition(stepTransition)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                footer
            }
            .padding(36)
        }
        .frame(width: 720, height: 540)
        .preferredColorScheme(.dark)
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .offset(x: 60).combined(with: .opacity),
            removal: .offset(x: -60).combined(with: .opacity)
        )
    }

    private var canAdvance: Bool {
        step == 1 ? appState.accessibilityGranted : true
    }

    private var footer: some View {
        HStack(spacing: 0) {
            // Progress: thin amber line that grows — no dots row.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.text.opacity(0.08)).frame(height: 2)
                    Capsule().fill(Ink.amber)
                        .frame(width: geo.size.width * CGFloat(step + 1) / CGFloat(stepCount), height: 2)
                        .animation(springSoft, value: step)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(width: 120, height: 20)

            Spacer()

            if step > 0 {
                Button("Back") {
                    withAnimation(springSnappy) { step -= 1 }
                }
                .buttonStyle(GhostButtonStyle())
            }

            Button(step == stepCount - 1 ? "Start using Nook" : "Continue") {
                if step == stepCount - 1 {
                    appState.settings.onboardingCompleted = true
                    appState.settingsChanged()
                    onFinished()
                } else {
                    withAnimation(springSnappy) { step += 1 }
                }
            }
            .buttonStyle(AmberButtonStyle())
            .disabled(!canAdvance)
            .opacity(canAdvance ? 1 : 0.35)
            .animation(springSnappy, value: canAdvance)
            .padding(.leading, 14)
        }
        .frame(height: 44)
    }
}

// MARK: - Step 1 · Welcome (the signature moment)

private struct WelcomeStep: View {
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            DemoBar(mode: .loop)
                .frame(height: 44)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 14)

            Spacer().frame(height: 48)

            Text("Your menu bar,\ntucked away.")
                .font(.system(size: 46, weight: .semibold))
                .tracking(-1.2)
                .lineSpacing(2)
                .foregroundStyle(Ink.text)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 18)

            Spacer().frame(height: 16)

            Text("Nook keeps every icon a hover away — and the ones you never need, out of sight.")
                .font(.system(size: 13))
                .foregroundStyle(Ink.textDim)
                .frame(maxWidth: 380, alignment: .leading)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 18)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(springSoft.delay(0.15)) { appeared = true }
        }
    }
}

// MARK: - Step 2 · Access

private struct AccessStep: View {
    let appState: AppState
    @State private var appeared = false
    @State private var poll: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            Text("One permission.")
                .font(.system(size: 46, weight: .semibold))
                .tracking(-1.2)
                .foregroundStyle(Ink.text)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 18)

            Spacer().frame(height: 16)

            Text("Nook arranges your menu bar through macOS accessibility — that's how it sees the icons and moves them. Nothing is read from your screen, nothing leaves your Mac.")
                .font(.system(size: 13))
                .foregroundStyle(Ink.textDim)
                .frame(maxWidth: 420, alignment: .leading)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 18)

            Spacer().frame(height: 32)

            HStack(spacing: 12) {
                Circle()
                    .fill(appState.accessibilityGranted ? Ink.amber : Ink.text.opacity(0.15))
                    .frame(width: 8, height: 8)
                    .animation(springSnappy, value: appState.accessibilityGranted)
                if appState.accessibilityGranted {
                    Text("Access granted")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Ink.text)
                } else {
                    Button("Grant Accessibility Access") {
                        requestAccessibility()
                    }
                    .buttonStyle(AmberButtonStyle())
                }
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 18)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(springSoft.delay(0.1)) { appeared = true }
            poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in appState.refreshAccessibility() }
            }
        }
        .onDisappear { poll?.invalidate() }
    }

    private func requestAccessibility() {
        NSApp.activate()
        let alreadyPrompted = UserDefaults.standard.bool(forKey: "nook.axPromptShown")
        if !alreadyPrompted {
            UserDefaults.standard.set(true, forKey: "nook.axPromptShown")
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        } else {
            NSWorkspace.shared.open(URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )!)
        }
    }
}

// MARK: - Step 3 · Try it (the drag is the lesson)

private struct TryItStep: View {
    @State private var appeared = false
    @State private var tucked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            DemoBar(mode: .interactive(tucked: $tucked))
                .frame(height: 44)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 14)

            Spacer().frame(height: 48)

            Text(tucked ? "That's the whole trick." : "Drag the icon left\nof the chevron.")
                .font(.system(size: 46, weight: .semibold))
                .tracking(-1.2)
                .lineSpacing(2)
                .foregroundStyle(Ink.text)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 18)
                .animation(springSnappy, value: tucked)

            Spacer().frame(height: 16)

            Text(tucked
                 ? "Left of the chevron hides, right stays. In your real bar, hold ⌘ while dragging — or arrange everything in Nook's settings."
                 : "The chevron is the boundary: everything left of it tucks away.")
                .font(.system(size: 13))
                .foregroundStyle(Ink.textDim)
                .frame(maxWidth: 420, alignment: .leading)
                .opacity(appeared ? 1 : 0)
                .animation(springSnappy, value: tucked)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(springSoft.delay(0.1)) { appeared = true }
        }
    }
}

// MARK: - Step 4 · Ready

private struct ReadyStep: View {
    let appState: AppState
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            Text("Settled in.")
                .font(.system(size: 46, weight: .semibold))
                .tracking(-1.2)
                .foregroundStyle(Ink.text)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 18)

            Spacer().frame(height: 16)

            Text("Hover the bar to peek, click the chevron to toggle, right-click it for settings. Everything else is arrangeable in Nook Settings › Menu Bar.")
                .font(.system(size: 13))
                .foregroundStyle(Ink.textDim)
                .frame(maxWidth: 420, alignment: .leading)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 18)

            Spacer().frame(height: 32)

            Toggle(isOn: Binding(
                get: { appState.settings.launchAtLogin },
                set: { enabled in
                    appState.settings.launchAtLogin = enabled
                    try? enabled
                        ? SMAppService.mainApp.register()
                        : SMAppService.mainApp.unregister()
                    appState.settingsChanged()
                }
            )) {
                Text("Open Nook at login")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Ink.text)
            }
            .toggleStyle(.switch)
            .tint(Ink.amber)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 18)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(springSoft.delay(0.1)) { appeared = true }
        }
    }
}

// MARK: - The demo bar

/// A miniature menubar. `.loop` plays the tidy-and-peek choreography;
/// `.interactive` hands the user one draggable icon and lets the drop across
/// the chevron teach the mechanic.
private struct DemoBar: View {
    enum Mode {
        case loop
        case interactive(tucked: Binding<Bool>)
    }

    let mode: Mode

    private let hideableSymbols = ["cube", "leaf", "moon", "paperplane"]
    private let stayingSymbols = ["wifi", "battery.75percent", "clock"]

    @State private var hidden = false
    @State private var loopTask: Task<Void, Never>?
    @State private var dragOffset: CGSize = .zero
    @State private var dragTucked = false

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            // Hideable group — tucks INTO the chevron: right-anchored frames
            // so each icon slides toward the boundary as its slot closes,
            // nearest-to-the-chevron first. (Center-collapse reads wrong —
            // the real bar's right side never moves.)
            HStack(spacing: hidden ? 0 : 10) {
                ForEach(Array(hideableSymbols.enumerated()), id: \.offset) { index, symbol in
                    slot(symbol)
                        .opacity(hidden ? 0 : 1)
                        .scaleEffect(hidden ? 0.5 : 1, anchor: .trailing)
                        .frame(width: hidden ? 0 : 28, alignment: .trailing)
                        .animation(
                            springSnappy.delay(Double(hideableSymbols.count - 1 - index) * 0.05),
                            value: hidden
                        )
                }
                if case .interactive = mode {
                    if dragTucked {
                        // Tucked icon joins the hidden side, dimmed.
                        slot("star")
                            .opacity(0.35)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
            }

            // The chevron — the boundary, marked in amber.
            Image(systemName: "chevron.compact.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Ink.amber)
                .frame(width: 20)

            if case .interactive = mode, !dragTucked {
                slot("star", accent: true)
                    .offset(dragOffset)
                    .zIndex(2)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                dragOffset = CGSize(width: value.translation.width, height: 0)
                            }
                            .onEnded { value in
                                if value.translation.width < -46 {
                                    withAnimation(springSnappy) {
                                        dragTucked = true
                                        if case .interactive(let tucked) = mode {
                                            tucked.wrappedValue = true
                                        }
                                    }
                                }
                                withAnimation(springSnappy) { dragOffset = .zero }
                            }
                    )
                    .help("Drag me left of the chevron")
            }

            // Always-visible group.
            HStack(spacing: 10) {
                ForEach(stayingSymbols, id: \.self) { symbol in
                    slot(symbol)
                }
            }

            Text("14:50")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Ink.text.opacity(0.8))
        }
        .padding(.leading, 16)
        .padding(.trailing, 22)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Ink.raised)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        )
        .onAppear {
            if case .loop = mode {
                loopTask = Task {
                    // Choreography: settle, tuck, hold, peek, hold, repeat.
                    try? await Task.sleep(for: .seconds(1.2))
                    while !Task.isCancelled {
                        withAnimation { hidden = true }
                        try? await Task.sleep(for: .seconds(2.2))
                        withAnimation { hidden = false }
                        try? await Task.sleep(for: .seconds(2.6))
                    }
                }
            }
        }
        .onDisappear { loopTask?.cancel() }
    }

    private func slot(_ symbol: String, accent: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(accent ? Ink.amber : Ink.text.opacity(0.85))
            .frame(width: 28, height: 28)
            .background(
                Circle().fill(accent ? Ink.amber.opacity(0.14) : Ink.text.opacity(0.05))
            )
    }
}

// MARK: - Buttons

private struct AmberButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Ink.base)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Capsule().fill(Ink.amber))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(springSnappy, value: configuration.isPressed)
    }
}

private struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Ink.textDim)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
