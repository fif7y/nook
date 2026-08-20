// SeparatorManager.swift
// User-created separator/spacer items (Spaced-style). Plain NSStatusItems with
// stable autosave names — natively ⌘-draggable, right-click opens Nook's menu
// (an always-available settings entry point in iconless mode).
//
// Separators are section-managed like Nook's extras: hiding is their OWN
// visibility (asserting away Nook's bundle would take the chevron too), and
// the width-collapse rides the engine's reflow companion so their motion
// matches the assertion items'.

import AppKit
import NookCore
import NookEngine

@MainActor
final class SeparatorManager {
    private var items: [UUID: NSStatusItem] = [:]
    private var specsByID: [UUID: SeparatorSpec] = [:]
    private var lastVisible: [UUID: Bool] = [:]
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    static func itemID(for spec: SeparatorSpec) -> ItemID {
        ItemID(rawValue: "status:\(Bundle.main.bundleIdentifier ?? "app.fif7y.Nook")::Nook.Separator.\(spec.id.uuidString)")
    }

    func sync(with specs: [SeparatorSpec]) {
        let wanted = Set(specs.map(\.id))
        for (id, item) in items where !wanted.contains(id) {
            NSStatusBar.system.removeStatusItem(item)
            items.removeValue(forKey: id)
            specsByID.removeValue(forKey: id)
            lastVisible.removeValue(forKey: id)
        }
        for spec in specs {
            specsByID[spec.id] = spec
            if let existing = items[spec.id] {
                configure(existing.button, spec: spec)
            } else {
                let item = NSStatusBar.system.statusItem(
                    withLength: spec.style == .space ? 14 : NSStatusItem.variableLength
                )
                item.autosaveName = "Nook.Separator.\(spec.id.uuidString)"
                item.button?.setAccessibilityTitle("Nook.Separator.\(spec.id.uuidString)")
                configure(item.button, spec: spec)
                items[spec.id] = item
            }
            ItemImageCache.registerNookItem(
                title: "Nook.Separator.\(spec.id.uuidString)",
                image: Self.glyphImage(for: spec.style)
            )
        }
        applyCurrent()
    }

    /// Section visibility, extras-style: width-collapse in the same reflow as
    /// the assertion swap, then leave layout once the bar has settled.
    func apply(model: SectionModel, revealed: Set<NookCore.Section>) {
        for (id, item) in items {
            guard let spec = specsByID[id] else { continue }
            let section = model.section(of: Self.itemID(for: spec))
            setVisible(section == .visible || revealed.contains(section), for: id, item: item, spec: spec)
        }
    }

    private func applyCurrent() {
        guard let appState else { return }
        apply(
            model: appState.settings.sectionModel,
            revealed: appState.revealedSectionsForExtras
        )
    }

    private func setVisible(_ visible: Bool, for id: UUID, item: NSStatusItem, spec: SeparatorSpec) {
        guard lastVisible[id] != visible else { return }
        lastVisible[id] = visible
        NookLog.log("separator: \(spec.style.displayName) → \(visible ? "show" : "hide")")
        if visible {
            item.isVisible = true
            item.length = spec.style == .space ? 14 : NSStatusItem.variableLength
            item.button?.alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, self.lastVisible[id] == true,
                      let button = self.items[id]?.button else { return }
                let target = spec.style == .space ? 0 : spec.opacity
                AlphaFade.run(button, to: target, duration: 0.22, controlPoints: (0.16, 1, 0.3, 1)) {
                    button.alphaValue = target  // re-sync the view property
                }
            }
        } else {
            // Same ghost-fade as extras: the glyph outlives its item as a
            // floating snapshot while the gap closes in the bar reflow.
            showFadingGhost(for: item)
            item.length = 0
            item.button?.alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.lastVisible[id] == false else { return }
                self.items[id]?.isVisible = false
            }
        }
    }

    /// Snapshot the button and fade the snapshot at its old screen position.
    private func showFadingGhost(for item: NSStatusItem) {
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
        // Ease-IN for the fade-out (hold, then accelerate away) — the show
        // curve's ease-out dumped the alpha in the first frames and the hide
        // read as a pop.
        AlphaFade.run(imageView, to: 0, duration: 0.3, controlPoints: (0.55, 0, 0.8, 0.4)) {
            ghost.orderOut(nil)
        }
    }

    private func configure(_ button: NSStatusBarButton?, spec: SeparatorSpec) {
        guard let button else { return }
        button.title = spec.style == .space ? "" : spec.style.rawValue
        button.appearsDisabled = false
        // While hidden, alpha stays down; the reveal animation restores it.
        if lastVisible[spec.id] != false {
            button.alphaValue = spec.style == .space ? 0 : spec.opacity
        }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.rightMouseUp])
    }

    /// Editor-tile glyph: the separator's actual character, template-style.
    private static func glyphImage(for style: SeparatorStyle) -> NSImage {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            let text = style == .space ? "␣" : style.rawValue
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.black,
            ]
            let string = NSAttributedString(string: text, attributes: attributes)
            let bounds = string.size()
            string.draw(at: NSPoint(
                x: rect.midX - bounds.width / 2,
                y: rect.midY - bounds.height / 2
            ))
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func clicked() {
        guard let appState else { return }
        let menu = NookStatusItem.contextMenu(appState: appState)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}
