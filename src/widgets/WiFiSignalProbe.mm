//
//  WiFiSignalProbe.mm
//  Helium
//
//  Wi-Fi 关联状态（公开 API）与接收功率（MobileWiFi 私有框架）。
//
//  ══════════════════════════════════════════════════════════════════════════
//  这个文件改过三版，每一版的错误都记在这里，免得再踩
//  ══════════════════════════════════════════════════════════════════════════
//
//  **第一版：整个 HUD 崩掉。**
//
//  `WiFiManagerClientGetDevice` 会段错误（netctl 的 `wifi/wifi.m` 里明确写着
//  `// WiFiManagerClientGetDevice(WiFiManagerRef) segfaults`），而 Helium 的每个
//  部件都由同一个进程绘制 —— 所以表现是「启用后所有部件一起不显示」。
//  改用 `WiFiManagerClientCopyDevices` + `CFArrayGetValueAtIndex`。
//
//  **第二版：数值卡住不动。**
//
//  一是**读错了属性**。`CFSTR("RSSI")` 在**设备**上返回的是**字典**（要取
//  `RSSI_CTL_AGR`），那是控制用的聚合值，粒度很粗 —— 表现就是「只有固定几个数值
//  在跳」。正确做法是走**网络**：
//
//      WiFiNetworkRef network = WiFiDeviceClientCopyCurrentNetwork(device);
//      CFNumberRef rssi = WiFiNetworkGetProperty(network, CFSTR("RSSI"));  // 浮点 dBm
//
//  这是 David Murray（MobileWiFi 头文件作者）在 `davidmurray/wifi` 与
//  `davidmurray/airscan` 里的写法：`%.0f dBm` 直接就是这个数。
//
//  二是**把锁加错了地方**：为了防「每秒重试一次崩一次」，加了个「整个进程只读一次」
//  的 latch，结果连数值也一起冻住了。**latch 应该只管会话建立，不管读数** ——
//  会话建好之后，每次采样重新读一遍属性才是「实时值」。
//
//  ══════════════════════════════════════════════════════════════════════════
//  现在保留的两层防护
//  ══════════════════════════════════════════════════════════════════════════
//
//  * 「连没连 Wi-Fi」用 `getifaddrs`（公开 API）判断，不在 Wi-Fi 上时**根本不会
//    碰到私有框架**；
//  * 会话建立（dlopen / dlsym / create / 取设备）**整个进程只做一次**，失败就锁定 ——
//    这条路一旦有问题，每秒重试只会每秒出一次问题。
//
//  失败时把「断在哪一步」记进 `helium_wifi_diagnosis()`，由设置页显示。
//

#import "WiFiSignalProbe.h"

#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <ifaddrs.h>
#import <math.h>
#import <net/if.h>
#import <netinet/in.h>
#import <string.h>

// 不透明类型，只按指针用。
typedef struct __WiFiManager WiFiManager;
typedef struct __WiFiDeviceClient WiFiDeviceClient;
typedef struct __WiFiNetwork WiFiNetwork;

typedef WiFiManager *(*WiFiManagerClientCreateFunc)(CFAllocatorRef allocator, int flags);
typedef CFArrayRef (*WiFiManagerClientCopyDevicesFunc)(WiFiManager *manager);
typedef WiFiNetwork *(*WiFiDeviceClientCopyCurrentNetworkFunc)(WiFiDeviceClient *device);
typedef CFPropertyListRef (*WiFiDeviceClientCopyPropertyFunc)(WiFiDeviceClient *device, CFStringRef property);
typedef CFPropertyListRef (*WiFiNetworkGetPropertyFunc)(WiFiNetwork *network, CFStringRef property);
typedef float (*WiFiNetworkGetFloatPropertyFunc)(WiFiNetwork *network, CFStringRef property);

static const char *const kDiagnosisNotAttempted = "not-attempted";
static const char *const kDiagnosisOK = "ok";
static const char *const kDiagnosisDLOpen = "dlopen-failed";
static const char *const kDiagnosisSymbols = "symbol-missing";
static const char *const kDiagnosisCreate = "create-failed";
static const char *const kDiagnosisNoDevice = "no-device";
static const char *const kDiagnosisNoNetwork = "no-network";
static const char *const kDiagnosisUnreadable = "rssi-unreadable";

static const char *gDiagnosis = kDiagnosisNotAttempted;

/// 会话状态：0 = 没试过，1 = 可用，-1 = 不可用（已锁定，不再重试）。
static int gSession = 0;
static WiFiDeviceClient *gDevice = NULL;

static WiFiDeviceClientCopyCurrentNetworkFunc gCopyCurrentNetwork = NULL;
static WiFiDeviceClientCopyPropertyFunc gCopyDeviceProperty = NULL;
static WiFiNetworkGetPropertyFunc gNetworkGetProperty = NULL;
static WiFiNetworkGetFloatPropertyFunc gNetworkGetFloatProperty = NULL;

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

// MARK: - 会话（整个进程只建一次）

static BOOL ensureSession(void)
{
    if (gSession != 0) {
        return gSession > 0;
    }

    void *handle = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi",
                          RTLD_LAZY);
    if (handle == NULL) {
        gDiagnosis = kDiagnosisDLOpen;
        gSession = -1;
        return NO;
    }

    WiFiManagerClientCreateFunc create =
        (WiFiManagerClientCreateFunc)dlsym(handle, "WiFiManagerClientCreate");
    WiFiManagerClientCopyDevicesFunc copyDevices =
        (WiFiManagerClientCopyDevicesFunc)dlsym(handle, "WiFiManagerClientCopyDevices");
    gCopyCurrentNetwork =
        (WiFiDeviceClientCopyCurrentNetworkFunc)dlsym(handle, "WiFiDeviceClientCopyCurrentNetwork");
    gCopyDeviceProperty =
        (WiFiDeviceClientCopyPropertyFunc)dlsym(handle, "WiFiDeviceClientCopyProperty");
    gNetworkGetProperty =
        (WiFiNetworkGetPropertyFunc)dlsym(handle, "WiFiNetworkGetProperty");
    // 可选符号：有就直接拿 float，没有就走 `GetProperty` + 解析 CFNumber。
    gNetworkGetFloatProperty =
        (WiFiNetworkGetFloatPropertyFunc)dlsym(handle, "WiFiNetworkGetFloatProperty");

    if (create == NULL || copyDevices == NULL || gCopyCurrentNetwork == NULL ||
        gCopyDeviceProperty == NULL || gNetworkGetProperty == NULL) {
        gDiagnosis = kDiagnosisSymbols;
        gSession = -1;
        return NO;
    }

    WiFiManager *manager = create(kCFAllocatorDefault, 0);
    if (manager == NULL) {
        gDiagnosis = kDiagnosisCreate;
        gSession = -1;
        return NO;
    }

    // **不要用 `WiFiManagerClientGetDevice`** —— 它会段错误，见文件头的说明。
    CFArrayRef devices = copyDevices(manager);
    if (devices == NULL || CFArrayGetCount(devices) == 0) {
        if (devices != NULL) {
            CFRelease(devices);
        }
        gDiagnosis = kDiagnosisNoDevice;
        gSession = -1;
        return NO;
    }
    gDevice = (WiFiDeviceClient *)CFArrayGetValueAtIndex(devices, 0);
    // 设备指针只是数组里的一项；会话本身由 manager 撑着，数组可以不持有。
    CFRelease(devices);

    gSession = 1;
    return YES;
}

// MARK: - 读数（每次采样都重新读）

/// 从一个 `CFPropertyListRef` 里取负的浮点 dBm。取不到返回 0。
static int32_t dBmFromNumber(CFPropertyListRef raw)
{
    if (raw == NULL || CFGetTypeID(raw) != CFNumberGetTypeID()) {
        return 0;
    }
    float strength = 0;
    if (!CFNumberGetValue((CFNumberRef)raw, kCFNumberFloatType, &strength)) {
        return 0;
    }
    if (!(strength < 0)) {
        return 0;
    }
    return (int32_t)lroundf(strength);
}

int32_t helium_wifi_rssi_dbm(void)
{
    if (!ensureSession()) {
        return 0;
    }

    // 首选：**当前网络**上的 RSSI。
    //
    // 这是 David Murray 的实现用的那条路（`davidmurray/wifi`、`davidmurray/airscan`），
    // 返回浮点 dBm —— 也就是状态栏上该显示的那个数。
    WiFiNetwork *network = gCopyCurrentNetwork(gDevice);
    if (network != NULL) {
        int32_t value = 0;

        // 先试直接返回 float 的那个（省掉类型解析）。
        if (gNetworkGetFloatProperty != NULL) {
            float strength = gNetworkGetFloatProperty(network, CFSTR("RSSI"));
            if (strength < 0) {
                value = (int32_t)lroundf(strength);
            }
        }
        // 再试 `GetProperty` + 解析 —— David Murray 的实现走的就是这条。
        if (value == 0) {
            // `Get` 规则：+0，不需要释放。
            value = dBmFromNumber(gNetworkGetProperty(network, CFSTR("RSSI")));
        }

        CFRelease(network);
        if (value < 0) {
            gDiagnosis = kDiagnosisOK;
            return value;
        }
    }

    // 兜底：设备字典里的 `RSSI_CTL_AGR`。
    //
    // 粒度比上面那个粗（是控制用的聚合值），所以只当兜底 —— 第二版就是因为只走了
    // 这条路，才出现「只有固定几个数值在跳」。
    CFPropertyListRef raw = gCopyDeviceProperty(gDevice, CFSTR("RSSI"));
    if (raw != NULL) {
        int32_t value = 0;
        if (CFGetTypeID(raw) == CFDictionaryGetTypeID()) {
            value = dBmFromNumber(CFDictionaryGetValue((CFDictionaryRef)raw, CFSTR("RSSI_CTL_AGR")));
        } else {
            value = dBmFromNumber(raw);
        }
        CFRelease(raw);
        if (value < 0) {
            gDiagnosis = kDiagnosisOK;
            return value;
        }
    }

    gDiagnosis = (network == NULL) ? kDiagnosisNoNetwork : kDiagnosisUnreadable;
    return 0;
}

const char *helium_wifi_diagnosis(void)
{
    return gDiagnosis;
}
