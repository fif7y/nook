// MenuBarPolicy.swift
// Identity and policy tables shared by the engine and the app UI. These lived
// as statics on the engine actor, which made the UI import engine internals
// and left ConvergePlan depending on the actor type it is meant to be
// independent of.

import CoreGraphics
import Foundation

public enum NookBundle {
    /// Nook's bundle id where Bundle.main has none (unit tests, probes).
    public static let fallbackID = "app.fif7y.Nook"
    public static let agentID = "com.apple.MenuBarAgent"
    /// The one canonical "Nook's own bundle id" (A10): Bundle.main's, with
    /// the fallback for hosts that have none. Use this — never hand-roll the
    /// `??` (or forget it, as one comparison site did).
    public static let mainID = Bundle.main.bundleIdentifier ?? fallbackID
}

/// The 9 system items macOS 27's assessment configuration can individually
/// allow (raw MBSystemItemIdentifier values). Anything not allowed is hidden
/// while an assertion is active.
public enum SystemItem: Int, CaseIterable, Sendable {
    case battery = 0
    case bluetooth = 1
    case clock = 2
    case displays = 3
    case keyboard = 4
    case volume = 5
    case wifi = 6
    case screenMirroring = 7
    /// Control Center ("bento box" is its internal name). Deliberately
    /// unmapped in systemItem(for:) — the agent keeps Control Center visible
    /// under any assertion regardless of allowlist (verified fc3f64c: the
    /// identifier space truly stops at 8; CC-pinned modules collateral-hide,
    /// CC itself never does). Kept to document the raw MBSystemItemIdentifier
    /// range, not to be produced.
    case primaryBentoBox = 8
}

public enum MenuBarPolicy {
    /// Core system items ARE controllable via the assertion's system-item
    /// allowlist — map their menuextra identifiers to MBSystemItemIdentifier.
    public static func systemItem(for id: ItemID) -> SystemItem? {
        let raw = id.rawValue
        guard raw.contains("::com.apple.menuextra.") else { return nil }
        if raw.hasSuffix(".sound") { return .volume }
        if raw.hasSuffix(".battery") { return .battery }
        if raw.hasSuffix(".wifi") { return .wifi }
        if raw.hasSuffix(".clock") { return .clock }
        if raw.hasSuffix(".bluetooth") { return .bluetooth }
        if raw.hasSuffix(".display") || raw.hasSuffix(".displays") { return .displays }
        if raw.hasSuffix(".textinput") || raw.hasSuffix(".keyboard") { return .keyboard }
        if raw.hasSuffix(".screen-mirroring") { return .screenMirroring }
        return nil
    }

    /// Bundles whose items legitimately mix live and hidden — never subject
    /// to tag-drift pruning (Nook's own items; the agent's per-identifier
    /// system items).
    public static func identityExemptBundles(nookBundleID: String) -> Set<String> {
        [nookBundleID, NookBundle.agentID]
    }

    /// True for Nook-owned proxy/extra items (NOT the chevron): they're
    /// section-manageable through their own visibility. Separators included —
    /// they live in sections and hide with them, extras-style.
    public static func isNookExtraID(_ id: ItemID) -> Bool {
        let raw = id.rawValue
        return raw.contains("::Nook.")
            && !raw.contains("Nook.StatusItem")
    }

    /// Apple bundle that is NOT manageable as a third-party item — only the
    /// menuextra → SystemItem allowlist can touch it (or nothing can).
    /// SystemUIServer's Siri icon deliberately stays out of scope: the
    /// assertion CAN hide it (bundle-allowlist governed, verified live
    /// 2026-08-21), but the agent hard-pins its position — plist slots and
    /// synthetic ⌘-drags are both ignored — and an editor tile that ignores
    /// placement breaks the editor's promise. macOS's own Siri setting
    /// already covers show/hide.
    public static func isUnmanagedAppleBundle(_ bundle: String?) -> Bool {
        bundle?.hasPrefix("com.apple.") == true
    }
}

/// Menubar band geometry in CG top-left global coordinates.
public enum MenuBarGeometry {
    public static let bandTopInset: CGFloat = -5
    public static let bandBottomLimit: CGFloat = 50

    /// True when a frame sits in the main display's menubar band. Frames from
    /// other displays carry their own coordinate origins and fall outside.
    public static func isInBand(_ frame: CGRect) -> Bool {
        frame.minY > bandTopInset && frame.minY < bandBottomLimit
    }
}
