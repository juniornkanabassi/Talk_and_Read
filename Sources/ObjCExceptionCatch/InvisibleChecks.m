// Opt-in counterpart of the unchanged TestOffscreen guard for real-app checks. Normal launches are untouched.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "ObjCExceptionCatch.h"

static void swap(Class type, SEL original, SEL replacement) {
  Method old = class_getInstanceMethod(type, original), new = class_getInstanceMethod(type, replacement);
  if (!old || !new) return;
  if (class_addMethod(type, original, method_getImplementation(new), method_getTypeEncoding(new)))
    class_replaceMethod(type, replacement, method_getImplementation(old), method_getTypeEncoding(old));
  else
    method_exchangeImplementations(old, new);
}

@implementation NSWindow (TRInvisibleChecks)
- (void)trInvisibleChecks_hide { [self trInvisibleChecks_setAlphaValue:0]; self.ignoresMouseEvents = YES; }
- (void)trInvisibleChecks_setAlphaValue:(CGFloat)value { [self trInvisibleChecks_setAlphaValue:0]; }
- (void)trInvisibleChecks_orderWindow:(NSWindowOrderingMode)mode relativeTo:(NSInteger)other {
  [self trInvisibleChecks_hide]; [self trInvisibleChecks_orderWindow:mode relativeTo:other];
}
- (void)trInvisibleChecks_orderFront:(id)sender { [self trInvisibleChecks_hide]; [self trInvisibleChecks_orderFront:sender]; }
- (void)trInvisibleChecks_orderFrontRegardless { [self trInvisibleChecks_hide]; [self trInvisibleChecks_orderFrontRegardless]; }
- (void)trInvisibleChecks_makeKeyAndOrderFront:(id)sender { [self trInvisibleChecks_hide]; [self trInvisibleChecks_makeKeyAndOrderFront:sender]; }
@end

@implementation NSApplication (TRInvisibleChecks)
- (void)trInvisibleChecks_activateIgnoringOtherApps:(BOOL)flag {}
- (void)trInvisibleChecks_activate {}
@end

void TRInstallInvisibleChecks(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    BOOL enabled = NSProcessInfo.processInfo.environment[@"XCTestConfigurationFilePath"] != nil;
    for (NSString *arg in args) enabled |= [arg isEqualToString:@"--agent-screen"] || [arg hasPrefix:@"--selftest-"];
    if (!enabled) return;
    Class window = NSWindow.class, app = NSApplication.class;
    swap(window, @selector(setAlphaValue:), @selector(trInvisibleChecks_setAlphaValue:));
    swap(window, @selector(orderWindow:relativeTo:), @selector(trInvisibleChecks_orderWindow:relativeTo:));
    swap(window, @selector(orderFront:), @selector(trInvisibleChecks_orderFront:));
    swap(window, @selector(orderFrontRegardless), @selector(trInvisibleChecks_orderFrontRegardless));
    swap(window, @selector(makeKeyAndOrderFront:), @selector(trInvisibleChecks_makeKeyAndOrderFront:));
    swap(app, @selector(activateIgnoringOtherApps:), @selector(trInvisibleChecks_activateIgnoringOtherApps:));
    swap(app, @selector(activate), @selector(trInvisibleChecks_activate));
  });
}

// Hosted XCTest must be protected before the app's own early windows, not only when its test bundle loads.
__attribute__((constructor)) static void installInvisibleChecksEarly(void) { TRInstallInvisibleChecks(); }
