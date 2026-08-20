// MBAssessmentShim.m
#import "include/MBAssessmentShim.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

static Class _configClass;
static Class _assertionClass;
static BOOL _loaded;

static void nook_load(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Apple platform binary in the dyld shared cache — dlopen by framework
        // path resolves it without any entitlement.
        void *handle = dlopen(
            "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore",
            RTLD_LAZY);
        if (handle == NULL) {
            return;
        }
        _configClass = NSClassFromString(@"MBAssessmentModeConfiguration");
        _assertionClass = NSClassFromString(@"MBAssessmentModeAssertion");
        _loaded = (_configClass != Nil && _assertionClass != Nil);
    });
}

BOOL nook_assessmentModeAvailable(void) {
    nook_load();
    return _loaded;
}

static void nook_appendMethods(NSMutableString *out, Class cls, BOOL classMethods) {
    unsigned int count = 0;
    Class target = classMethods ? object_getClass(cls) : cls;
    Method *methods = class_copyMethodList(target, &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        const char *types = method_getTypeEncoding(methods[i]);
        [out appendFormat:@"  %@%@  [%s]\n", classMethods ? @"+" : @"-",
                          NSStringFromSelector(sel), types ?: "?"];
    }
    free(methods);
}

NSString *nook_describeAssessmentClasses(void) {
    nook_load();
    NSMutableString *out = [NSMutableString string];
    if (!_loaded) {
        [out appendString:@"MenuBarClientCore: classes NOT resolved\n"];
        return out;
    }
    for (Class cls in @[ _configClass, _assertionClass ]) {
        [out appendFormat:@"%@ (superclass %@)\n", NSStringFromClass(cls),
                          NSStringFromClass(class_getSuperclass(cls))];
        nook_appendMethods(out, cls, YES);
        nook_appendMethods(out, cls, NO);
        unsigned int pcount = 0;
        objc_property_t *props = class_copyPropertyList(cls, &pcount);
        for (unsigned int i = 0; i < pcount; i++) {
            [out appendFormat:@"  @property %s  [%s]\n",
                              property_getName(props[i]),
                              property_getAttributes(props[i]) ?: "?"];
        }
        free(props);
        [out appendString:@"\n"];
    }
    return out;
}

id nook_makeConfiguration(NSArray<NSNumber *> *allowedSystemItems,
                          NSArray<NSString *> *allowedBundleIDs) {
    nook_load();
    if (!_loaded) {
        return nil;
    }
    @try {
        SEL initSel = NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:");
        if (![_configClass instancesRespondToSelector:initSel]) {
            return nil;
        }
        id alloced = [_configClass alloc];
        id (*initMsg)(id, SEL, NSArray *, NSArray *) = (void *)objc_msgSend;
        return initMsg(alloced, initSel, allowedSystemItems, allowedBundleIDs);
    } @catch (NSException *e) {
        NSLog(@"[MBAssessmentShim] makeConfiguration raised: %@", e);
        return nil;
    }
}

id nook_activateAssertion(id configuration,
                          void (^completion)(NSError *_Nullable)) {
    nook_load();
    if (!_loaded || configuration == nil) {
        return nil;
    }
    @try {
        // Verified on 27.0 (26A5416b) via runtime introspection: the assertion
        // is a plain-init instance activated with
        // -activateWithConfiguration:completionHandler: (void return).
        SEL activateSel = NSSelectorFromString(@"activateWithConfiguration:completionHandler:");
        if ([_assertionClass instancesRespondToSelector:activateSel]) {
            id assertion = [[_assertionClass alloc] init];
            if (assertion == nil) {
                return nil;
            }
            void (*activateMsg)(id, SEL, id, void (^)(NSError *)) = (void *)objc_msgSend;
            activateMsg(assertion, activateSel, configuration, completion);
            return assertion;
        }
        NSLog(@"[MBAssessmentShim] no known activation selector on %@", _assertionClass);
        return nil;
    } @catch (NSException *e) {
        NSLog(@"[MBAssessmentShim] activateAssertion raised: %@", e);
        return nil;
    }
}

void nook_invalidateAssertion(id assertion) {
    if (assertion == nil) {
        return;
    }
    @try {
        SEL invalidateSel = NSSelectorFromString(@"invalidate");
        if ([assertion respondsToSelector:invalidateSel]) {
            void (*invalidateMsg)(id, SEL) = (void *)objc_msgSend;
            invalidateMsg(assertion, invalidateSel);
        }
    } @catch (NSException *e) {
        NSLog(@"[MBAssessmentShim] invalidate raised: %@", e);
    }
}
