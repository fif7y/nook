// SparkleController.swift
// Sparkle 2 updater. Disabled until a real EdDSA public key lands in
// Info.plist (SUPublicEDKey) — starting the updater with the placeholder
// would surface signature errors on every automatic check.

import AppKit
import NookEngine
import Sparkle

@MainActor
final class SparkleController {
    static let shared = SparkleController()

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
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        NookLog.log("sparkle: updater started, feed=\(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "?")")
    }

    func checkForUpdates() {
        start()
        guard let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        // The update window lands at normal level — the floating settings
        // window would bury it.
        SettingsWindowController.shared.lowerForSystemPrompt()
        controller.checkForUpdates(nil)
    }
}
