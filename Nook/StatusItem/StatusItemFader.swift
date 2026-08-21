// StatusItemFader.swift
// The one home for the Nook-owned status item show/hide choreography.
// SeparatorManager and ExtrasManager previously carried verbatim copies of
// this (identical constants, identical ghost code) — the timings here were
// hard-won against the agent's reflow behavior; change them in ONE place.
//
// Two-phase hide: the width-collapse rides the same coalesced bar reflow as
// the assertion swap (any later width change is a second agent animation —
// bounce and all), then after the reflow settles the item leaves layout
// entirely — zero-length items still reserve their built-in spacing, which
// reads as a dead gap next to the chevron. The glyph outlives its item as a
// ghost overlay fading at its old screen position, exactly how the agent
// renders third-party conceals.

import AppKit

@MainActor
enum StatusItemFader {
    /// Delay before the show fade starts — in step with the agent fading in
    /// assertion-revealed items during its reflow.
    private static let attachDelay: TimeInterval = 0.08
    /// Fade duration, symmetric for show and hide (matched to the agent's).
    private static let fadeDuration: TimeInterval = 0.22
    /// When the collapsed item leaves layout (after the reflow settles).
    private static let layoutDropDelay: TimeInterval = 0.45
    /// Ease-out for entrances.
    private static let showCurve: (Float, Float, Float, Float) = (0.16, 1, 0.3, 1)
    /// Ease-IN for exits (hold, then accelerate away) — the show curve dumped
    /// the alpha in the first frames and the hide read as a pop.
    private static let hideCurve: (Float, Float, Float, Float) = (0.55, 0, 0.8, 0.4)

    /// Apply visibility with the standard choreography. `stillCurrent` guards
    /// the delayed phases: it must return true only while `visible` is still
    /// the desired state for this item (a quick reversal must cancel them).
    static func setVisible(
        _ visible: Bool,
        item: NSStatusItem,
        shownLength: CGFloat,
        shownAlpha: CGFloat,
        stillCurrent: @escaping @MainActor () -> Bool
    ) {
        if visible {
            // Attach silently at FULL width right at companion time — Nook
            // items are pinned leftmost in their section, so the width lands
            // in empty left-edge space and displaces nothing.
            item.isVisible = true
            item.length = shownLength
            item.button?.alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + attachDelay) { [weak item] in
                guard stillCurrent(), let button = item?.button else { return }
                AlphaFade.run(button, to: shownAlpha, duration: fadeDuration, controlPoints: showCurve) {
                    button.alphaValue = shownAlpha  // re-sync the view property
                }
            }
        } else {
            showFadingGhost(for: item)
            item.length = 0
            item.button?.alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + layoutDropDelay) { [weak item] in
                guard stillCurrent() else { return }
                item?.isVisible = false
            }
        }
    }

    /// Snapshot the button and fade the snapshot at its old screen position.
    static func showFadingGhost(for item: NSStatusItem) {
        guard
            !ConcealGhostOverlay.stripActive,  // the strip already shows this glyph
            let button = item.button,
            let buttonWindow = button.window,
            let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds)
        else { return }
        button.cacheDisplay(in: button.bounds, to: rep)
        let image = NSImage(size: button.bounds.size)
        image.addRepresentation(rep)

        let screenRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let ghost = NSWindow(
            contentRect: screenRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        ghost.isOpaque = false
        ghost.backgroundColor = .clear
        ghost.level = .statusBar
        ghost.ignoresMouseEvents = true
        ghost.hasShadow = false
        let imageView = NSImageView(image: image)
        imageView.frame = NSRect(origin: .zero, size: screenRect.size)
        imageView.wantsLayer = true
        ghost.contentView = imageView
        ghost.orderFrontRegardless()
        AlphaFade.run(imageView, to: 0, duration: fadeDuration, controlPoints: hideCurve) {
            ghost.orderOut(nil)
        }
    }
}
