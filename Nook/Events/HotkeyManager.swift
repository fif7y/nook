// HotkeyManager.swift
// One global hotkey via Carbon RegisterEventHotKey — works without Input
// Monitoring, sandboxes fine, survives Secure Input better than event taps.

import Carbon.HIToolbox
import Foundation
import NookCore

final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onTrigger: () -> Void

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    // No deinit: the manager lives for the app's lifetime (owned by AppState);
    // register(_:) unregisters the previous hotkey on every change.

    func register(_ spec: HotkeySpec?) {
        unregister()
        guard let spec else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { manager.onTrigger() }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &handlerRef
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x4E4F4F4B) /* NOOK */, id: 1)
        RegisterEventHotKey(
            spec.keyCode,
            spec.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}
