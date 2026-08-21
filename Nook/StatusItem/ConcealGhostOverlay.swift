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
    static var stripActive: Bool { currentStrip != nil }
    /// The strip currently covering the bar. Instance-tracked, not a bool:
    /// with back-to-back conceals, an OLDER strip's fade completion must not
    /// clear the flag while a newer strip is still up.
    private static weak var currentStrip: ConcealGhostOverlay?

    /// SCShareableContent lookup is the slow part (can be 100ms+) — cache the
    /// display handle so repeat conceals only pay for the capture itself.
    /// Invalidated on display reconfiguration: a stale SCDisplay makes every
    /// capture fail (no hide animation) or capture wrong geometry.
    private static var cachedDisplay: SCDisplay?
    private static var reconfigureObserver: NSObjectProtocol?

    static func prewarmDisplay() {
        if reconfigureObserver == nil {
            reconfigureObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { _ in
                Task { @MainActor in
                    cachedDisplay = nil
                    _ = await display()
                }
            }
        }
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

    /// A captured strip image ready to float — reveal covers pre-capture at
    /// conceal settle so the reveal path pays zero capture latency.
    struct BarSnapshot: @unchecked Sendable {
        let image: CGImage
        let capture: CGRect
        let takenAt: Date
    }

    /// Capture `rect` (AX global top-left coordinates, main display). Returns
    /// nil when capture is unavailable — callers then run uncovered, never
    /// blocked.
    static func snapshot(of rect: CGRect?) async -> BarSnapshot? {
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
            NookLog.log("ghost: strip capture failed — running uncovered")
            return nil
        }
        return BarSnapshot(image: shot, capture: capture, takenAt: Date())
    }

    /// Capture now and float immediately. Call `fadeOut()`/`dismiss()` once
    /// the swap beneath has been issued; a safety timeout fades regardless.
    static func begin(over rect: CGRect?, safety: TimeInterval = 0.5) async -> ConcealGhostOverlay? {
        guard let snap = await snapshot(of: rect) else { return nil }
        return begin(from: snap, safety: safety)
    }

    /// Float a pre-captured snapshot — synchronous, zero capture latency.
    static func begin(from snap: BarSnapshot, safety: TimeInterval = 0.5) -> ConcealGhostOverlay? {
        guard let primary = NSScreen.screens.first else { return nil }
        return ConcealGhostOverlay(shot: snap.image, capture: snap.capture, primary: primary, safety: safety)
    }

    private init(shot: CGImage, capture: CGRect, primary: NSScreen, safety: TimeInterval) {
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
        Self.currentStrip = self
        NookLog.log("ghost: strip up \(Int(capture.width))×\(Int(capture.height))")
        // Safety: never leave a stale cover if the caller's task dies.
        DispatchQueue.main.asyncAfter(deadline: .now() + safety) { [weak self] in
            self?.fadeOut()
        }
    }

    /// Drop the cover with no animation — the Instant reveal style: whatever
    /// landed beneath simply is, from one frame to the next. Idempotent.
    func dismiss() {
        guard !finished else { return }
        finished = true
        window.orderOut(nil)
        if Self.currentStrip === self {
            Self.currentStrip = nil
        }
    }

    /// Fade the cover out — ease-in (holds visibility, then accelerates away),
    /// the mirror of the show fade's ease-out. Idempotent. `slide` adds a
    /// rightward drift toward the chevron — the Smooth style's manufactured
    /// tuck-away, mirroring the agent's slide-in on reveal.
    func fadeOut(slide: Bool = false) {
        guard !finished else { return }
        finished = true
        if slide, let layer = imageView.layer {
            let shift = min(imageView.bounds.width * 0.5, 80)
            let anim = CABasicAnimation(keyPath: "position.x")
            anim.fromValue = layer.position.x
            anim.toValue = layer.position.x + shift
            anim.duration = 0.16
            anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.8, 0.4)
            layer.add(anim, forKey: "nookSlideOut")
            layer.position.x += shift
        }
        AlphaFade.run(imageView, to: 0, duration: 0.16, controlPoints: (0.55, 0, 0.8, 0.4)) { [window, weak self] in
            window.orderOut(nil)
            // Only the strip that is still current stands down the flag — an
            // older strip finishing must not expose a newer one's cover.
            if let self, Self.currentStrip === self {
                Self.currentStrip = nil
            }
        }
    }
}
