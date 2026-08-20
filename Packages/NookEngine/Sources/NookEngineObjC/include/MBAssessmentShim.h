// MBAssessmentShim.h
// Clean-room bridge to the private MenuBarClientCore.framework assessment-mode
// API on macOS 27. Everything here is resolved at runtime (dlopen +
// NSClassFromString) and wrapped in @try/@catch: if Apple changes the API in a
// point release, calls fail soft and `nook_assessmentModeAvailable` returns NO.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Loads MenuBarClientCore.framework and resolves the assessment-mode classes.
/// Safe to call repeatedly; caches the result.
BOOL nook_assessmentModeAvailable(void);

/// Introspection: method lists + type encodings of the assessment classes.
/// Probe-only; lets us verify the API surface on the running OS build.
NSString *nook_describeAssessmentClasses(void);

/// Creates an MBAssessmentModeConfiguration allowing the given system items
/// (raw MBSystemItemIdentifier values 0–8) and third-party bundle identifiers.
/// Everything NOT listed gets hidden while an assertion is active.
/// Returns nil if unavailable or the initializer signature changed.
id _Nullable nook_makeConfiguration(NSArray<NSNumber *> *allowedSystemItems,
                                    NSArray<NSString *> *allowedBundleIDs);

/// Activates an assertion for the configuration. The completion fires
/// asynchronously with nil on success or the underlying error.
/// Returns the assertion handle (retain it; it is process-bound), or nil if
/// activation could not even be attempted.
id _Nullable nook_activateAssertion(id configuration,
                                    void (^completion)(NSError *_Nullable error));

/// Invalidates a previously activated assertion, restoring the menu bar.
void nook_invalidateAssertion(id _Nullable assertion);

NS_ASSUME_NONNULL_END
