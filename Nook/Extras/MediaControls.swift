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
    /// Play/pause state the media glyph shows. Click intent drives it (players
    /// keep the output device open while paused, so DeviceIsRunningSomewhere
    /// alone can't see a pause); real audio EDGES reconcile it when they do
    /// arrive — start means playing, device release means stopped.
    private var mediaPlaying = false
    private var lastAudioOutputActive = false
    /// Edge tracking for the camera/mic indicator's placement walk.
    private var lastCameraIndicatorVisible = false

    init(appState: AppState) {
        self.appState = appState
    }

    static func itemID(for spec: ExtraItemSpec) -> ItemID {
        .status(
            bundle: NookBundle.mainID,
            title: spec.itemTitle
        )
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
            lastVisible.removeValue(forKey: id)
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
        let needsCameraMonitor = newSpecs.contains {
            $0.kind == .cameraMicIndicator || $0.kind == .mediaControls
        }
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
            switch spec.kind {
            case .cameraMicIndicator:
                // Pure indicator, like Apple's: exists ONLY while hardware is
                // live (section decides where it appears, not whether). Defers
                // to the system pill when that one is on screen.
                let active = cameraMicMonitor?.isActive ?? false
                visible = active && !systemCameraPillVisible
                updateCameraSymbol(item, monitor: cameraMicMonitor)
                // Re-entering layout (isVisible flip) parks the item wherever
                // the agent decides, not at its model slot — walk it back on
                // the ACTIVATION edge only (a no-op when already in place;
                // reveals must not trigger drags).
                if visible, !lastCameraIndicatorVisible {
                    let itemID = Self.itemID(for: spec)
                    Task { await appState?.placeDynamicExtra(itemID) }
                }
                lastCameraIndicatorVisible = visible
            case .mediaControls:
                // Section-governed AND media-relevant: playing, or within the
                // post-playback linger so pause doesn't swallow resume.
                visible = visible && (cameraMicMonitor?.mediaRelevant ?? true)
                let audioActive = cameraMicMonitor?.audioOutputActive ?? false
                if audioActive != lastAudioOutputActive {
                    lastAudioOutputActive = audioActive
                    mediaPlaying = audioActive
                }
                updateMediaSymbol(item, title: spec.itemTitle)
            case .airdrop, .shortcut:
                break
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
        NookLog.log("extras: \(specs[id]?.itemTitle ?? "?") → \(visible ? "show" : "hide (ghost)")")
        // Runs as the engine's reflow companion, so timing coincides with the
        // assertion swap — choreography and constants live in StatusItemFader.
        StatusItemFader.setVisible(
            visible,
            item: item,
            shownLength: NSStatusItem.squareLength,
            shownAlpha: 1
        ) { [weak self] in
            self?.lastVisible[id] == visible
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

    /// Play when idle (click plays), pause while audio is running (click
    /// pauses) — the button shows the action a click will take.
    private func updateMediaSymbol(_ item: NSStatusItem, title: String) {
        item.button?.image = NSImage(
            systemSymbolName: mediaPlaying ? "pause.fill" : "play.fill",
            accessibilityDescription: title
        )
    }

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
                mediaPlaying.toggle()
                updateMediaSymbol(statusItem.value, title: spec.itemTitle)
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
        // stable public entry point. The chord is posted globally, so ONLY
        // post it once Finder actually owns the keyboard: on a slow
        // activation the chord would land in whatever is frontmost instead
        // (⇧⌘R is Reply-All in Mail, Reader in Safari…). Retry briefly, then
        // give up silently.
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        postAirDropChordWhenFinderFrontmost(attempt: 0)
    }

    private func postAirDropChordWhenFinderFrontmost(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else {
                if attempt < 4 {
                    self.postAirDropChordWhenFinderFrontmost(attempt: attempt + 1)
                }
                return
            }
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
        // Read BEFORE waiting: with output past the 64KB pipe buffer, the
        // child blocks on write and waitUntilExit never returns.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

// MARK: - Camera / mic activity

/// "Is any camera/mic in use" via public CoreMediaIO / CoreAudio properties
/// (the OverSight approach) — EVENT-DRIVEN: `DeviceIsRunningSomewhere`
/// property listeners per device (plus device-list listeners for hot-plug)
/// re-poll on change, and a slow 30s fallback timer covers the media-linger
/// expiry and any listener the OS fails to deliver. The original 2s poll was
/// Nook's only steady idle wakeup.
final class CameraMicMonitor {
    private(set) var cameraActive = false
    private(set) var micActive = false
    /// Any audio OUTPUT device running — the "something is playing" signal.
    private(set) var audioOutputActive = false
    private(set) var lastAudioActiveAt: Date = .distantPast
    private var timer: Timer?
    private let onChange: () -> Void
    // nonisolated(unsafe): mutated only on the main actor (install/remove),
    // but deinit must read them to unhook the HAL — Swift 6 bars isolated
    // property access from deinitializers.
    private nonisolated(unsafe) var audioListenerDevices: [AudioObjectID] = []
    private nonisolated(unsafe) var cmioListenerDevices: [CMIOObjectID] = []
    // C-function-pointer listeners, NOT the *ListenerBlock variants: the HAL
    // matches removals by block identity, and Swift re-bridges a closure to a
    // fresh block object on every call — so block removals never matched,
    // listeners accumulated across reinstalls, and each device event fanned
    // out into a main-thread reinstall storm (the 2026-08-21 beachball).
    // Function pointer + clientData compare reliably. Callbacks arrive on a
    // HAL thread; hop to main before touching state.
    private nonisolated static let audioListenerProc: AudioObjectPropertyListenerProc = { _, count, addresses, clientData in
        guard let clientData else { return noErr }
        let monitor = Unmanaged<CameraMicMonitor>.fromOpaque(clientData).takeUnretainedValue()
        let listChanged = UnsafeBufferPointer(start: addresses, count: Int(count))
            .contains { $0.mSelector == kAudioHardwarePropertyDevices }
        DispatchQueue.main.async {
            listChanged ? monitor.deviceListChanged() : monitor.poll()
        }
        return noErr
    }
    private nonisolated static let cmioListenerProc: CMIOObjectPropertyListenerProc = { _, count, addresses, clientData in
        guard let clientData else { return noErr }
        let monitor = Unmanaged<CameraMicMonitor>.fromOpaque(clientData).takeUnretainedValue()
        let listChanged = UnsafeBufferPointer(start: addresses, count: Int(count))
            .contains { $0.mSelector == CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices) }
        DispatchQueue.main.async {
            listChanged ? monitor.deviceListChanged() : monitor.poll()
        }
        return noErr
    }

    var isActive: Bool { cameraActive || micActive }

    /// Playing now, or within the linger window — so pausing music doesn't
    /// swallow the resume button. (Apple keeps Now Playing for the paused
    /// session via private API; the linger is the honest approximation.)
    var mediaRelevant: Bool {
        audioOutputActive || Date().timeIntervalSince(lastAudioActiveAt) < 300
    }

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        // Fallback only: catches the media-linger window expiring (a pure
        // wall-clock transition no listener fires for) and any missed
        // listener delivery. Generous tolerance = coalesced wakeups.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer?.tolerance = 5
        installListeners()
        poll()
    }

    // stop() is the normal teardown (ExtrasManager removes the entry);
    // deinit is the guard rail — a release without stop() would leave the
    // HAL dispatching to a dangling clientData pointer. The timer is left
    // to its weak-self no-op (invalidating cross-thread from deinit is
    // unsafe); the HAL pointer is the real hazard.
    deinit {
        Self.removeCListeners(
            selfPtr: Unmanaged.passUnretained(self).toOpaque(),
            audioDevices: audioListenerDevices,
            cmioDevices: cmioListenerDevices
        )
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        removeListeners()
    }

    /// Device topology changed (hot-plug) — re-install the per-device
    /// listeners. Running-state changes skip this and go straight to poll().
    private func deviceListChanged() {
        removeListeners()
        installListeners()
        poll()
    }

    private func installListeners() {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // System object: device list changes (hot-plug).
        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, Self.audioListenerProc, selfPtr
        )
        for deviceID in Self.allAudioDeviceIDs() {
            if AudioObjectAddPropertyListener(deviceID, &runningAddress, Self.audioListenerProc, selfPtr) == noErr {
                audioListenerDevices.append(deviceID)
            }
        }

        var cmioRunning = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var cmioDevices = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        CMIOObjectAddPropertyListener(
            CMIOObjectID(kCMIOObjectSystemObject), &cmioDevices, Self.cmioListenerProc, selfPtr
        )
        for deviceID in Self.allCMIODeviceIDs() {
            if CMIOObjectAddPropertyListener(deviceID, &cmioRunning, Self.cmioListenerProc, selfPtr) == noErr {
                cmioListenerDevices.append(deviceID)
            }
        }
    }

    private func removeListeners() {
        Self.removeCListeners(
            selfPtr: Unmanaged.passUnretained(self).toOpaque(),
            audioDevices: audioListenerDevices,
            cmioDevices: cmioListenerDevices
        )
        audioListenerDevices = []
        cmioListenerDevices = []
    }

    /// Static + nonisolated so deinit can reach it: removal matches by
    /// (proc, clientData) identity, so it needs only the pointer and the
    /// device lists — not isolated state access.
    private nonisolated static func removeCListeners(
        selfPtr: UnsafeMutableRawPointer,
        audioDevices: [AudioObjectID],
        cmioDevices cmioDeviceList: [CMIOObjectID]
    ) {
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, Self.audioListenerProc, selfPtr
        )
        for deviceID in audioDevices {
            AudioObjectRemovePropertyListener(deviceID, &runningAddress, Self.audioListenerProc, selfPtr)
        }

        var cmioRunning = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var cmioDevices = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        CMIOObjectRemovePropertyListener(
            CMIOObjectID(kCMIOObjectSystemObject), &cmioDevices, Self.cmioListenerProc, selfPtr
        )
        for deviceID in cmioDeviceList {
            CMIOObjectRemovePropertyListener(deviceID, &cmioRunning, Self.cmioListenerProc, selfPtr)
        }
    }

    private static func allAudioDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }
        var deviceIDs = [AudioObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }
        return deviceIDs
    }

    private static func allCMIODeviceIDs() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }
        var deviceIDs = [CMIOObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<CMIOObjectID>.size)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, dataSize, &dataUsed, &deviceIDs
        ) == noErr else { return [] }
        return deviceIDs
    }

    private func poll() {
        let camera = Self.anyCameraRunning()
        let mic = Self.anyMicRunning()
        let audio = Self.anyOutputRunning()
        if audio { lastAudioActiveAt = Date() }
        let relevantNow = mediaRelevant
        if camera != cameraActive || mic != micActive || audio != audioOutputActive
            || relevantNow != lastMediaRelevant {
            cameraActive = camera
            micActive = mic
            audioOutputActive = audio
            lastMediaRelevant = relevantNow
            onChange()
        }
    }

    private var lastMediaRelevant = true

    private static func anyOutputRunning() -> Bool {
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
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
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
