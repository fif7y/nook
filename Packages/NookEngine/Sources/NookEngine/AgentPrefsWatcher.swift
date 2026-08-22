// AgentPrefsWatcher.swift
// Watches com.apple.MenuBarAgent.plist so native ⌘-drags (and the agent's own
// re-interpolations) are ADOPTED into Nook's model instead of corrected.
// Debounced; suppresses events caused by our own writes.

import Foundation

final class AgentPrefsWatcher: @unchecked Sendable {
    private let plistURL: URL
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private let queue = DispatchQueue(label: "nook.agent-prefs-watcher")
    private var debounceWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var suppressUntil: Date = .distantPast
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        self.plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.MenuBarAgent.plist")
    }

    func start() {
        queue.sync { openSource() }
    }

    func stop() {
        queue.sync { closeSource() }
    }

    /// Call right before a self-write; changes within the window are ignored.
    func suppress(for interval: TimeInterval = 1.5) {
        queue.sync { suppressUntil = Date().addingTimeInterval(interval) }
    }

    // MARK: - Internals (all on `queue`)

    private func openSource() {
        closeSource()
        descriptor = open(plistURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // The plist can be momentarily absent (cfprefsd's atomic replace
            // mid-reopen, or a fresh account before the agent's first write).
            // A silent bail here killed external-order adoption for the whole
            // session — keep retrying quietly instead.
            NookLog.log("prefsWatcher: plist unavailable — retrying in 5s")
            let work = DispatchWorkItem { [weak self] in self?.openSource() }
            retryWork = work
            queue.asyncAfter(deadline: .now() + 5, execute: work)
            return
        }
        retryWork?.cancel()
        retryWork = nil
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            // cfprefsd replaces the file atomically: reopen on delete/rename.
            if events.contains(.delete) || events.contains(.rename) {
                self.openSource()
            }
            self.scheduleNotify()
        }
        source.setCancelHandler { [descriptor] in
            if descriptor >= 0 { close(descriptor) }
        }
        source.resume()
        self.source = source
    }

    private func closeSource() {
        retryWork?.cancel()
        retryWork = nil
        source?.cancel()
        source = nil
        descriptor = -1
    }

    private func scheduleNotify() {
        guard Date() >= suppressUntil else { return }
        debounceWork?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        debounceWork = work
        // Settle window: agent reflows write in bursts.
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
