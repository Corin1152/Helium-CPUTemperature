//
//  WidgetManager.m
//  
//
//  Created by lemin on 10/6/23.
//

#import <Foundation/Foundation.h>
#import <net/if.h>
#import <ifaddrs.h>
#import <sys/wait.h>
#import <sys/types.h>
#import <sys/sysctl.h>
#import <objc/runtime.h>
#import "WidgetManager.h"
#import <IOKit/IOKitLib.h>
#import "../extensions/LunarDate.h"
#import "../extensions/FontUtils.h"
#import "../extensions/WeatherUtils.h"

// Thanks to: https://github.com/lwlsw/NetworkSpeed13

#define KILOBITS 1000
#define MEGABITS 1000000
#define GIGABITS 1000000000
#define KILOBYTES (1 << 10)
#define MEGABYTES (1 << 20)
#define GIGABYTES (1 << 30)
#define SHOW_ALWAYS 1
// #define INLINE_SEPARATOR "\t"

// #pragma mark - Formatting Methods
// static unsigned char getSeparator(NSMutableAttributedString *currentAttributed)
// {
//     return [[currentAttributed string] isEqualToString:@""] ? *"" : *"\t";
// }

#pragma mark - Widget-specific Variables
// MARK: 0 - Date Widget
static NSDateFormatter *formatter = nil;

// MARK: Net Speed Widget
static uint8_t DATAUNIT = 0;

typedef struct {
    uint64_t inputBytes;
    uint64_t outputBytes;
} UpDownBytes;

static uint64_t prevOutputBytes = 0, prevInputBytes = 0;
static NSAttributedString *attributedUploadPrefix = nil;
static NSAttributedString *attributedDownloadPrefix = nil;
static NSAttributedString *attributedUploadPrefix2 = nil;
static NSAttributedString *attributedDownloadPrefix2 = nil;

#pragma mark - Date Widget
static NSString* formattedDate(NSString *dateFormat, NSString *dateLocale)
{
    if (!formatter) {
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:dateLocale];
    }
    NSDate *currentDate = [NSDate date];
    NSString *newDateFormat = [LunarDate getChineseCalendarWithDate:currentDate format:dateFormat];
    [formatter setDateFormat:newDateFormat];
    return [formatter stringFromDate:currentDate];
}

#pragma mark - Net Speed Widgets
static UpDownBytes getUpDownBytes()
{
    struct ifaddrs *ifa_list = 0, *ifa;
    UpDownBytes upDownBytes;
    upDownBytes.inputBytes = 0;
    upDownBytes.outputBytes = 0;
    
    if (getifaddrs(&ifa_list) == -1) return upDownBytes;

    for (ifa = ifa_list; ifa; ifa = ifa->ifa_next)
    {
        /* Skip invalid interfaces */
        if (ifa->ifa_name == NULL || ifa->ifa_addr == NULL || ifa->ifa_data == NULL)
            continue;
        
        /* Skip interfaces that are not link level interfaces */
        if (AF_LINK != ifa->ifa_addr->sa_family)
            continue;

        /* Skip interfaces that are not up or running */
        if (!(ifa->ifa_flags & IFF_UP) && !(ifa->ifa_flags & IFF_RUNNING))
            continue;
        
        /* Skip interfaces that are not ethernet or cellular */
        if (strncmp(ifa->ifa_name, "en", 2) && strncmp(ifa->ifa_name, "pdp_ip", 6))
            continue;
        
        struct if_data *if_data = (struct if_data *)ifa->ifa_data;
        
        upDownBytes.inputBytes += if_data->ifi_ibytes;
        upDownBytes.outputBytes += if_data->ifi_obytes;
    }
    
    freeifaddrs(ifa_list);
    return upDownBytes;
}

static NSString* formattedSpeed(uint64_t bytes, NSInteger minUnit)
{
    if (0 == DATAUNIT) {
        // Get min units first
        if (minUnit == 1 && bytes < KILOBYTES) return @"0 KB/s";
        else if (minUnit == 2 && bytes < MEGABYTES) return @"0 MB/s";
        else if (minUnit == 3 && bytes < GIGABYTES) return @"0 GB/s";

        if (bytes < KILOBYTES) return [NSString stringWithFormat:@"%.0f B/s", (double)bytes];
        else if (bytes < MEGABYTES) return [NSString stringWithFormat:@"%.0f KB/s", (double)bytes / KILOBYTES];
        else if (bytes < GIGABYTES) return [NSString stringWithFormat:@"%.2f MB/s", (double)bytes / MEGABYTES];
        else return [NSString stringWithFormat:@"%.2f GB/s", (double)bytes / GIGABYTES];
    } else {
        // Get min units first
        if (minUnit == 1 && bytes < KILOBITS) return @"0 Kb/s";
        else if (minUnit == 2 && bytes < MEGABITS) return @"0 Mb/s";
        else if (minUnit == 3 && bytes < GIGABITS) return @"0 Gb/s";

        if (bytes < KILOBITS) return [NSString stringWithFormat:@"%.0f b/s", (double)bytes];
        else if (bytes < MEGABITS) return [NSString stringWithFormat:@"%.0f Kb/s", (double)bytes / KILOBITS];
        else if (bytes < GIGABITS) return [NSString stringWithFormat:@"%.2f Mb/s", (double)bytes / MEGABITS];
        else return [NSString stringWithFormat:@"%.2f Gb/s", (double)bytes / GIGABITS];
    }
}

static NSAttributedString* formattedAttributedSpeedString(BOOL isUp, NSInteger speedIcon, NSInteger minUnit, BOOL hideWhenZero, double fontSize)
{
    @autoreleasepool {
        if (!attributedUploadPrefix)
            attributedUploadPrefix = [[NSAttributedString alloc] initWithString:[[NSString stringWithUTF8String:"▲"] stringByAppendingString:@" "] attributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:fontSize]}];
        if (!attributedDownloadPrefix)
            attributedDownloadPrefix = [[NSAttributedString alloc] initWithString:[[NSString stringWithUTF8String:"▼"] stringByAppendingString:@" "] attributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:fontSize]}];
        if (!attributedUploadPrefix2)
            attributedUploadPrefix2 = [[NSAttributedString alloc] initWithString:[[NSString stringWithUTF8String:"↑"] stringByAppendingString:@" "] attributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:fontSize]}];
        if (!attributedDownloadPrefix2)
            attributedDownloadPrefix2 = [[NSAttributedString alloc] initWithString:[[NSString stringWithUTF8String:"↓"] stringByAppendingString:@" "] attributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:fontSize]}];
        
        NSMutableAttributedString* mutableString = [[NSMutableAttributedString alloc] init];
        
        UpDownBytes upDownBytes = getUpDownBytes();
        
        uint64_t diff;
        
        if (isUp) {
            if (upDownBytes.outputBytes > prevOutputBytes)
                diff = upDownBytes.outputBytes - prevOutputBytes;
            else
                diff = 0;
            prevOutputBytes = upDownBytes.outputBytes;
        } else {
            if (upDownBytes.inputBytes > prevInputBytes)
                diff = upDownBytes.inputBytes - prevInputBytes;
            else
                diff = 0;
            prevInputBytes = upDownBytes.inputBytes;
        }
        
        if (DATAUNIT == 1)
            diff *= 8;
        
        NSString *speedString = formattedSpeed(diff, minUnit);
        if (!hideWhenZero || ![speedString hasPrefix:@"0"]) {
            if (isUp)
                [mutableString appendAttributedString:(speedIcon == 0 ? attributedUploadPrefix : attributedUploadPrefix2)];
            else
                [mutableString appendAttributedString:(speedIcon == 0 ? attributedDownloadPrefix : attributedDownloadPrefix2)];
            [mutableString appendAttributedString:[[NSAttributedString alloc] initWithString:speedString]];
        }
        
        return [mutableString copy];
    }
}

#pragma mark - Battery Temp Widget
NSDictionary* getBatteryInfo()
{
    CFDictionaryRef matching = IOServiceMatching("IOPMPowerSource");
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, matching);
    CFMutableDictionaryRef prop = NULL;
    IORegistryEntryCreateCFProperties(service, &prop, NULL, 0);
    NSDictionary* dict = (__bridge_transfer NSDictionary*)prop;
    IOObjectRelease(service);
    return dict;
}

static NSString* formattedTemp(BOOL useFahrenheit)
{
    NSDictionary *batteryInfo = getBatteryInfo();
    if (batteryInfo) {
        // AdapterDetails.Watts.Description.Temperature
        double temp = [batteryInfo[@"Temperature"] doubleValue] / 100.0;
        if (temp) {
            if (useFahrenheit) {
                temp = (temp * 9.0/5.0) + 32;
                return [NSString stringWithFormat: @"%.2fºF", temp];
            } else {
                return [NSString stringWithFormat: @"%.2fºC", temp];
            }
        }
    }
    return @"??ºC";
}

#pragma mark - CPU Temp Widget (IOReport)
/*
 CPU/SoC die temperature is not exposed by any public API. It is published on the
 IOReport "CPU Die Temperature" channel group instead. IOReport lives inside
 IOKit.framework but its symbols are private, so they are resolved at runtime with
 dlopen/dlsym: if anything is unavailable the widget degrades to "??" instead of
 crashing the HUD.

 Entitlements required: com.apple.private.security.no-sandbox (already present in
 ent.plist). Without it IOReport returns nothing on jailed devices.
 */
#import <dlfcn.h>
#import <math.h>

typedef void *IORepSubRef;
typedef CFMutableDictionaryRef (*fn_IOReportCopyChannelsInGroup)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef CFMutableDictionaryRef (*fn_IOReportCopyAllChannels)(uint64_t, uint64_t);
typedef IORepSubRef (*fn_IOReportCreateSubscription)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*fn_IOReportCreateSamples)(IORepSubRef, CFMutableDictionaryRef, CFTypeRef);
typedef long (*fn_IOReportSimpleGetIntegerValue)(CFDictionaryRef, int);
typedef CFStringRef (*fn_IOReportChannelGetChannelName)(CFDictionaryRef);

static void *ioReportHandle = NULL;
static BOOL ioReportResolved = NO;
static fn_IOReportCopyChannelsInGroup pCopyChannelsInGroup = NULL;
static fn_IOReportCopyAllChannels pCopyAllChannels = NULL;
static fn_IOReportCreateSubscription pCreateSubscription = NULL;
static fn_IOReportCreateSamples pCreateSamples = NULL;
static fn_IOReportSimpleGetIntegerValue pSimpleGetIntegerValue = NULL;
static fn_IOReportChannelGetChannelName pChannelGetChannelName = NULL;

static int cpuTempRetryCountdown = 0;
static BOOL cpuTempSetupFailed = NO;

// How many times we are allowed to walk the candidate groups. Probing allocates
// an IOReport subscription per group and IOReport exposes no documented way to
// release one, so the budget keeps a permanently failing device from leaking
// a subscription every second.
static int cpuTempProbeBudget = 5;

// The group that worked, plus its subscription, reused on every later refresh.
static CFStringRef gActiveGroup = NULL;
static IORepSubRef gActiveSubscription = NULL;
static CFMutableDictionaryRef gActiveChannels = NULL;

#pragma mark - Temperature diagnostics

/* Builds a text report of every temperature source this device actually
   exposes. Shown in-app so the data can be read back without a debugger. */
static NSMutableString *gDiag = nil;
static BOOL gDiagDone = NO;

static double getCPUDieTemperature(void); // forward decl, run on demand

static void diagReset(void)
{
    @try {
        gDiagDone = NO;
        gDiag = [NSMutableString string];
        [gDiag appendString:@"=== Helium CPU Temperature Diagnostics ===\n"];
        [gDiag appendFormat:@"Device: %@ / iOS %@\n\n",
            [[UIDevice currentDevice] model], [[UIDevice currentDevice] systemVersion]];
    } @catch (NSException *e) { }
}

static void diagAdd(NSString *line)
{
    @try {
        if (!gDiag) return;
        [gDiag appendString:line];
        [gDiag appendString:@"\n"];
    } @catch (NSException *e) { }
}

// This file is compiled as Objective-C++ (WidgetManager.mm). Without an explicit
// C linkage the symbol gets name-mangled, and the plain Objective-C bridge
// (SwiftObjCPPBridger.m) then fails to link against it.
extern "C" NSString* HeliumTemperatureDiagnostics(void)
{
    @try {
        // The HUD renders in a separate process, so its report is not visible here.
        // The main app carries the same entitlements, so it simply probes itself.
        if (!gDiagDone) {
            (void)getCPUDieTemperature();
        }

        NSString *text = [gDiag length] > 0 ? [gDiag copy] : @"(diagnostics produced no output)";

        // This build is unsandboxed, so the report is also written out for anyone
        // who prefers to fetch it with a file browser.
        for (NSString *p in @[@"/var/mobile/Documents/HeliumTempDiag.txt",
                              @"/var/mobile/Media/Downloads/HeliumTempDiag.txt"]) {
            @try {
                [text writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
            } @catch (NSException *e) { }
        }
        return text;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"diagnostics failed: %@", e.reason];
    }
}

static BOOL ensureIOReportSymbols(void)
{
    if (ioReportResolved) {
        return (pCreateSamples != NULL && pSimpleGetIntegerValue != NULL);
    }
    ioReportResolved = YES;
    ioReportHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!ioReportHandle) {
        // IOKit is linked privately by the Makefile, so the symbols may already be
        // in the default namespace.
        ioReportHandle = RTLD_DEFAULT;
    }
    pCopyChannelsInGroup = (fn_IOReportCopyChannelsInGroup)dlsym(ioReportHandle, "IOReportCopyChannelsInGroup");
    pCopyAllChannels = (fn_IOReportCopyAllChannels)dlsym(ioReportHandle, "IOReportCopyAllChannels");
    pCreateSubscription = (fn_IOReportCreateSubscription)dlsym(ioReportHandle, "IOReportCreateSubscription");
    pCreateSamples = (fn_IOReportCreateSamples)dlsym(ioReportHandle, "IOReportCreateSamples");
    pSimpleGetIntegerValue = (fn_IOReportSimpleGetIntegerValue)dlsym(ioReportHandle, "IOReportSimpleGetIntegerValue");
    pChannelGetChannelName = (fn_IOReportChannelGetChannelName)dlsym(ioReportHandle, "IOReportChannelGetChannelName");
    return (pCreateSamples != NULL && pSimpleGetIntegerValue != NULL);
}

// forward declarations: the probe runs before these are defined
static double normalizeTemperature(long raw);
static BOOL findTemperatureInSamples(CFDictionaryRef node, long *outRaw, NSString **outName, int depth);

// Probe ONE channel group end to end: copy its channels, subscribe to just those,
// sample once and look for a temperature reading.
//
// Subscribing to the *entire* channel set (IOReportCopyAllChannels) is what the
// previous implementation did as a fallback, and it is unreliable: on older SoCs
// the subscription is refused and the widget silently degraded to "??". Probing
// groups one at a time keeps each subscription small and tells us which group
// actually worked.
static BOOL tryTemperatureGroup(CFStringRef group, double *outC, NSString **outName, BOOL keep)
{
    if (!pCopyChannelsInGroup || !pCreateSubscription || !pCreateSamples) return NO;

    CFMutableDictionaryRef channels = pCopyChannelsInGroup(group, NULL, 0, 0, 0);
    if (!channels) return NO;
    if (CFDictionaryGetCount(channels) == 0) {
        CFRelease(channels);
        return NO;
    }

    CFMutableDictionaryRef subbed = NULL;
    IORepSubRef sub = pCreateSubscription(NULL, channels, &subbed, 0, NULL);
    if (!sub) {
        CFRelease(channels);
        if (subbed) CFRelease(subbed);
        return NO;
    }

    // Only the channels actually subscribed to can be sampled.
    CFMutableDictionaryRef target = subbed ? subbed : channels;

    BOOL ok = NO;
    double c = NAN;
    NSString *hitName = nil;
    CFDictionaryRef samples = pCreateSamples(sub, target, NULL);
    if (samples) {
        long raw = 0;
        NSString *name = nil;
        if (findTemperatureInSamples(samples, &raw, &name, 0)) {
            c = normalizeTemperature(raw);
            if (!isnan(c)) {
                ok = YES;
                hitName = name;
            }
        }
        CFRelease(samples);
    }

    if (ok && keep) {
        // Keep this subscription alive and reuse it: IOReport has no documented
        // release, and CFRelease on it can crash the HUD.
        gActiveGroup = group;
        gActiveSubscription = sub;
        gActiveChannels = target;
        if (target != channels) {
            CFRelease(channels);
        }
    } else {
        // One-off probe (diagnostics). The channel set is released; the
        // subscription itself is intentionally left allocated (bounded count).
        CFRelease(channels);
        if (subbed) CFRelease(subbed);
    }
    if (ok) {
        if (outC) *outC = c;
        if (outName) *outName = hitName;
    }
    return ok;
}

// Rate how likely a channel name is a die temperature. Older SoCs do not always
// spell it "…Temperature", so TEMP / THERMAL / DIE / TDIE all count, while
// readings that are obviously power or voltage are rejected outright.
static int temperatureScore(NSString *name)
{
    if ([name length] == 0) return 0;
    NSString *u = [name uppercaseString];

    if ([u rangeOfString:@"POWER"].location != NSNotFound) return -1;
    if ([u rangeOfString:@"ENERGY"].location != NSNotFound) return -1;
    if ([u rangeOfString:@"VOLTAGE"].location != NSNotFound) return -1;
    if ([u rangeOfString:@"CURRENT"].location != NSNotFound) return -1;
    if ([u rangeOfString:@"COUNT"].location != NSNotFound) return -1;
    if ([u rangeOfString:@"FREQ"].location != NSNotFound) return -1;
    if ([u rangeOfString:@"RESIDENCY"].location != NSNotFound) return -1;

    int score = 0;
    if ([u rangeOfString:@"TEMPERATURE"].location != NSNotFound) score += 100;
    if ([u rangeOfString:@"TDIE"].location != NSNotFound) score += 60;
    if ([u rangeOfString:@"TEMP"].location != NSNotFound) score += 50;
    if ([u rangeOfString:@"THERMAL"].location != NSNotFound) score += 50;
    if ([u rangeOfString:@"DIE"].location != NSNotFound) score += 40;
    if ([u rangeOfString:@"CPU"].location != NSNotFound) score += 20;
    if ([u rangeOfString:@"SOC"].location != NSNotFound) score += 15;
    if ([u rangeOfString:@"GPU"].location != NSNotFound) score += 5;
    return score;
}

// Walk the nested sample dictionary (group -> subgroup -> channel) and return the
// best-scoring channel whose value normalises to a plausible SoC temperature.
static BOOL findTemperatureInSamples(CFDictionaryRef node, long *outRaw, NSString **outName, int depth)
{
    if (!node || CFGetTypeID(node) != CFDictionaryGetTypeID()) return NO;
    if (!pSimpleGetIntegerValue) return NO;
    if (depth > 6) return NO;

    CFIndex count = CFDictionaryGetCount(node);
    if (count <= 0 || count > 8192) return NO;

    CFTypeRef *keys = (CFTypeRef *)malloc(sizeof(CFTypeRef) * (size_t)count);
    CFTypeRef *vals = (CFTypeRef *)malloc(sizeof(CFTypeRef) * (size_t)count);
    if (!keys || !vals) {
        free(keys);
        free(vals);
        return NO;
    }
    CFDictionaryGetKeysAndValues(node, keys, vals);

    int bestScore = 0;
    long bestRaw = 0;
    NSString *bestName = nil;

    for (CFIndex i = 0; i < count; i++) {
        CFTypeRef key = keys[i];
        CFTypeRef val = vals[i];

        NSString *name = nil;
        if (key && CFGetTypeID(key) == CFStringGetTypeID()) {
            name = (__bridge NSString *)key;
        } else if (val && CFGetTypeID(val) == CFDictionaryGetTypeID() && pChannelGetChannelName) {
            CFStringRef n = pChannelGetChannelName((CFDictionaryRef)val);
            if (n) name = (__bridge NSString *)n;
        }

        if (name && val && CFGetTypeID(val) == CFDictionaryGetTypeID()) {
            int score = temperatureScore(name);
            if (score > 0) {
                long v = pSimpleGetIntegerValue((CFDictionaryRef)val, 0);
                if (!isnan(normalizeTemperature(v)) && score > bestScore) {
                    bestScore = score;
                    bestRaw = v;
                    bestName = name;
                }
            }
        }

        if (val && CFGetTypeID(val) == CFDictionaryGetTypeID()) {
            long r = 0;
            NSString *n2 = nil;
            if (findTemperatureInSamples((CFDictionaryRef)val, &r, &n2, depth + 1)) {
                int s2 = n2 ? temperatureScore(n2) : 0;
                if (s2 > bestScore) {
                    bestScore = s2;
                    bestRaw = r;
                    bestName = n2;
                }
            }
        }
    }

    free(keys);
    free(vals);

    if (bestScore > 0) {
        if (outRaw) *outRaw = bestRaw;
        if (outName) *outName = bestName ?: @"";
        return YES;
    }
    return NO;
}

// IOReport publishes temperatures in different scales depending on the channel:
// plain Celsius, decidegrees (1/10 C) or centidegrees (1/100 C). Pick the scale
// that lands inside a plausible range for a phone SoC.
static double normalizeTemperature(long raw)
{
    double d = (double)raw;
    if (d >= -50.0 && d <= 150.0) return d;
    if (d / 10.0 >= -50.0 && d / 10.0 <= 150.0) return d / 10.0;
    if (d / 100.0 >= -50.0 && d / 100.0 <= 150.0) return d / 100.0;
    return NAN;
}

// Channel groups that carry a die temperature on at least one SoC/iOS pair.
// Probed in order; the first one yielding a plausible reading wins.
static CFStringRef kTemperatureGroups[] = {
    CFSTR("CPU Die Temperature"),
    CFSTR("SoC Die Temperature"),
    CFSTR("GPU Die Temperature"),
    CFSTR("Thermal"),
    CFSTR("Energy Model"),
    CFSTR("PLATFORM Power"),
    CFSTR("PMP"),
    CFSTR("DieTemp"),
    CFSTR("temperature"),
    CFSTR("CPU Die Temperature (C)"),
    CFSTR("SoC Die Temperature (C)"),
};
static const int kTemperatureGroupCount =
    (int)(sizeof(kTemperatureGroups) / sizeof(kTemperatureGroups[0]));

// Returns the CPU/SoC die temperature in Celsius, or NAN when unavailable.
static double getCPUDieTemperature(void)
{
    // 1) Fast path: reuse the subscription that already proved to work.
    if (gActiveSubscription && pCreateSamples) {
        CFDictionaryRef samples = pCreateSamples(gActiveSubscription, gActiveChannels, NULL);
        if (samples) {
            long raw = 0;
            NSString *name = nil;
            BOOL ok = findTemperatureInSamples(samples, &raw, &name, 0);
            CFRelease(samples);
            if (ok) {
                double c = normalizeTemperature(raw);
                if (!isnan(c)) {
                    cpuTempSetupFailed = NO;
                    return c;
                }
            }
        }
        // the cached group stopped reporting -> probe again below
        gActiveSubscription = NULL;
        gActiveChannels = NULL;
        gActiveGroup = NULL;
    }

    // 2) Respect the probe budget and the backoff between attempts.
    if (cpuTempProbeBudget <= 0) return NAN;
    if (cpuTempRetryCountdown > 0) {
        cpuTempRetryCountdown--;
        return NAN;
    }
    cpuTempProbeBudget--;

    // 3) The first run records everything it finds, later ones stop at the hit.
    BOOL fullScan = !gDiagDone;

    if (!ensureIOReportSymbols()) {
        if (fullScan) {
            diagReset();
            diagAdd(@"[0] IOReport symbols could not be resolved -> IOReport unusable");
            gDiagDone = YES;
        }
        return NAN;
    }

    if (fullScan) {
        diagReset();
        diagAdd([NSString stringWithFormat:
            @"[0] symbols: channels=%d all=%d subscribe=%d sample=%d getint=%d name=%d",
            pCopyChannelsInGroup != NULL, pCopyAllChannels != NULL,
            pCreateSubscription != NULL, pCreateSamples != NULL,
            pSimpleGetIntegerValue != NULL, pChannelGetChannelName != NULL]);
    }

    double result = NAN;
    NSString *hitName = nil;

    for (int i = 0; i < kTemperatureGroupCount && isnan(result); i++) {
        double c = NAN;
        NSString *name = nil;
        NSString *gname = (__bridge NSString *)kTemperatureGroups[i];
        BOOL ok = tryTemperatureGroup(kTemperatureGroups[i], &c, &name, YES);

        if (fullScan) {
            if (ok) {
                diagAdd([NSString stringWithFormat:
                    @"[1] \"%@\" -> HIT   %@   %.2fC", gname, name, c]);
            } else {
                diagAdd([NSString stringWithFormat:
                    @"[1] \"%@\" -> empty / no temperature channel", gname]);
            }
        }
        if (ok) {
            result = c;
            hitName = name;
        }
    }

    // 4) Last resort: enumerate every group name the device reports and probe the
    //    ones that look thermal, in case the fixed list above misses it.
    if (isnan(result) && pCopyAllChannels) {
        CFMutableDictionaryRef all = pCopyAllChannels(0, 0);
        if (all) {
            CFIndex count = CFDictionaryGetCount(all);
            if (fullScan) {
                diagAdd([NSString stringWithFormat:@"[2] all-channels groups: %ld", (long)count]);
            }
            if (count > 0 && count < 8192) {
                CFTypeRef *keys = (CFTypeRef *)malloc(sizeof(CFTypeRef) * (size_t)count);
                CFTypeRef *vals = (CFTypeRef *)malloc(sizeof(CFTypeRef) * (size_t)count);
                if (keys && vals) {
                    CFDictionaryGetKeysAndValues((CFDictionaryRef)all, keys, vals);
                    for (CFIndex i = 0; i < count && isnan(result); i++) {
                        CFTypeRef k = keys[i];
                        if (!k || CFGetTypeID(k) != CFStringGetTypeID()) continue;
                        NSString *gname = (__bridge NSString *)k;
                        NSString *u = [gname uppercaseString];
                        if ([u rangeOfString:@"TEMP"].location == NSNotFound &&
                            [u rangeOfString:@"THERM"].location == NSNotFound &&
                            [u rangeOfString:@"DIE"].location == NSNotFound &&
                            [u rangeOfString:@"CPU"].location == NSNotFound &&
                            [u rangeOfString:@"SOC"].location == NSNotFound) {
                            continue;
                        }
                        double c = NAN;
                        NSString *name = nil;
                        if (tryTemperatureGroup((CFStringRef)k, &c, &name, YES)) {
                            if (fullScan) {
                                diagAdd([NSString stringWithFormat:
                                    @"[2] scan \"%@\" -> HIT   %@   %.2fC", gname, name, c]);
                            }
                            result = c;
                            hitName = name;
                        }
                    }
                }
                free(keys);
                free(vals);
            }
            CFRelease(all);
        }
    }

    if (fullScan) {
        diagAdd(@"");
        if (!isnan(result)) {
            diagAdd([NSString stringWithFormat:@"[3] RESULT: %.2f C   source: %@", result, hitName ?: @"?"]);
        } else {
            diagAdd(@"[3] RESULT: no CPU/SoC temperature source found on this device");
        }
        gDiagDone = YES;
    }

    if (isnan(result)) {
        cpuTempSetupFailed = YES;
        cpuTempRetryCountdown = 30;
    } else {
        cpuTempSetupFailed = NO;
    }
    return result;
}

static NSString* formattedCPUTemp(BOOL useFahrenheit)
{
    double temp = getCPUDieTemperature();
    if (isnan(temp)) {
        return useFahrenheit ? @"??ºF" : @"??ºC";
    }
    if (useFahrenheit) {
        temp = (temp * 9.0/5.0) + 32.0;
        return [NSString stringWithFormat: @"%.2fºF", temp];
    }
    return [NSString stringWithFormat: @"%.2fºC", temp];
}

#pragma mark - Battery Widget
/*
 Battery Widget Identifiers:
 0 = Watts
 1 = Charging Current
 2 = Regular Amperage
 3 = Charge Cycles
 */
static NSString* formattedBattery(NSInteger valueType)
{
    NSDictionary *batteryInfo = getBatteryInfo();
    if (batteryInfo) {
        if (valueType == 0) {
            // Watts
            int watts = [batteryInfo[@"AdapterDetails"][@"Watts"] longLongValue];
            if (watts) {
                return [NSString stringWithFormat: @"%d W", watts];
            } else {
                return @"0 W";
            }
        } else if (valueType == 1) {
            // Charging Current
            double current = [batteryInfo[@"AdapterDetails"][@"Current"] doubleValue];
            if (current) {
                return [NSString stringWithFormat: @"%.0f mA", current];
            } else {
                return @"0 mA";
            }
        } else if (valueType == 2) {
            // Regular Amperage
            double amps = [batteryInfo[@"Amperage"] doubleValue];
            if (amps) {
                return [NSString stringWithFormat: @"%.0f mA", amps];
            } else {
                return @"0 mA";
            }
        } else if (valueType == 3) {
            // Charge Cycles
            return [batteryInfo[@"CycleCount"] stringValue];
        } else {
            return @"???";
        }
    }
    return @"??";
}

#pragma mark - Current Capacity Widget
static NSString* formattedCurrentCapacity(BOOL showPercentage)
{
    NSDictionary *batteryInfo = getBatteryInfo();
    if (batteryInfo) {
        return [
            NSString stringWithFormat: @"%@%@",
            [batteryInfo[@"CurrentCapacity"] stringValue],
            showPercentage ? @"%" : @""
            ];
    }
    return @"??%";
}

#pragma mark - Charging Symbol Widget
static NSString* formattedChargingSymbol(BOOL filled)
{
    [[UIDevice currentDevice] setBatteryMonitoringEnabled: YES];
    if ([[UIDevice currentDevice] batteryState] != UIDeviceBatteryStateUnplugged) {
        if (filled) {
            return @"bolt.fill";
        } else {
            return @"bolt";
        }
    }
    return @"";
}


#pragma mark - Main Widget Functions
/*
 Widget Identifiers:
 0 = None
 1 = Date
 2 = Network Up/Down
 3 = Device Temp
 4 = Battery Detail
 5 = Time
 6 = Text
 7 = Battery Percentage
 8 = Charging Symbol
 9 = Weather
 10 = CPU Temp (SoC die temperature via IOReport)

 TODO:
 - Music Visualizer
 */
void formatParsedInfo(NSDictionary *parsedInfo, NSInteger parsedID, NSMutableAttributedString *mutableString, double fontSize, UIColor *textColor, NSString *apiKey, NSString *dateLocale)
{
    NSString *widgetString;
    NSString *sfSymbolName;
    NSTextAttachment *imageAttachment;
    switch (parsedID) {
        case 1:
        case 5:
            // Date/Time
            widgetString = formattedDate(
                [parsedInfo valueForKey:@"dateFormat"] ? [parsedInfo valueForKey:@"dateFormat"] : (parsedID == 1 ? NSLocalizedString(@"E MMM dd", comment: @"") : @"hh:mm"), dateLocale
            );
            break;
        case 2:
            // Network Speed
            [
                mutableString appendAttributedString: formattedAttributedSpeedString(
                    [parsedInfo valueForKey:@"isUp"] ? [[parsedInfo valueForKey:@"isUp"] boolValue] : NO,
                    [parsedInfo valueForKey:@"speedIcon"] ? [[parsedInfo valueForKey:@"speedIcon"] intValue] : 0,
                    [parsedInfo valueForKey:@"minUnit"] ? [[parsedInfo valueForKey:@"minUnit"] intValue] : 1,
                    [parsedInfo valueForKey:@"hideSpeedWhenZero"] ? [[parsedInfo valueForKey:@"hideSpeedWhenZero"] boolValue] : NO,
                    fontSize
                )
            ];
            break;
        case 3:
            // Device Temp
            widgetString = formattedTemp(
                [parsedInfo valueForKey:@"useFahrenheit"] ? [[parsedInfo valueForKey:@"useFahrenheit"] boolValue] : NO
            );
            break;
        case 4:
            // Battery Stats
            widgetString = formattedBattery(
                [parsedInfo valueForKey:@"batteryValueType"] ? [[parsedInfo valueForKey:@"batteryValueType"] integerValue] : 0
            );
            break;
        case 6:
            // Text
            widgetString = [parsedInfo valueForKey:@"text"] ? [parsedInfo valueForKey:@"text"] : @"Unknown";
            break;
        case 7:
            // Current Capacity
            widgetString = formattedCurrentCapacity(
                [parsedInfo valueForKey:@"showPercentage"] ? [[parsedInfo valueForKey:@"showPercentage"] boolValue] : YES
            );
            break;
        case 8:
            // Charging Symbol
            sfSymbolName = formattedChargingSymbol(
                [parsedInfo valueForKey:@"filled"] ? [[parsedInfo valueForKey:@"filled"] boolValue] : YES
            );
            if (![sfSymbolName isEqualToString:@""]) {
                imageAttachment = [[NSTextAttachment alloc] init];
                imageAttachment.image = [
                    [
                        UIImage systemImageNamed:sfSymbolName
                        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:fontSize]
                    ]
                    imageWithTintColor:textColor
                ];
                [mutableString appendAttributedString:[NSAttributedString attributedStringWithAttachment:imageAttachment]];
            }
            break;
        case 9:
            {
                // Weather
                NSString *location = [parsedInfo valueForKey:@"location"];
                NSString *format = [parsedInfo valueForKey:@"format"];
                NSDictionary *now = [WeatherUtils fetchNowWeatherForLocation: location apiKey:apiKey dateLocale:dateLocale];
                NSDictionary *today = [WeatherUtils fetchTodayWeatherForLocation: location apiKey:apiKey dateLocale:dateLocale];
                widgetString = [WeatherUtils formatNowResult:now format:format];
                widgetString = [WeatherUtils formatTodayResult:today format:widgetString];
            }
            break;
        case 10:
            // CPU Temp
            widgetString = formattedCPUTemp(
                [parsedInfo valueForKey:@"useFahrenheit"] ? [[parsedInfo valueForKey:@"useFahrenheit"] boolValue] : NO
            );
            break;
        default:
            // do not add anything
            break;
    }
    if (widgetString) {
        widgetString = [widgetString stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"];
        widgetString = [widgetString stringByReplacingOccurrencesOfString:@"\\t" withString:@"\t"];
        [
            mutableString appendAttributedString:[[NSAttributedString alloc] initWithString: widgetString]
        ];
    }
}

NSAttributedString* formattedAttributedString(NSArray *identifiers, double fontSize, UIColor *textColor, NSString *apiKey, NSString *dateLocale)
{
    @autoreleasepool {
        NSMutableAttributedString* mutableString = [[NSMutableAttributedString alloc] init];
        
        if (identifiers) {
            for (id idInfo in identifiers) {
                NSDictionary *parsedInfo = idInfo;
                NSInteger parsedID = [parsedInfo valueForKey:@"widgetID"] ? [[parsedInfo valueForKey:@"widgetID"] integerValue] : 0;
                formatParsedInfo(parsedInfo, parsedID, mutableString, fontSize, textColor, apiKey, dateLocale);
            }
        } else {
            return nil;
        }
        
        return [mutableString copy];
    }
}
