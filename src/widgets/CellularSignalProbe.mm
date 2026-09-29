//
//  CellularSignalProbe.mm
//  Helium
//
//  RSRP via CoreTelephony's private XPC client.
//
//  ## Why this is not a one-liner
//
//  Two things stand between a status-bar widget and one number:
//
//    * `CoreTelephonyClient` is a private class, and Helium links no part of
//      CoreTelephony. Nothing has loaded the framework, so
//      `NSClassFromString(@"CoreTelephonyClient")` returns Nil until something
//      dlopen()s it. (Same shape as the IOReport lookup in the CPU temperature
//      widget next door.)
//
//    * The call is gated by `com.apple.CommCenter.fine-grained`. Without it,
//      CommCenter refuses the connection and the method returns nil with an
//      error. There is no crash and no log — the widget would just sit there
//      showing its placeholder forever. That is why this file also reports the
//      probe's own state rather than only the number.
//
//  Everything is resolved at runtime, so a renamed or removed private class
//  degrades to "no reading" instead of failing to link or crashing.
//
//  Reference: DevelopCubeLab/CellularInfo (GPL-3.0), which does the same thing
//  in Swift and ships class-dump headers for the framework. The call shape here
//  matches Controller/CoreTelephonyController.swift:
//
//      let descriptor = getServiceDescriptor(slotID:)
//      let measurements = try client.getSignalStrengthMeasurements(descriptor)
//      measurements?.rsrp?.stringValue
//

#import "CellularSignalProbe.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

/// Probe states, as plain C strings — see the header.
static const char *const kStatePending     = "pending";
static const char *const kStateOK          = "ok";
static const char *const kStateUnavailable = "unavailable";

static const char *gSignalState = kStatePending;

static void *gCTHandle = NULL;
static BOOL gCTResolved = NO;
static id gCTClient = nil;

/// The one `CoreTelephonyClient` instance, created on first use.
///
/// Kept alive for the process: the object owns an XPC connection to CommCenter,
/// and making a new one per sample would be both wasteful and noisier for
/// CommCenter. Returns nil when the class cannot be reached at all.
static id ctClient(void)
{
    if (gCTResolved) {
        return gCTClient;
    }
    gCTResolved = YES;

    // Helium links no part of CoreTelephony, so the framework is probably not
    // loaded yet. dlopen() it; fall back to the default namespace in case
    // something else already pulled it in.
    gCTHandle = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony",
                       RTLD_LAZY);
    if (gCTHandle == NULL) {
        gCTHandle = RTLD_DEFAULT;
    }

    Class clientClass = NSClassFromString(@"CoreTelephonyClient");
    if (clientClass != Nil) {
        @try {
            // `-init`, not `-initWithQueue:`. See the class-dump header.
            gCTClient = [[clientClass alloc] init];
        } @catch (NSException *e) {
            gCTClient = nil;
        }
    }
    return gCTClient;
}

/// The `CTServiceDescriptor` for a slot, or nil.
///
/// `slot` 0 asks CoreTelephony which SIM is carrying data right now, which is
/// what a widget should follow by default — on a dual-SIM phone the user can
/// switch the data line without touching the widget.
static id serviceDescriptor(id client, int32_t slot)
{
    @try {
        if (slot <= 0) {
            SEL sel = NSSelectorFromString(@"getCurrentDataServiceDescriptorSync:");
            if (![client respondsToSelector:sel]) {
                return nil;
            }
            id (*send)(id, SEL, id *) = (id (*)(id, SEL, id *))objc_msgSend;
            return send(client, sel, NULL);
        }

        SEL sel = NSSelectorFromString(@"getDescriptorsForDomain:error:");
        if (![client respondsToSelector:sel]) {
            return nil;
        }
        id (*send)(id, SEL, long long, id *) = (id (*)(id, SEL, long long, id *))objc_msgSend;
        id container = send(client, sel, 1LL, NULL);

        NSArray *descriptors = [container valueForKey:@"descriptors"];
        if (![descriptors isKindOfClass:[NSArray class]]) {
            return nil;
        }
        // `instance` is the slot number (1 -> slot 1).
        for (id descriptor in descriptors) {
            if ([[descriptor valueForKey:@"instance"] integerValue] == slot) {
                return descriptor;
            }
        }
    } @catch (NSException *e) {
        // A private class that answers differently than expected — treat it the
        // same as "no descriptor" rather than letting the exception escape into
        // the HUD's render loop.
    }
    return nil;
}

int32_t helium_cellular_rsrp_dbm(int32_t slot)
{
    @autoreleasepool {
        id client = ctClient();
        if (client == nil) {
            gSignalState = kStateUnavailable;
            return 0;
        }

        id descriptor = serviceDescriptor(client, slot);
        if (descriptor == nil) {
            gSignalState = kStateUnavailable;
            return 0;
        }

        SEL sel = NSSelectorFromString(@"getSignalStrengthMeasurements:error:");
        if (![client respondsToSelector:sel]) {
            gSignalState = kStateUnavailable;
            return 0;
        }

        id (*send)(id, SEL, id, NSError **) = (id (*)(id, SEL, id, NSError **))objc_msgSend;
        NSError *error = nil;
        id measurements = nil;
        @try {
            measurements = send(client, sel, descriptor, &error);
        } @catch (NSException *e) {
            gSignalState = kStateUnavailable;
            return 0;
        }

        if (measurements == nil || error != nil) {
            // Exactly the silent case: no entitlement, no service, or CommCenter
            // restarting. Nothing to log — the state is the message.
            gSignalState = kStateUnavailable;
            return 0;
        }

        NSNumber *rsrp = nil;
        @try {
            rsrp = [measurements valueForKey:@"rsrp"];
        } @catch (NSException *e) {
            rsrp = nil;
        }
        if (![rsrp isKindOfClass:[NSNumber class]]) {
            gSignalState = kStateUnavailable;
            return 0;
        }

        // RSRP is a negative dBm figure (roughly -44 … -140). Zero or positive
        // means "no reading" — some devices report 0 while there is no service,
        // and 0 is the sentinel this API uses for that.
        NSInteger value = rsrp.integerValue;
        if (value >= 0) {
            gSignalState = kStateUnavailable;
            return 0;
        }

        gSignalState = kStateOK;
        return (int32_t)value;
    }
}

const char *helium_cellular_signal_state(void)
{
    return gSignalState;
}
