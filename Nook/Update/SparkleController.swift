// SparkleController.swift
// Sparkle 2 updater. Disabled until a real EdDSA public key lands in
// Info.plist (SUPublicEDKey) — starting the updater with the placeholder
// would surface signature errors on every automatic check.
//
// Hybrid update UI: availability renders INLINE in the About pane (silent
// probe via checkForUpdateInformation → observable `status`); Sparkle's
// standard windows handle only the actual install — download, extract,
// relaunch — the part not worth reimplementing.

import AppKit
import NookEngine
import Sparkle

@MainActor
@Observable
final class SparkleController: NSObject {
    static let shared = SparkleController()

    enum UpdateStatus: Equatable {
        case unknown
        case checking
        case upToDate
        case available(version: String)
    }

    /// What the About pane renders. Fed by the silent probe AND by Sparkle's
    /// scheduled automatic checks (same delegate).
    private(set) var status: UpdateStatus = .unknown

    private var controller: SPUStandardUpdaterController?

    /// True once Info.plist carries a real Sparkle public key. The About
    /// pane hides its update button entirely in unconfigured dev builds.
    var isConfigured: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else { return false }
        return !key.isEmpty && !key.hasPrefix("REPLACE")
    }

    func start() {
        guard controller == nil else { return }
        guard isConfigured else {
            NookLog.log("sparkle: no EdDSA public key in Info.plist — updater disabled")
            return
        }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        NookLog.log("sparkle: updater started, feed=\(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "?")")
    }

    /// Silent availability probe — no UI, no download. About calls this on
    /// appear; the result lands in `status`.
    func probe() {
        start()
        guard let controller else { return }
        guard status != .checking else { return }
        // Sparkle throttles checkForUpdateInformation by the scheduled-check
        // interval; a fresh probe per About-open is what we want, so bypass
        // is not needed — an update found by ANY check updates status.
        status = .checking
        controller.updater.checkForUpdateInformation()
    }

    /// The install flow — Sparkle's standard windows take over from here.
    /// (No explicit lower here: the user-driver delegate below yields the
    /// settings window for EVERY Sparkle window, scheduled checks included.)
    func checkForUpdates() {
        start()
        guard let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

extension SparkleController: SPUStandardUserDriverDelegate {
    /// Sparkle's windows come up at normal level — the floating settings
    /// window buries them. This fires for every presentation path (manual
    /// check AND the scheduled automatic check, which bypasses
    /// checkForUpdates() entirely — the 0.1.2 lower-on-click fix missed it).
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        Task { @MainActor in SettingsWindowController.shared.lowerForSystemPrompt() }
    }

    nonisolated func standardUserDriverWillShowModalAlert() {
        Task { @MainActor in SettingsWindowController.shared.lowerForSystemPrompt() }
    }
}

extension SparkleController: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in
            self.status = .available(version: version)
            NookLog.log("sparkle: update available \(version)")
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.status = .upToDate }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Offline / feed unreachable: don't claim up-to-date, just stop
        // showing "checking". (A found-update abort keeps its status.)
        Task { @MainActor in
            if self.status == .checking { self.status = .unknown }
        }
    }
}
