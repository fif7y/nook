// ConcealGhostOverlay.swift
// The agent animates reveals (slide + fade over ~150ms) but drops concealed
// items with NO animation — the whole strip pops off within a frame or two
// (measured via frame capture, 2026-08-20). The overlay manufactures the
// missing hide motion: screenshot the strip of items about to conceal, float
// it over the bar, let the swap pop the real items beneath the cover, then
// fade the snapshot out. One motion for the whole strip — third-party and
// Nook-owned items alike (per-item ghosts stand down while a strip is up).

import AppKit
import NookEngine
import QuartzCore
import ScreenCaptureKit

/// Explicit Core Animation alpha fade. On macOS 27, `animator().alphaValue`
/// under NSAnimationContext completes almost immediately for windows AND
/// views (verified with presentation sampling, 2026-08-20) — the fade reads
/// as a pop. Only an explicit CABasicAnimation composites fractional alpha
/// over the full duration.
@MainActor
enum AlphaFade {
    static func run(
        _ view: NSView,
        to target: CGFloat,
        duration: CFTimeInterval,
        controlPoints points: (Float, Float, Float, Float),
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        view.wantsLayer = true
        guard let layer = view.layer else { completion?(); return }
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        if let completion {
            CATransaction.setCompletionBlock {
                Task { @MainActor in completion() }
            }
        }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = from
        anim.toValue = Float(target)
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(
            controlPoints: points.0, points.1, points.2, points.3
        )
        layer.add(anim, forKey: "nookAlphaFade")
        layer.opacity = Float(target)
        CATransaction.commit()
    }
}

@MainActor
final class ConcealGhostOverlay {
    /// True while a strip overlay is covering the bar — SeparatorManager and
    /// ExtrasManager skip their per-item ghosts (the strip already shows their
    /// glyphs; a second fading copy would double-expose).
    private(set) static var stripActive = false

    /// SCShareableContent lookup is the slow part (can be 100ms+) — cache the
    /// display handle so repeat conceals only pay for the capture itself.
    private static var cachedDisplay: SCDisplay?

    static func prewarmDisplay() {
        Task { _ = await display() }
    }

    private static func display() async -> SCDisplay? {
        if let cachedDisplay { return cachedDisplay }
        guard
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
            let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
        else { return nil }
        cachedDisplay = display
        return display
    }

    private let window: NSWindow
    private let imageView: NSImageView
    private var finished = false

    /// Capture `rect` (AX global top-left coordinates, main display) and put
    /// the snapshot up at full alpha. Returns nil when capture is unavailable
    /// — the conceal then runs uncovered, never blocked. Call `fadeOut()` once
    /// the swap beneath has been issued; a safety timeout fades regardless.
    static func begin(over rect: CGRect?) async -> ConcealGhostOverlay? {
        guard
            let rect, rect.width > 8,
            CGPreflightScreenCaptureAccess(),
            let primary = NSScreen.screens.first,
            let display = await display()
        else { return nil }

        // Pad horizontally and take the full bar height so the snapshot's
        // background is continuous with the bar around it.
        let bandHeight = max(rect.maxY, primary.frame.maxY - primary.visibleFrame.maxY)
        let capture = CGRect(
            x: max(0, rect.minX - 6), y: 0,
            width: min(rect.width + 12, CGFloat(display.width) - max(0, rect.minX - 6)),
            height: bandHeight
        )
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = capture
        config.width = Int(capture.width) * 2
        config.height = Int(capture.height) * 2
        config.showsCursor = false
        guard let shot = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        ) else {
            NookLog.log("ghost: strip capture failed — conceal runs uncovered")
            return nil
        }
        return ConcealGhostOverlay(shot: shot, capture: capture, primary: primary)
    }

    private init(shot: CGImage, capture: CGRect, primary: NSScreen) {
        // AX top-left → Cocoa bottom-left.
        let frame = NSRect(
            x: capture.minX,
            y: primary.frame.maxY - capture.maxY,
            width: capture.width,
            height: capture.height
        )
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.hasShadow = false
        imageView = NSImageView(
            image: NSImage(cgImage: shot, size: frame.size)
        )
        imageView.frame = NSRect(origin: .zero, size: frame.size)
        imageView.wantsLayer = true
        window.contentView = imageView
        window.orderFrontRegardless()
        window.displayIfNeeded()
        Self.stripActive = true
        NookLog.log("ghost: strip up \(Int(capture.width))×\(Int(capture.height))")
        // Safety: never leave a stale cover if the caller's task dies.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.fadeOut()
        }
    }

    /// Fade the cover out — ease-in (holds visibility, then accelerates away),
    /// the mirror of the show fade's ease-out. Idempotent.
    func fadeOut() {
        guard !finished else { return }
        finished = true
        AlphaFade.run(imageView, to: 0, duration: 0.3, controlPoints: (0.55, 0, 0.8, 0.4)) { [window] in
            window.orderOut(nil)
            Self.stripActive = false
        }
    }
}
