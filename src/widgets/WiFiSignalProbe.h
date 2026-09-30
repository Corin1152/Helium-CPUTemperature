//
//  WiFiSignalProbe.h
//  Helium
//
//  Wi-Fi 关联状态与接收功率。
//
//  ⚠️ 两条路的可靠性不同：
//
//    * `helium_wifi_is_associated()` 走 `getifaddrs`（公开 API），安全。
//    * `helium_wifi_rssi_dbm()` 走 MobileWiFi 私有框架。
//
//  所以「要不要显示 Wi-Fi」用前者判断，只有真的关联了才去碰后者。
//

#ifndef WiFiSignalProbe_h
#define WiFiSignalProbe_h

#include <stdint.h>

/// 是否连着一个 Wi-Fi 网络（网卡拿到了地址）。
///
/// 走 `getifaddrs`，不碰私有框架 —— 这条判断是「要不要去调用 MobileWiFi」的闸门。
BOOL helium_wifi_is_associated(void);

/// 已关联网络的 RSSI，单位 dBm。真实读数恒为负；**0 表示「读不到」**。
///
/// 走 MobileWiFi 私有框架。**整个进程最多真正尝试一次** —— 见 .mm 里的说明。
///
/// 阻塞，调用方要放到后台队列上，且**不要**和蜂窝探针共用队列。
int32_t helium_wifi_rssi_dbm(void);

/// 诊断串：MobileWiFi 那条链走到了哪一步、断在哪。
///
/// 形如 `ok` / `dlopen-failed` / `symbol-missing` / `create-failed` /
/// `no-device` / `rssi-unreadable` / `not-attempted`。
const char *helium_wifi_diagnosis(void);

#endif /* WiFiSignalProbe_h */
