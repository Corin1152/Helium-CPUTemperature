//
//  WiFiSignalProbe.mm
//  Helium
//
//  Wi-Fi RSSI through MobileWiFi's private client.
//
//  ## 为什么是运行时解析
//
//  Helium links no part of MobileWiFi, so the framework has to be dlopen()ed
//  before dlsym() can find anything. Everything is resolved by name at runtime,
//  which means a renamed or removed symbol degrades to "no reading" instead of
//  failing to link or crashing — the same shape as the IOReport lookup in the
//  CPU temperature widget and the CoreTelephony lookup in CellularSignalProbe.
//
//  ## API 形状（取自 MobileWiFi 的公开头文件）
//
//      WiFiManagerRef  WiFiManagerClientCreate(CFAllocatorRef, int);
//      WiFiDeviceClientRef WiFiManagerClientGetDevice(WiFiManagerRef);
//      CFPropertyListRef  WiFiDeviceClientCopyProperty(WiFiDeviceClientRef, CFStringRef);
//      WiFiNetworkRef     WiFiDeviceClientCopyCurrentNetwork(WiFiDeviceClientRef);
//
//  常量里有 `kWiFiRSSIThresholdKey` / `kWiFiStrengthKey` / `kWiFiScaledRSSIKey`，
//  但真正返回的 RSSI 直接按属性名 `"RSSI"` 取 —— 头文件里那个 `SCAN_RSSI_THRESHOLD`
//  的注释（Apple 用 -80 当扫描门限）说明这个键名是 wifid 认的。
//
//  ## 失败时是静默的
//
//  wifid 拒绝连接时这些调用返回 NULL，不抛异常也不打日志。所以这里把「有没有关联」
//  与「读不读得到 RSSI」分开报告：前者决定要不要回落到蜂窝，后者决定这一格显示什么。
//

#import "WiFiSignalProbe.h"

#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>

// 这些类型在公开头文件里是不透明结构体，这里只按指针用，不需要完整定义。
typedef struct __WiFiManager WiFiManager;
typedef struct __WiFiDeviceClient WiFiDeviceClient;
typedef struct __WiFiNetwork WiFiNetwork;

typedef WiFiManager *(*WiFiManagerClientCreateFunc)(CFAllocatorRef allocator, int flags);
typedef WiFiDeviceClient *(*WiFiManagerClientGetDeviceFunc)(WiFiManager *manager);
typedef CFPropertyListRef (*WiFiDeviceClientCopyPropertyFunc)(WiFiDeviceClient *device, CFStringRef property);
typedef WiFiNetwork *(*WiFiDeviceClientCopyCurrentNetworkFunc)(WiFiDeviceClient *device);

static void *gWiFiHandle = NULL;
static BOOL gWiFiResolved = NO;
static WiFiManager *gWiFiManager = NULL;
static WiFiDeviceClient *gWiFiDevice = NULL;
static BOOL gWiFiSymbolsResolved = NO;

static WiFiManagerClientGetDeviceFunc gGetDevice = NULL;
static WiFiDeviceClientCopyPropertyFunc gCopyProperty = NULL;
static WiFiDeviceClientCopyCurrentNetworkFunc gCopyCurrentNetwork = NULL;

/// 把框架拉进来，并且**一直留着**：`WiFiManagerClientCreate` 建的是到 wifid 的会话，
/// 每次采样重建一个既浪费也会让 wifid 那头不停看到新客户端。
static WiFiDeviceClient *wifiDevice(void)
{
    if (gWiFiResolved) {
        return gWiFiDevice;
    }
    gWiFiResolved = YES;

    gWiFiHandle = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi",
                         RTLD_LAZY);
    if (gWiFiHandle == NULL) {
        return NULL;
    }

    WiFiManagerClientCreateFunc create =
        (WiFiManagerClientCreateFunc)dlsym(gWiFiHandle, "WiFiManagerClientCreate");
    gGetDevice = (WiFiManagerClientGetDeviceFunc)dlsym(gWiFiHandle, "WiFiManagerClientGetDevice");
    gCopyProperty =
        (WiFiDeviceClientCopyPropertyFunc)dlsym(gWiFiHandle, "WiFiDeviceClientCopyProperty");
    gCopyCurrentNetwork =
        (WiFiDeviceClientCopyCurrentNetworkFunc)dlsym(gWiFiHandle, "WiFiDeviceClientCopyCurrentNetwork");

    gWiFiSymbolsResolved = (create != NULL && gGetDevice != NULL &&
                            gCopyProperty != NULL && gCopyCurrentNetwork != NULL);
    if (!gWiFiSymbolsResolved) {
        return NULL;
    }

    gWiFiManager = create(NULL, 0);
    if (gWiFiManager == NULL) {
        return NULL;
    }
    gWiFiDevice = gGetDevice(gWiFiManager);
    return gWiFiDevice;
}

BOOL helium_wifi_is_associated(void)
{
    WiFiDeviceClient *device = wifiDevice();
    if (device == NULL) {
        return NO;
    }

    WiFiNetwork *network = gCopyCurrentNetwork(device);
    if (network == NULL) {
        return NO;
    }
    // `Copy` 出来的，交回 CoreFoundation 管。
    CFRelease((CFTypeRef)network);
    return YES;
}

int32_t helium_wifi_rssi_dbm(void)
{
    WiFiDeviceClient *device = wifiDevice();
    if (device == NULL) {
        return 0;
    }

    CFPropertyListRef raw = gCopyProperty(device, CFSTR("RSSI"));
    if (raw == NULL) {
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
    return value;
}
