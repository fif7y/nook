// SeparatorManager.swift
// User-created separator/spacer items (Spaced-style). Plain NSStatusItems with
// stable autosave names — natively ⌘-draggable, right-click opens Nook's menu
// (an always-available settings entry point in iconless mode).

import AppKit
import NookCore

final class SeparatorManager {
    private var items: [UUID: NSStatusItem] = [:]
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func sync(with specs: [SeparatorSpec]) {
        let wanted = Set(specs.map(\.id))
        for (id, item) in items where !wanted.contains(id) {
            NSStatusBar.system.removeStatusItem(item)
            items.removeValue(forKey: id)
        }
        for spec in specs {
            if let existing = items[spec.id] {
                configure(existing.button, style: spec.style)
            } else {
                let item = NSStatusBar.system.statusItem(
                    withLength: spec.style == .space ? 14 : NSStatusItem.variableLength
                )
                item.autosaveName = "Nook.Separator.\(spec.id.uuidString)"
                configure(item.button, style: spec.style)
                items[spec.id] = item
            }
        }
    }

    private func configure(_ button: NSStatusBarButton?, style: SeparatorStyle) {
        guard let button else { return }
        button.title = style == .space ? "" : style.rawValue
        button.appearsDisabled = false
        button.alphaValue = style == .space ? 0 : 0.55
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.rightMouseUp])
    }

    @objc private func clicked() {
        guard let appState else { return }
        let menu = NookStatusItem.contextMenu(appState: appState)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}
