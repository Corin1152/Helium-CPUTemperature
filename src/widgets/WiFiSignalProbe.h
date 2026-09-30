//
//  WiFiSignalProbe.h
//  Helium
//
//  Wi-Fi 关联状态与接收功率。
//
//  ⚠️ 这个文件里的两条路**可靠性完全不同**，调用方必须区别对待：
//
//    * `helium_wifi_is_associated()` 走 `getifaddrs`（公开 API），安全、不会崩。
//    * `helium_wifi_rssi_dbm()` 走 MobileWiFi 私有框架，**未在真机验证过**。
//
//  所以「要不要显示 Wi-Fi」用前者判断，只有真的关联了才去碰后者。
//

#ifndef WiFiSignalProbe_h
#define WiFiSignalProbe_h

#include <stdint.h>

/// 是否连着一个 Wi-Fi 网络（网卡拿到了地址）。
///
/// 走 `getifaddrs`，**不碰私有框架** —— 这条判断必须绝对可靠，因为它是「要不要去
/// 调用 MobileWiFi」的闸门。返回 NO 时下面的函数根本不会被调用。
BOOL helium_wifi_is_associated(void);

/// 已关联网络的 RSSI，单位 dBm。真实读数恒为负；**0 表示「读不到」**。
///
/// 走 MobileWiFi 私有框架。**整个进程最多真正尝试一次** —— 见 WiFiSignalProbe.mm
/// 里的说明：那条路一旦有问题（卡住或崩溃），反复重试只会反复出问题。
///
/// 阻塞，调用方要放到后台队列上，且**不要**和蜂窝探针共用队列。
int32_t helium_wifi_rssi_dbm(void);

/// 诊断串：MobileWiFi 那条链走到了哪一步、断在哪。
///
/// 形如 `ok` / `disabled-after-failure` / `dlopen-failed` / `symbol-missing` /
/// `create-failed` / `get-device-failed` / `rssi-unreadable` / `not-attempted`。
///
/// 加这个是因为**无法在真机上调试**：只有它能区分「框架没加载」「符号改名了」
/// 「wifid 拒绝连接」这几种在界面上看起来一模一样的失败。
const char *helium_wifi_diagnosis(void);

#endif /* WiFiSignalProbe_h */
