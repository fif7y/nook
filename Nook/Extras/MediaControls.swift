// MediaControls.swift — Nook items ("extras"): Nook-owned proxies for the
// system extras that macOS collateral-hides under any assertion, plus user
// shortcut buttons. Because Nook owns these NSStatusItems, hiding is plain
// `isVisible` per assigned section — no assertion involvement (asserting away
// Nook's bundle would take the chevron too).

import AppKit
import AVFoundation
import CoreAudio
import CoreMediaIO
import NookCore
import NookEngine

// MARK: - Media keys

enum MediaKey: Int32 {
    case playPause = 16  // NX_KEYTYPE_PLAY
    case next = 17       // NX_KEYTYPE_NEXT
    case previous = 18   // NX_KEYTYPE_PREVIOUS

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

// MARK: - Manager

@MainActor
final class ExtrasManager {
    private weak var appState: AppState?
    private var items: [UUID: NSStatusItem] = [:]
    private var specs: [UUID: ExtraItemSpec] = [:]
    private var lastVisible: [UUID: Bool] = [:]
    private var cameraMicMonitor: CameraMicMonitor?

    init(appState: AppState) {
        self.appState = appState
    }

    static func itemID(for spec: ExtraItemSpec) -> ItemID {
        ItemID(rawValue: "status:\(Bundle.main.bundleIdentifier ?? "app.fif7y.Nook")::\(spec.itemTitle)")
    }

    /// All ItemIDs the editor should represent even when invisible.
    var managedItemIDs: [ItemID] {
        specs.values.map(Self.itemID(for:))
    }

    func sync(with newSpecs: [ExtraItemSpec]) {
        let wanted = Set(newSpecs.map(\.id))
        for (id, item) in items where !wanted.contains(id) {
            NSStatusBar.system.removeStatusItem(item)
            items.removeValue(forKey: id)
            specs.removeValue(forKey: id)
        }
        for spec in newSpecs {
            specs[spec.id] = spec
            if items[spec.id] == nil {
                items[spec.id] = makeItem(for: spec)
            }
            ItemImageCache.registerNookItem(
                title: spec.itemTitle, symbol: Self.symbol(for: spec)
            )
        }
        let needsCameraMonitor = newSpecs.contains { $0.kind == .cameraMicIndicator }
        if needsCameraMonitor, cameraMicMonitor == nil {
            cameraMicMonitor = CameraMicMonitor { [weak self] in
                self?.applyCurrent()
            }
        } else if !needsCameraMonitor {
            cameraMicMonitor?.stop()
            cameraMicMonitor = nil
        }
        applyCurrent()
    }

    /// Applies section visibility. Hiding collapses the item's LENGTH instead
    /// of toggling isVisible — isVisible plays its own slide animation on a
    /// different clock than the assertion reflow; a width collapse rides the
    /// same bar reflow and reads as one motion. The camera/mic indicator
    /// overrides its section while hardware is live — an indicator that hides
    /// when active would be lying.
    func apply(
        model: SectionModel,
        revealed: Set<NookCore.Section>,
        systemCameraPillVisible: Bool
    ) {
        for (id, item) in items {
            guard let spec = specs[id] else { continue }
            let section = model.section(of: Self.itemID(for: spec))
            var visible = section == .visible || revealed.contains(section)
            if spec.kind == .cameraMicIndicator {
                // macOS force-shows its own camera pill through the assertion
                // when the camera is live (privacy override). Nook's indicator
                // fills the gap, never duplicates: it self-asserts only while
                // hardware is active AND the system pill isn't on screen.
                let active = cameraMicMonitor?.isActive ?? false
                visible = visible || (active && !systemCameraPillVisible)
                if systemCameraPillVisible, section != .visible, !revealed.contains(section) {
                    visible = false
                }
                updateCameraSymbol(item, monitor: cameraMicMonitor)
            }
            setVisible(visible, for: id, item: item)
        }
    }

    /// Two-phase hide: width-collapse rides the same bar reflow as the
    /// assertion (matched animation), then after the reflow settles the item
    /// leaves layout entirely — zero-length items still reserve their built-in
    /// spacing, which reads as a dead gap next to the chevron.
    private func setVisible(_ visible: Bool, for id: UUID, item: NSStatusItem) {
        guard lastVisible[id] != visible else { return }
        lastVisible[id] = visible
        // Snap, don't stage: this runs as the engine's reflow companion — the
        // width change lands in the SAME agent reflow as the assertion swap,
        // so the agent's own animation carries these items exactly like the
        // assertion-hidden ones. Any staged fade of our own runs on a second
        // clock and reads as sliding.
        if visible {
            item.isVisible = true
            item.length = NSStatusItem.squareLength
            item.button?.alphaValue = 1
        } else {
            item.length = 0
            item.button?.alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.lastVisible[id] == false else { return }
                self.items[id]?.isVisible = false
            }
        }
    }

    private func applyCurrent() {
        guard let appState else { return }
        apply(
            model: appState.settings.sectionModel,
            revealed: appState.revealedSectionsForExtras,
            systemCameraPillVisible: appState.systemCameraPillVisible
        )
    }

    // MARK: Item construction

    private func makeItem(for spec: ExtraItemSpec) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = spec.itemTitle
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: Self.symbol(for: spec),
                accessibilityDescription: spec.itemTitle
            )
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // Explicit AX title = the engine's item identity. Without it the
            // enumerator falls back to "Item-0" and every Nook item collides.
            button.setAccessibilityTitle(spec.itemTitle)
        }
        return item
    }

    static func symbol(for spec: ExtraItemSpec) -> String {
        switch spec.kind {
        case .mediaControls: "playpause.fill"
        case .cameraMicIndicator: "video.fill"
        case .airdrop: Self.airdropSymbol
        case .shortcut: spec.symbol ?? "bolt.fill"
        }
    }

    /// SF Symbols has a real "airdrop" glyph on current systems; fall back to
    /// the radiating-waves look everywhere else.
    static let airdropSymbol: String = {
        NSImage(systemSymbolName: "airdrop", accessibilityDescription: nil) != nil
            ? "airdrop"
            : "dot.radiowaves.left.and.right"
    }()

    private func updateCameraSymbol(_ item: NSStatusItem, monitor: CameraMicMonitor?) {
        let camera = monitor?.cameraActive ?? false
        let mic = monitor?.micActive ?? false
        let symbol = camera ? "video.fill" : (mic ? "mic.fill" : "video.fill")
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Camera & Mic")
        if camera || mic {
            image?.isTemplate = false
            item.button?.contentTintColor = camera ? .systemGreen : .systemOrange
        } else {
            item.button?.contentTintColor = nil
        }
        item.button?.image = image
    }

    // MARK: Actions

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard
            let statusItem = items.first(where: { $0.value.button === sender }),
            let spec = specs[statusItem.key]
        else { return }
        let rightClick = NSApp.currentEvent?.type == .rightMouseUp

        switch spec.kind {
        case .mediaControls:
            if rightClick {
                let menu = NSMenu()
                let previous = NSMenuItem(title: "Previous Track", action: #selector(previousTrack), keyEquivalent: "")
                let next = NSMenuItem(title: "Next Track", action: #selector(nextTrack), keyEquivalent: "")
                for menuItem in [previous, next] { menuItem.target = self }
                menu.items = [previous, next]
                popUp(menu, on: statusItem.value)
            } else {
                MediaKey.playPause.send()
            }
        case .cameraMicIndicator:
            // Informational; click opens Privacy settings for a quick audit.
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
            )
        case .airdrop:
            openAirDrop()
        case .shortcut:
            if let name = spec.shortcutName {
                runShortcut(named: name)
            }
        }
    }

    private func popUp(_ menu: NSMenu, on item: NSStatusItem) {
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func previousTrack() { MediaKey.previous.send() }
    @objc private func nextTrack() { MediaKey.next.send() }

    private func openAirDrop() {
        // Finder's AirDrop view via its keyboard shortcut (⇧⌘R) — the only
        // stable public entry point.
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let source = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 15 /* R */, keyDown: down)
                event?.flags = [.maskCommand, .maskShift]
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    private func runShortcut(named name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        try? process.run()
    }

    /// Names from the user's Shortcuts library (for the picker).
    nonisolated static func availableShortcuts() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

// MARK: - Camera / mic activity

/// Polls "is any camera/mic in use" via public CoreMediaIO / CoreAudio
/// properties (the OverSight approach). 2s cadence — indicators, not alarms.
final class CameraMicMonitor {
    private(set) var cameraActive = false
    private(set) var micActive = false
    private var timer: Timer?
    private let onChange: () -> Void

    var isActive: Bool { cameraActive || micActive }

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    // No deinit: the monitor lives as long as its ExtrasManager entry; the
    // timer is invalidated in stop() when the indicator item is removed.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let camera = Self.anyCameraRunning()
        let mic = Self.anyMicRunning()
        if camera != cameraActive || mic != micActive {
            cameraActive = camera
            micActive = mic
            onChange()
        }
    }

    private static func anyCameraRunning() -> Bool {
        var propertyAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &propertyAddress, 0, nil, &dataSize
        ) == noErr else { return false }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var deviceIDs = [CMIOObjectID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &propertyAddress, 0, nil, dataSize, &dataUsed, &deviceIDs
        ) == noErr else { return false }

        var runningAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        for deviceID in deviceIDs {
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if CMIOObjectGetPropertyData(deviceID, &runningAddress, 0, nil, size, &size, &running) == noErr,
               running != 0 {
                return true
            }
        }
        return false
    }

    private static func anyMicRunning() -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize
        ) == noErr else { return false }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return false }

        for deviceID in deviceIDs {
            // Input side only.
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &streamsSize) == noErr,
                  streamsSize > 0 else { continue }

            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &runningAddress, 0, nil, &size, &running) == noErr,
               running != 0 {
                return true
            }
        }
        return false
    }
}
