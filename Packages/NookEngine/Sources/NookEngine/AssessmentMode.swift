// AssessmentMode.swift
// Swift face of the MenuBarClientCore shim. The engine's hide/show primitive.

import Foundation
import NookEngineObjC

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
    case primaryBentoBox = 8
}

/// One active hide state. Process-bound: dropping the instance (or the app
/// crashing) restores the menu bar — macOS invalidates the assertion itself.
public final class AssessmentAssertion {
    private let handle: AnyObject

    fileprivate init(handle: AnyObject) {
        self.handle = handle
    }

    public func invalidate() {
        nook_invalidateAssertion(handle)
    }
}

public enum AssessmentMode {
    /// Whether MenuBarClientCore resolved on this OS build. Re-check on app
    /// activation; a 27.x update can remove the private API.
    public static var isAvailable: Bool {
        nook_assessmentModeAvailable()
    }

    /// Probe-only: the runtime method surface of the private classes.
    public static var apiDescription: String {
        nook_describeAssessmentClasses()
    }

    /// Activates an assertion that keeps only `systemItems` and `bundleIDs`
    /// visible; every other item is hidden and the bar reflows.
    public static func activate(
        allowing systemItems: [SystemItem] = SystemItem.allCases,
        bundleIDs: [String],
        completion: @escaping @Sendable (Error?) -> Void
    ) -> AssessmentAssertion? {
        let config = nook_makeConfiguration(
            systemItems.map { NSNumber(value: $0.rawValue) },
            bundleIDs
        )
        guard let config else { return nil }
        guard let handle = nook_activateAssertion(config, { completion($0) }) else {
            return nil
        }
        return AssessmentAssertion(handle: handle as AnyObject)
    }
}
