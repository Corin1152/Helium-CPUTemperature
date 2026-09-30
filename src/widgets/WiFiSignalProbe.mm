//
//  WiFiSignalProbe.mm
//  Helium
//
//  Wi-Fi 关联状态（公开 API）与接收功率（私有框架）。
//
//  ══════════════════════════════════════════════════════════════════════════
//  为什么关联判断不走 MobileWiFi
//  ══════════════════════════════════════════════════════════════════════════
//
//  第一版把「有没有连 Wi-Fi」也交给了 MobileWiFi（`WiFiDeviceClientCopyCurrentNetwork`），
//  结果是启用这个部件后**所有部件一起不显示** —— 那说明这条调用把 HUD 进程带下去了，
//  而 Helium 的每个部件都由同一个进程绘制。
//
//  现在把它拆成两层：
//
//    * 「连没连 Wi-Fi」用 `getifaddrs`（公开 API，不会崩）判断；
//    * 只有确实连着，才去问 MobileWiFi 要 RSSI。
//
//  这样不在 Wi-Fi 上时**根本不会碰到私有框架** —— 风险面小了一个数量级。
//
//  ══════════════════════════════════════════════════════════════════════════
//  而且整个进程最多只真正尝试一次
//  ══════════════════════════════════════════════════════════════════════════
//
//  `WiFiManagerClientCreate` 是跟 wifid 建会话，它一旦有问题（卡住或崩溃），
//  每秒重试一次毫无意义 —— 只会每秒出一次问题。所以这里用一个 latch：
//  第一次尝试之后就把结论定下来（成功或失败），之后只读缓存，不再调用。
//
//  失败时还会把「断在哪一步」记进 `helium_wifi_diagnosis()`，由设置页显示出来。
//  加这个是因为无法在真机上调试：`dlopen` 失败、符号改名、wifid 拒绝连接，
//  这三种在界面上看起来完全一样（都只是「数字不动」）。
//
//  ══════════════════════════════════════════════════════════════════════════
//  MobileWiFi 的 API 形状（取自其公开头文件，不是猜的）
//  ══════════════════════════════════════════════════════════════════════════
//
//      WiFiManagerRef     WiFiManagerClientCreate(CFAllocatorRef, int);
//      WiFiDeviceClientRef WiFiManagerClientGetDevice(WiFiManagerRef);
//      CFPropertyListRef  WiFiDeviceClientCopyProperty(WiFiDeviceClientRef, CFStringRef);
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
typedef WiFiDeviceClient *(*WiFiManagerClientGetDeviceFunc)(WiFiManager *manager);
typedef CFPropertyListRef (*WiFiDeviceClientCopyPropertyFunc)(WiFiDeviceClient *device, CFStringRef property);

static const char *const kDiagnosisNotAttempted = "not-attempted";
static const char *const kDiagnosisOK = "ok";
static const char *const kDiagnosisDLOpen = "dlopen-failed";
static const char *const kDiagnosisSymbols = "symbol-missing";
static const char *const kDiagnosisCreate = "create-failed";
static const char *const kDiagnosisDevice = "get-device-failed";
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
    WiFiManagerClientGetDeviceFunc getDevice =
        (WiFiManagerClientGetDeviceFunc)dlsym(handle, "WiFiManagerClientGetDevice");
    WiFiDeviceClientCopyPropertyFunc copyProperty =
        (WiFiDeviceClientCopyPropertyFunc)dlsym(handle, "WiFiDeviceClientCopyProperty");

    if (create == NULL || getDevice == NULL || copyProperty == NULL) {
        gDiagnosis = kDiagnosisSymbols;
        return 0;
    }

    WiFiManager *manager = create(NULL, 0);
    if (manager == NULL) {
        gDiagnosis = kDiagnosisCreate;
        return 0;
    }

    WiFiDeviceClient *device = getDevice(manager);
    if (device == NULL) {
        gDiagnosis = kDiagnosisDevice;
        return 0;
    }

    CFPropertyListRef raw = copyProperty(device, CFSTR("RSSI"));
    if (raw == NULL) {
        gDiagnosis = kDiagnosisUnreadable;
        return 0;
    }

    int32_t value = 0;
    if (CFGetTypeID(raw) == CFNumberGetTypeID()) {
        int number = 0;
        if (CFNumberGetValue((CFNumberRef)raw, kCFNumberIntType, &number) && number < 0) {
            value = (int32_t)number;
        }
    }
    CFRelease(raw);

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
