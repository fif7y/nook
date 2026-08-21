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
    /// reveals — concealed items can't be captured at all. (Per-window SCK
    /// capture would give true alpha, but macOS 27 exposes the whole bar as
    /// one WindowServer "Menubar" window that captures blank — items don't
    /// exist as individual SCWindows. Region capture + keying is all there is.)
    static func prewarmBarCaptures(items: [ObservedItem]) async {
        guard preferBarIcons, CGPreflightScreenCaptureAccess() else { return }
        guard
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
            let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
        else { return }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = 2
        // Capture ONLY the menu bar band, not the whole display: everything
        // cropped below is inside it (the item filter already requires
        // minY < 50), and a full-screen capture needlessly snapshots every
        // visible window — a privacy overreach for a menu bar utility, and
        // ~50× the pixels.
        let bandHeight = 50
        config.sourceRect = CGRect(x: 0, y: 0, width: display.width, height: bandHeight)
        config.width = display.width * scale
        config.height = bandHeight * scale
        config.showsCursor = false
        guard let shot = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        ) else { return }
        let pixelScale = CGFloat(shot.width) / CGFloat(display.width)
        var captured = 0
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
                  let glyph = keyedGlyph(from: crop, scale: pixelScale)
            else { continue }
            barCaptures[item.id.rawValue] = glyph
            captured += 1
        }
        // No pruning: captures of currently-concealed items are the cache's
        // value (a hover reveal only observes a subset). KB-scale worst case.
        NookLog.log("icons: captured \(captured) this pass (\(barCaptures.count) cached)")
    }

    /// Screen crops carry the bar material (blurred wallpaper) behind the
    /// glyph. The material is smooth, so the crop's border — item padding,
    /// never glyph — is a faithful background sample: subtract a per-channel
    /// border median with a soft ramp to get alpha. Monochrome glyphs become
    /// templates (native adaptive rendering); colored glyphs keep their color.
    private static func keyedGlyph(from crop: CGImage, scale: CGFloat) -> NSImage? {
        let width = crop.width
        let height = crop.height
        guard width > 8, height > 8 else { return nil }
        // Context-owned buffer (data: nil), read/written via bindMemory —
        // `CGContext(data: &pixels, …)` kept using the inout pointer past the
        // initializer call, which is formally undefined behavior.
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let base = ctx.data else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = UnsafeMutableBufferPointer(
            start: base.bindMemory(to: UInt8.self, capacity: width * height * 4),
            count: width * height * 4
        )

        // Background = per-channel median of the 2px border ring.
        var reds: [UInt8] = [], greens: [UInt8] = [], blues: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width where x < 2 || x >= width - 2 || y < 2 || y >= height - 2 {
                let i = (y * width + x) * 4
                reds.append(pixels[i]); greens.append(pixels[i + 1]); blues.append(pixels[i + 2])
            }
        }
        func median(_ values: inout [UInt8]) -> Int { values.sort(); return Int(values[values.count / 2]) }
        let bgR = median(&reds), bgG = median(&greens), bgB = median(&blues)

        // Distance from background → alpha (soft ramp kills the residual
        // veil that a hard luminance threshold leaves around the glyph).
        var alphas = [UInt8](repeating: 0, count: width * height)
        var minX = width, maxX = -1, minY = height, maxY = -1
        var coloredPixels = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                let distance = max(abs(r - bgR), abs(g - bgG), abs(b - bgB))
                let alpha = distance <= 14 ? 0 : min(255, (distance - 14) * 255 / 46)
                alphas[y * width + x] = UInt8(alpha)
                if alpha > 128 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                    if max(abs(r - g), abs(g - b), abs(r - b)) > 30 {
                        coloredPixels += 1
                    }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let isTemplate = coloredPixels < 12

        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let alpha = Int(alphas[y * width + x])
                if isTemplate {
                    // Only alpha matters for templates.
                    pixels[i] = UInt8(alpha); pixels[i + 1] = UInt8(alpha); pixels[i + 2] = UInt8(alpha)
                } else {
                    // Premultiply the true color by the keyed alpha.
                    pixels[i] = UInt8(Int(pixels[i]) * alpha / 255)
                    pixels[i + 1] = UInt8(Int(pixels[i + 1]) * alpha / 255)
                    pixels[i + 2] = UInt8(Int(pixels[i + 2]) * alpha / 255)
                }
                pixels[i + 3] = UInt8(alpha)
            }
        }

        let margin = 2
        let box = CGRect(
            x: max(0, minX - margin),
            y: max(0, minY - margin),
            width: min(width, maxX + margin + 1) - max(0, minX - margin),
            height: min(height, maxY + margin + 1) - max(0, minY - margin)
        )
        guard let masked = ctx.makeImage()?.cropping(to: box) else { return nil }
        let image = NSImage(
            cgImage: masked,
            size: NSSize(width: box.width / scale, height: box.height / scale)
        )
        image.isTemplate = isTemplate
        return image
    }

    private static var nookItemSymbols: [String: String] = [:]
    private static var nookItemImages: [String: NSImage] = [:]

    /// ExtrasManager registers each Nook item's SF Symbol by item title.
    static func registerNookItem(title: String, symbol: String) {
        nookItemSymbols[title] = symbol
    }

    /// Direct image registration for Nook items whose glyph is not an SF
    /// Symbol (separators render their text glyph).
    static func registerNookItem(title: String, image: NSImage) {
        nookItemImages[title] = image
    }

    static func icon(for item: ItemID) -> NSImage? {
        // Nook renders its own items' glyphs — a bar capture of them only
        // adds crop-and-upscale fuzz (a 4px separator dot blown up to tile
        // size), so the registered image outranks captures.
        if let image = nookItemImages.first(where: { item.rawValue.hasSuffix($0.key) })?.value {
            return image
        }
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
