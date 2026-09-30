//
//  WiFiSignalProbe.mm
//  Helium
//
//  Wi-Fi 关联状态（公开 API）与接收功率（MobileWiFi 私有框架）。
//
//  ══════════════════════════════════════════════════════════════════════════
//  第一版把 HUD 整个搞崩了，原因有三个，都在这里修掉了
//  ══════════════════════════════════════════════════════════════════════════
//
//  1) **`WiFiManagerClientGetDevice` 会段错误。**
//
//      参考实现里明确写着这一条（ProcursusTeam/netctl 的 `wifi/wifi.m`）：
//
//          // WiFiManagerClientGetDevice(WiFiManagerRef) segfaults
//          CFArrayRef devices = WiFiManagerClientCopyDevices(manager);
//          client = (WiFiDeviceClientRef)CFArrayGetValueAtIndex(devices, 0);
//
//      第一版用的正是那个会崩的函数 —— 它把 HUD 进程直接带走，而 Helium 的
//      每个部件都由同一个进程绘制，表现就是「启用后所有部件一起不显示」。
//
//  2) **缺两条权限。** netctl 的 entitlements 里有
//      `com.apple.wifi.manager-access` 与 `com.apple.private.skip-library-validation`
//      （后者是加载私有框架用的）。见 `ent.plist`。
//
//  3) **RSSI 返回的是字典，不是数字。**
//
//          CFDictionaryRef data = WiFiDeviceClientCopyProperty(client, CFSTR("RSSI"));
//          CFNumberRef rssi = CFDictionaryGetValue(data, CFSTR("RSSI_CTL_AGR"));
//
//      第一版按 CFNumber 解析，类型对不上于是永远读不到 —— 部件静默退回蜂窝，
//      这正是「已连 Wi-Fi 却显示蜂窝」的原因。
//
//  ══════════════════════════════════════════════════════════════════════════
//  仍然保留的两层防护
//  ══════════════════════════════════════════════════════════════════════════
//
//  * 「连没连 Wi-Fi」用 `getifaddrs`（公开 API）判断，不在 Wi-Fi 上时**根本不会
//    碰到私有框架**；
//  * 整个进程**最多真正尝试一次**（latch）—— 那条路一旦有问题，每秒重试只会
//    每秒出一次问题。
//
//  失败时把「断在哪一步」记进 `helium_wifi_diagnosis()`，由设置页显示。
//  加这个是因为无法在真机上调试：`dlopen` 失败、符号改名、wifid 拒绝连接，
//  这几种在界面上看起来完全一样（都只是「数字不动」）。
//

#import "WiFiSignalProbe.h"

#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <string.h>

// 不透明类型，只按指针用。
typedef struct __WiFiManager WiFiManager;
typedef struct __WiFiDeviceClient WiFiDeviceClient;

typedef WiFiManager *(*WiFiManagerClientCreateFunc)(CFAllocatorRef allocator, int flags);
typedef CFArrayRef (*WiFiManagerClientCopyDevicesFunc)(WiFiManager *manager);
typedef CFPropertyListRef (*WiFiDeviceClientCopyPropertyFunc)(WiFiDeviceClient *device, CFStringRef property);

static const char *const kDiagnosisNotAttempted = "not-attempted";
static const char *const kDiagnosisOK = "ok";
static const char *const kDiagnosisDLOpen = "dlopen-failed";
static const char *const kDiagnosisSymbols = "symbol-missing";
static const char *const kDiagnosisCreate = "create-failed";
static const char *const kDiagnosisNoDevice = "no-device";
static const char *const kDiagnosisUnreadable = "rssi-unreadable";

static const char *gDiagnosis = kDiagnosisNotAttempted;
static BOOL gAttempted = NO;
static int32_t gRSSIDbm = 0;

// MARK: - 关联判断（公开 API）

BOOL helium_wifi_is_associated(void)
{
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0 || list == NULL) {
        return NO;
    }

    BOOL associated = NO;
    for (struct ifaddrs *entry = list; entry != NULL; entry = entry->ifa_next) {
        if (entry->ifa_addr == NULL) {
            continue;
        }
        // iOS 上 Wi-Fi 固定是 `en0`。只认 IPv4/IPv6，**不认 AF_LINK** ——
        // 网卡没连上时那条仍然存在，拿它判断会一直说「连着」。
        if (strcmp(entry->ifa_name, "en0") != 0) {
            continue;
        }
        if ((entry->ifa_flags & IFF_UP) == 0) {
            continue;
        }
        sa_family_t family = entry->ifa_addr->sa_family;
        if (family == AF_INET || family == AF_INET6) {
            associated = YES;
            break;
        }
    }

    freeifaddrs(list);
    return associated;
}

// MARK: - RSSI（私有框架，只试一次）

/// 从一个可能是数字、也可能是「装着数字的字典」的值里取出负的 dBm。
///
/// 两种形状都处理：参考实现里 `CFSTR("RSSI")` 给的是字典（键 `RSSI_CTL_AGR`），
/// 但不同 iOS 版本不一定一致，所以数字那条路也留着。
static int32_t dBmFromProperty(CFPropertyListRef raw)
{
    CFTypeID type = CFGetTypeID(raw);

    if (type == CFDictionaryGetTypeID()) {
        CFTypeRef inner = CFDictionaryGetValue((CFDictionaryRef)raw, CFSTR("RSSI_CTL_AGR"));
        if (inner == NULL || CFGetTypeID(inner) != CFNumberGetTypeID()) {
            return 0;
        }
        int number = 0;
        if (!CFNumberGetValue((CFNumberRef)inner, kCFNumberIntType, &number)) {
            return 0;
        }
        return number < 0 ? (int32_t)number : 0;
    }

    if (type == CFNumberGetTypeID()) {
        int number = 0;
        if (!CFNumberGetValue((CFNumberRef)raw, kCFNumberIntType, &number)) {
            return 0;
        }
        return number < 0 ? (int32_t)number : 0;
    }

    return 0;
}

/// 读一次 RSSI。**只在 `helium_wifi_rssi_dbm` 里被调用一次。**
static int32_t readRSSIOnce(void)
{
    void *handle = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi",
                          RTLD_LAZY);
    if (handle == NULL) {
        gDiagnosis = kDiagnosisDLOpen;
        return 0;
    }

    WiFiManagerClientCreateFunc create =
        (WiFiManagerClientCreateFunc)dlsym(handle, "WiFiManagerClientCreate");
    WiFiManagerClientCopyDevicesFunc copyDevices =
        (WiFiManagerClientCopyDevicesFunc)dlsym(handle, "WiFiManagerClientCopyDevices");
    WiFiDeviceClientCopyPropertyFunc copyProperty =
        (WiFiDeviceClientCopyPropertyFunc)dlsym(handle, "WiFiDeviceClientCopyProperty");

    if (create == NULL || copyDevices == NULL || copyProperty == NULL) {
        gDiagnosis = kDiagnosisSymbols;
        return 0;
    }

    WiFiManager *manager = create(kCFAllocatorDefault, 0);
    if (manager == NULL) {
        gDiagnosis = kDiagnosisCreate;
        return 0;
    }

    // **不要用 `WiFiManagerClientGetDevice`** —— 它会段错误，见文件头的说明。
    CFArrayRef devices = copyDevices(manager);
    if (devices == NULL || CFArrayGetCount(devices) == 0) {
        if (devices != NULL) {
            CFRelease(devices);
        }
        gDiagnosis = kDiagnosisNoDevice;
        return 0;
    }
    WiFiDeviceClient *device = (WiFiDeviceClient *)CFArrayGetValueAtIndex(devices, 0);

    CFPropertyListRef raw = copyProperty(device, CFSTR("RSSI"));
    if (raw == NULL) {
        CFRelease(devices);
        gDiagnosis = kDiagnosisUnreadable;
        return 0;
    }

    int32_t value = dBmFromProperty(raw);
    CFRelease(raw);
    CFRelease(devices);

    gDiagnosis = value < 0 ? kDiagnosisOK : kDiagnosisUnreadable;
    return value;
}

int32_t helium_wifi_rssi_dbm(void)
{
    if (!gAttempted) {
        gAttempted = YES;
        gRSSIDbm = readRSSIOnce();
    }
    return gRSSIDbm;
}

const char *helium_wifi_diagnosis(void)
{
    return gDiagnosis;
}
