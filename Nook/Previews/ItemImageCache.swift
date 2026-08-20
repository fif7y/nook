// ItemImageCache.swift
// Icon resolution for the layout editor: the chooser shows the REAL thing.
// Without Screen Recording we can't capture live status-item pixels, so the
// next-truest artifact is the owning app's icon (and the system symbol for
// Apple items). SCK live capture upgrades this in a later milestone.

import AppKit
import NookCore
import NookEngine
import ScreenCaptureKit

@MainActor
enum ItemImageCache {
    private static var appIcons: [String: NSImage] = [:]
    /// Live crops of the real menubar glyphs, keyed by item tag. Only filled
    /// while Screen Recording is granted and the bar-icons style is active.
    private static var barCaptures: [String: NSImage] = [:]
    static var preferBarIcons = false

    /// One display screenshot, cropped per visible item. Prewarm during
    /// reveals — concealed items can't be captured at all.
    static func prewarmBarCaptures(items: [ObservedItem]) async {
        guard preferBarIcons, CGPreflightScreenCaptureAccess() else { return }
        guard
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
            let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
        else { return }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = 2
        config.width = display.width * scale
        config.height = display.height * scale
        config.showsCursor = false
        guard let shot = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        ) else { return }
        let pixelScale = CGFloat(shot.width) / CGFloat(display.width)
        for item in items {
            guard let frame = item.frame,
                  frame.minY > -5, frame.minY < 50,  // main-display band only
                  frame.width > 4
            else { continue }
            let cropRect = CGRect(
                x: frame.minX * pixelScale,
                y: frame.minY * pixelScale,
                width: frame.width * pixelScale,
                height: frame.height * pixelScale
            )
            guard let crop = shot.cropping(to: cropRect),
                  let glyph = templateGlyph(from: crop)
            else { continue }
            barCaptures[item.id.rawValue] = glyph
        }
        NookLog.log("icons: prewarmed \(barCaptures.count) bar captures")
    }

    /// Raw screen crops carry the wallpaper tint and the item's padding.
    /// Menubar glyphs are white-on-dark, so luminance IS the shape: turn luma
    /// into alpha, tight-crop to the glyph's bounds, and mark the result as a
    /// template so it renders like a native monochrome icon.
    private static func templateGlyph(from crop: CGImage) -> NSImage? {
        let width = crop.width
        let height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Alpha from luminance; track the glyph's bounding box while at it.
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let luma = (Int(pixels[i]) * 299 + Int(pixels[i + 1]) * 587 + Int(pixels[i + 2]) * 114) / 1000
                let alpha = UInt8(luma)
                pixels[i] = alpha
                pixels[i + 1] = alpha
                pixels[i + 2] = alpha
                pixels[i + 3] = alpha
                if alpha > 60 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let margin = 2
        let box = CGRect(
            x: max(0, minX - margin),
            y: max(0, minY - margin),
            width: min(width, maxX + margin + 1) - max(0, minX - margin),
            height: min(height, maxY + margin + 1) - max(0, minY - margin)
        )
        guard let masked = ctx.makeImage()?.cropping(to: box) else { return nil }
        // Points at half the pixel size (captures are 2x).
        let image = NSImage(
            cgImage: masked,
            size: NSSize(width: box.width / 2, height: box.height / 2)
        )
        image.isTemplate = true
        return image
    }

    private static var nookItemSymbols: [String: String] = [:]

    /// ExtrasManager registers each Nook item's SF Symbol by item title.
    static func registerNookItem(title: String, symbol: String) {
        nookItemSymbols[title] = symbol
    }

    static func icon(for item: ItemID) -> NSImage? {
        if preferBarIcons, let capture = barCaptures[item.rawValue] {
            return capture
        }
        if let symbol = nookItemSymbols.first(where: { item.rawValue.hasSuffix($0.key) })?.value {
            return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        if let bundleID = item.bundleID {
            if bundleID == ItemEnumeratorBundle.agent {
                return systemSymbol(for: item)
            }
            if let cached = appIcons[bundleID] {
                return cached
            }
            let icon = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID).first?.icon
            if let icon {
                icon.size = NSSize(width: 20, height: 20)
                appIcons[bundleID] = icon
            }
            return icon
        }
        return nil
    }

    /// com.apple.menuextra.* → the SF Symbol the real item draws.
    private static func systemSymbol(for item: ItemID) -> NSImage? {
        let id = item.rawValue
        let symbol: String
        if id.contains("wifi") { symbol = "wifi" }
        else if id.contains("battery") { symbol = "battery.75percent" }
        else if id.contains("bluetooth") { symbol = "bluetooth" }
        else if id.contains("screen-mirroring") { symbol = "airplayvideo" }
        else if id.contains("clock") { symbol = "clock" }
        else if id.contains("audiovideo") { symbol = "video" }
        else if id.contains("controlcenter") { symbol = "switch.2" }
        else if id.contains("sound") { symbol = "speaker.wave.2" }
        else { symbol = "circle.dashed" }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }
}

enum ItemEnumeratorBundle {
    static let agent = "com.apple.MenuBarAgent"
}
