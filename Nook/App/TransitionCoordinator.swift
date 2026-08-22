// TransitionCoordinator.swift
// Reveal/conceal execution, extracted from AppState.dispatch: the overlay
// cover lifecycle (pre-captured reveal cover, conceal ghost, swap-quiet
// holds) around the engine transition. The rehide state machine stays in
// AppState — settle re-entry goes through the onSettled callbacks.

import AppKit
import NookCore
import NookEngine

@MainActor
final class TransitionCoordinator {
    private weak var appState: AppState?
    private let engine: EngineGoldenGate

    init(appState: AppState, engine: EngineGoldenGate) {
        self.appState = appState
        self.engine = engine
    }

    /// Settle re-entry into AppState (rehide machine, settle catch-up,
    /// placement flush / hover re-arm). Wired once at boot.
    var onRevealSettled: (() -> Void)?
    var onConcealSettled: (() -> Void)?

    /// Where the concealed strip last sat — icons reappear in the same spot,
    /// so this rect is the reveal cover's footprint (Instant/Fade styles).
    private var lastConcealedStripRect: CGRect?

    /// Empty-strip snapshot pre-captured while the bar idles concealed — the
    /// reveal path floats it synchronously instead of paying ~100ms+ of SCK
    /// capture before the swap can even start (snappiness).
    private var revealCoverSnapshot: ConcealGhostOverlay.BarSnapshot?

    /// The reveal cover's footprint: the remembered strip, padded generously —
    /// left is the slide origin (empty bar, free to cover), right catches the
    /// visible cluster shifting. Strip width drifts between conceals.
    private var revealCoverRect: CGRect? {
        lastConcealedStripRect.map {
            CGRect(x: $0.minX - 120, y: $0.minY, width: $0.width + 180, height: $0.height)
        }
    }

    func performReveal(_ sections: Set<NookCore.Section>) {
        Task {
            guard let appState else { return }
            // Instant/Fade styles: the agent's slide-in is the only
            // reveal animation the OS offers — a snapshot of the
            // still-empty strip covers the slide, then pops (Instant)
            // or fades (Fade) away once the swap lands. The strip rect
            // is remembered from the last conceal (icons reappear
            // where they left); no memory yet → the slide shows.
            var cover: ConcealGhostOverlay?
            if appState.settings.revealAnimation != .smooth {
                // Pre-captured snapshot floats synchronously; only
                // fall back to a live capture when none is cached.
                // Freshness cap: an appearance/wallpaper change
                // while idle would flash a stale background.
                if let snap = revealCoverSnapshot,
                   Date().timeIntervalSince(snap.takenAt) < AppTiming.revealCoverFreshness {
                    cover = ConcealGhostOverlay.begin(from: snap, safety: AppTiming.transitionCoverSafety)
                } else {
                    cover = await ConcealGhostOverlay.begin(
                        over: revealCoverRect, safety: AppTiming.transitionCoverSafety
                    )
                }
                revealCoverSnapshot = nil
            }
            NookLog.log("effect reveal \(sections) → engine (anim=\(appState.settings.revealAnimation.rawValue), cover=\(cover != nil))")
            await engine.reveal(sections)
            appState.updateSnapshot(await engine.snapshot())
            if let cover {
                // Hold until the engine is swap-quiet: under rapid
                // hover cycles the real swap can land AFTER the settle
                // report (epoch-guard race), and the agent animates
                // each swap — a timed grace popped the cover mid-slide.
                let fade = appState.settings.revealAnimation == .fade
                Task { @MainActor in
                    await appState.waitUntilQuiesced(interval: 0.15, deadline: 2, poll: .milliseconds(30))
                    if fade { cover.fadeOut() } else { cover.dismiss() }
                }
            }
            NookLog.log("effect reveal settled")
            onRevealSettled?()
        }
    }

    func performConceal() {
        Task {
            guard let appState else { return }
            // Cover the strip BEFORE the swap: the agent pops
            // concealed items with no animation, so the overlay is
            // the hide animation. Fades once the swap has landed.
            // Instant style skips the cover — the pop IS the look.
            let strip = await concealStripFrames()
            lastConcealedStripRect = strip
            let ghost = appState.settings.revealAnimation == .instant
                ? nil
                : await ConcealGhostOverlay.begin(over: strip, safety: AppTiming.transitionCoverSafety)
            NookLog.log("effect conceal → engine")
            await engine.conceal()
            appState.updateSnapshot(await engine.snapshot())
            if let ghost {
                // Same swap-quiet hold as the reveal cover: a late
                // second swap after the ghost fades reads as a bounce.
                // Exit mirrors the entry style — Smooth tucks toward
                // the chevron, Fade dissolves in place.
                let slide = appState.settings.revealAnimation == .smooth
                Task { @MainActor in
                    await appState.waitUntilQuiesced(interval: 0.15, deadline: 2, poll: .milliseconds(30))
                    ghost.fadeOut(slide: slide)
                }
            }
            NookLog.log("effect conceal settled")
            onConcealSettled?()
            scheduleRevealCoverPrecapture()
        }
    }

    /// Once the bar has gone swap-quiet after a conceal and the ghost is off
    /// screen, the strip region shows exactly the "empty bar" the next reveal
    /// wants to freeze — capture it now so the reveal floats it instantly.
    private func scheduleRevealCoverPrecapture() {
        guard appState?.settings.revealAnimation != .smooth else { return }
        Task { @MainActor in
            guard let appState else { return }
            await appState.waitUntilQuiesced(interval: 0.5, deadline: 3, poll: .milliseconds(200))
            // The ghost's fade must not bake into the snapshot.
            try? await Task.sleep(for: .milliseconds(300))
            guard appState.currentRevealedSections.isEmpty, !ConcealGhostOverlay.stripActive
            else { return }
            revealCoverSnapshot = await ConcealGhostOverlay.snapshot(of: revealCoverRect)
        }
    }

    /// Union of the on-screen frames about to conceal (main-display band
    /// only): everything assigned to a non-visible section that currently has
    /// a frame. Nil when nothing concealable is showing. Re-snapshots: AX
    /// lists freshly revealed items progressively, and the settle-time
    /// snapshot can be missing half the strip.
    private func concealStripFrames() async -> CGRect? {
        guard let appState else { return nil }
        let snap = await engine.snapshot()
        var union: CGRect?
        var count = 0
        for item in snap.items {
            guard let frame = item.frame,
                  MenuBarGeometry.isInBand(frame),
                  appState.settings.sectionModel.section(of: item.id) != .visible
            else { continue }
            count += 1
            union = union.map { $0.union(frame) } ?? frame
        }
        NookLog.log("strip: \(count) items → \(union.map { "\(Int($0.minX))..\(Int($0.maxX))" } ?? "nil")")
        return union
    }
}
