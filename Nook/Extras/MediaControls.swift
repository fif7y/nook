// MediaControls.swift
// Nook's own media item — the answer to macOS collateral-hiding the system
// Now Playing extra: an item WE own needs no assertion to hide, so it behaves
// like any icon in the sections (better, even). Controls ride HID media-key
// events — no permissions, works with every player. Track metadata is behind
// Apple's locked-down MediaRemote API and is deliberately out of scope.

import AppKit
import NookCore
import NookEngine

enum MediaKey: Int32 {
    case playPause = 16  // NX_KEYTYPE_PLAY
    case next = 17       // NX_KEYTYPE_NEXT
    case previous = 18   // NX_KEYTYPE_PREVIOUS
    case fastForward = 19
    case rewind = 20

    /// Posts the system-defined media key (down+up), same as the keyboard key.
    func send() {
        for down in [true, false] {
            let flags: UInt = down ? 0xA00 : 0xB00
            let data1 = Int((Int(self.rawValue) << 16) | ((down ? 0xA : 0xB) << 8))
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

/// The ⏯ status item. Section membership works through Nook's own visibility
/// control (`isVisible`), not the assertion — Nook's bundle can't be asserted
/// away without taking the chevron with it.
final class MediaControlsItem {
    static let itemID = ItemID(rawValue: "status:\(Bundle.main.bundleIdentifier ?? "app.fif7y.Nook")::Nook.MediaControls")

    private let item: NSStatusItem
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "Nook.MediaControls"
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "playpause.fill",
                accessibilityDescription: "Media Controls"
            )
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    /// Applies section membership: visible when its section is visible or
    /// currently revealed.
    func apply(model: SectionModel, revealed: Set<NookCore.Section>) {
        let section = model.section(of: Self.itemID)
        item.isVisible = section == .visible || revealed.contains(section)
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let previous = NSMenuItem(title: "Previous Track", action: #selector(previousTrack), keyEquivalent: "")
            let next = NSMenuItem(title: "Next Track", action: #selector(nextTrack), keyEquivalent: "")
            for menuItem in [previous, next] { menuItem.target = self }
            menu.items = [previous, next]
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            MediaKey.playPause.send()
        }
    }

    @objc private func previousTrack() { MediaKey.previous.send() }
    @objc private func nextTrack() { MediaKey.next.send() }
}
