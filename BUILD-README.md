# Statusbar — 基于 Helium 改版（新增「CPU温度」「CPU占用」「CPU频率」「蜂窝信号」部件）

## 这是什么

一份**已经改好代码的完整 Helium 源码**，在原有基础上新增了四个状态栏悬浮部件：
「CPU温度」（编号 10）、「CPU占用」（编号 11）、「CPU频率」（编号 12）、「蜂窝信号」（编号 13）。

版本：显示版本 **`0.04`**（`CFBundleShortVersionString`），构建号 `0.0.4`（`CFBundleVersion`）。
**应用名改为 `Statusbar`**（`CFBundleDisplayName` / `CFBundleName`），首页标题同步。

界面：只有**两页** —— 首页与自定义；**设置入口在首页右上角的齿轮**（sheet 弹出，不再是独立分页）。
那一页现在叫**「关于」**，只保留版本号与致谢，右上角一个「关闭」按钮直接退回首页（诊断、偏好设置、调试分组已移除）。
致谢页底部注明「基于 Helium 改版」（GPL-3.0 要求）。
产物：**`Statusbar.ipa`**。

## 追加（2026-09-29）：蜂窝信号（RSRP）

### 它是什么

参考信号接收功率，单位 dBm，**恒为负数**（约 -44 … -140），越接近 0 信号越好。
这是 4G/5G 里衡量基站信号强度的核心指标 —— 比系统状态栏那几格信号精确得多。

| 项目 | 内容 |
| --- | --- |
| 数据源 | CoreTelephony 私有接口 `CoreTelephonyClient.getSignalStrengthMeasurements:` → `CTSignalStrengthMeasurements.rsrp` |
| 显示格式 | `-95 dBm` / `-95` |
| 设置项 | 卡槽（自动 / 卡1 / 卡2）、是否显示单位、**状态行** |
| 存储字段 | `signalSlot`、`showUnit` |
| 权限 | **`com.apple.CommCenter.fine-grained = ["spi"]`**（`ent.plist` 里已加） |
| 最低系统 | iOS 13.0+ |

### 为什么它和前面三个不一样

**它是唯一一个「会静默失败」的部件。** 前面三个（CPU 温度/占用/频率）读不到就显示占位符，
原因只有一种；而这个部件在**没有 CommCenter 权限**时，取数调用**不抛异常、不打日志**，
只是永远拿不到值 —— 界面上和「没有服务」长得一模一样。

所以做了两件事：

1. `CellularSignalProbe.mm` 记录探针自己的状态（`pending` / `ok` / `unavailable`）；
2. 部件的设置页顶部有一行**状态**，`unavailable` 时会提示检查 CommCenter 权限。

`--` 到底是「无服务」还是「没权限」，只有那一行能区分。

### 另外两个实现要点

- **CoreTelephony 是运行时 dlopen 的。** Helium 不链接它，所以
  `NSClassFromString(@"CoreTelephonyClient")` 一开始会返回 Nil —— 必须先 dlopen
  `/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony`。
  私有类/方法全部按名字解析，改名或移除时降级为「读不到」，不会崩。
- **XPC 往返不能放在渲染路径上。** 与 CPU 频率同一个处理：后台串行队列每 3 秒采一次，
  渲染只读缓存；卡槽配置变了就立即重采（否则会短暂显示另一张卡的信号）。

### 权限只给了 `spi`

上游 CellularInfo 带的是完整 12 个值（它还要做 IPCC 安装、频段写入、eSIM 检测），
但读 RSRP 只需要 `spi` —— 依据是上游自己的能力判定代码：

```swift
static func hasCommCenterSPI() -> Bool {
    return EntitlementUtils.exists(["com.apple.CommCenter.fine-grained", "spi"])
}
```

而它 README 里「无需额外权利可以查询的数据」一节**不含 RSRP**。
真机上若读数一直是 `--` 且状态行显示「不可用」，再逐个补 `internal` 等值。

### 改动文件

| 文件 | 改动 |
| --- | --- |
| `ent.plist` | 新增 `com.apple.CommCenter.fine-grained = ["spi"]`（67 → 68 条） |
| `src/controllers/WidgetManager.swift` | 枚举新增 `cellularSignal = 13`；`WidgetDetails` 加名称与示例 |
| `src/widgets/CellularSignalProbe.{h,mm}` | **新增**：运行时解析 CoreTelephony 私有接口 + 状态上报 |
| `src/widgets/WidgetManager.mm` | 后台采样器 + 缓存；`formatParsedInfo` 加 `case 13` |
| `src/bridging/SwiftObjCPPBridger.{h,m}` | 新增 `HeliumCellularSignalStatusBridger()` |
| `src/views/widget/WidgetPreferencesView.swift` | 状态行 + 卡槽 + 单位；保存逻辑 |
| `src/views/widget/WidgetPreviewsView.swift` | 预览分支 |
| `layout/.../{en,zh-Hans}.lproj/Localizable.strings` | 各 +10 条 |

> `Makefile` 不用改：新 `.mm` 由 `widgets/*.mm` 的 wildcard 自动收。

---

## 追加（2026-09-30）：信号部件支持 Wi-Fi

「蜂窝信号」改名「信号」：连着 Wi-Fi 时显示 **Wi-Fi 接收功率（RSSI）**，断开后自动回到
**蜂窝 RSRP**。可以用设置项关掉，关掉后只看蜂窝。

### 刷新频率（三个部件的实际节拍）

| 部件 | 采样间隔 | 界面重绘 |
| --- | --- | --- |
| CPU 占用 | **0.25 秒** | 见下 |
| CPU 频率 | **3 秒** | 见下 |
| 信号（RSRP / Wi-Fi） | **3 秒** | 见下 |

界面重绘由「部件组」的 **Update Interval** 控制，默认 **1 秒**（编辑部件组页面里的滑杆，
范围 0.01–86400）。所以：

- CPU 占用：数值每 0.25 秒变一次，但**最快每秒才画一次**；
- CPU 频率与信号：数值每 3 秒变一次，界面每秒重绘也只会看到同一个数。

采样间隔是代码里的常量（`CPU_USAGE_CACHE_SECONDS` / `CPU_FREQUENCY_SAMPLE_SECONDS` /
`CELLULAR_SIGNAL_SAMPLE_SECONDS`），**不在界面上开放** —— 频率那个 3 秒是刻意的：
测频靠一段 15–20 ms 的满速忙循环，采太勤等于自己给自己造负载。

### Wi-Fi RSSI 怎么取的

走 MobileWiFi 私有框架（dlopen，不链接）：

    WiFiManagerClientCreate(NULL, 0)
      -> WiFiManagerClientGetDevice(manager)          // 与 wifid 的会话，一直留着
      -> WiFiDeviceClientCopyCurrentNetwork(device)   // 非空 = 已关联
      -> WiFiDeviceClientCopyProperty(device, CFSTR("RSSI"))

符号名取自 MobileWiFi 的公开头文件（`WiFiDeviceClient.h` / `WiFiManager.h`），不是猜的。

### ⚠️ 这个功能默认关闭，而且是实验性的

第一版**默认开启**，结果在真机上「启用后所有部件一起不显示」—— 因为 Helium 的每个部件
都由同一个进程绘制，而 MobileWiFi 那条链把进程带下去了。

现在改成三层防护：

1. **默认关**（`followNetwork` 默认 `NO`），用户显式打开才走这条路；
2. **关联判断改用 `getifaddrs`**（公开 API），只有确实连着 Wi-Fi 才去碰私有框架 ——
   不在 Wi-Fi 上时根本不进 MobileWiFi；
3. **Wi-Fi 采样走独立队列**，且整个进程**最多真正尝试一次**（latch）——
   那条路一旦有问题，每秒重试只会每秒出一次问题。

设置页的「来源」行会在失败时显示 `已连 Wi-Fi，但读不到 RSSI（原因）`，
原因是 `dlopen-failed` / `symbol-missing` / `create-failed` / `get-device-failed` /
`rssi-unreadable` 之一 —— 这是唯一能区分「框架没加载」「符号改名」「wifid 拒绝连接」
的地方。

### 「关联了但读不到 RSSI」时不切换

那种情况如果切成蜂窝数值，就会出现「明明在 Wi-Fi 上却显示蜂窝信号」。所以规则是
**连着 Wi-Fi 且真的读到 RSSI 才切**；读不到就静默退回蜂窝 —— 退化成原来的
纯蜂窝小部件，比一直显示 `--` 有用。

而这也正是部件设置页里那行「来源」存在的理由：Wi-Fi 与蜂窝的读数范围重叠
（都在 -40…-100 之间），光看数字分不出是哪一路；MobileWiFi 那条路一旦不通，
用户看到的只是「信号一直不变」，看不出原因。

### 权限

`ent.plist` 加了 `com.apple.developer.networking.wifi-info`（标准的
「Access Wi-Fi Information」能力，CPU-X 也带着它）。**不确定 wifid 是否校验它** ——
加了不亏，读不到时会退回蜂窝。

### 改动文件

| 文件 | 改动 |
| --- | --- |
| `src/widgets/WiFiSignalProbe.{h,mm}` | **新增**：MobileWiFi 运行时解析 |
| `src/widgets/WidgetManager.mm` | 采样器同时采蜂窝与 Wi-Fi；新增 `HeliumSignalSource()` |
| `src/bridging/SwiftObjCPPBridger.{h,m}` | 新增 `HeliumSignalSourceBridger()` |
| `src/controllers/WidgetManager.swift` | 显示名「蜂窝信号」→「信号」 |
| `src/views/widget/WidgetPreferencesView.swift` | 新增「来源」行与「连接 Wi-Fi 时显示 Wi-Fi 信号」开关 |
| `ent.plist` | +`com.apple.developer.networking.wifi-info`（69 条） |
| 两份 `Localizable.strings` | +5 条 |

> `Makefile` 不用改：新 `.mm` 由 `widgets/*.mm` 的 wildcard 自动收。

---

## 追加（2026-09-29）：CPU占用 / CPU频率

### 部件一览

| 项目 | CPU占用（11） | CPU频率（12） |
| --- | --- | --- |
| 数据源 | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`，两次采样求差 | `CPUFrequencyProbe.mm` 的周期计数忙循环实测 |
| 显示格式 | `37%` / `37.4%` | `2.39 GHz` / `2390 MHz` |
| 设置项 | 统计方式（平均 / 最高核心）、小数位（0 / 1）、是否显示 `%` | 频率单位（GHz / MHz） |
| 存储字段 | `usageMode`、`decimals`、`showPercentage` | `freqUnit` |
| 权限 | 无 | 无 |

两个部件都**不需要新的 entitlement** —— `host_processor_info` 与内联汇编对沙箱 App 都是开放的。
（旁边的「CPU温度」要 `no-sandbox`，那是因为 IOReport 要，两者无关。）

### 两个实现要点

**占用率必须两次采样求差。** 内核给的是**累计 tick 计数**，不是百分比。而 Helium 的
`formattedAttributedString()` 是无状态纯函数、由定时器驱动重绘，所以上一次的 tick 存在
文件级 `static` 里 —— 这正是网速部件算 `prevOutputBytes` 用的同一招。
另外缓存了 0.25 秒的计算结果：同一组里放两个 CPU 部件时，第二次调用才不会把第一次的差值吃掉。

**频率探针绝不能在渲染路径上跑。** 它是一段约 15–20 ms 的满速忙循环（原理见
`CPUFrequencyProbe.mm` 的文件头注释），放主线程上就是肉眼可见的卡顿。所以它跑在自己的
串行队列上，每 3 秒采一次，渲染路径**只读缓存**。3 秒这个间隔还有第二层原因：探针为了读到
有意义的数字会先把所在核心的频率顶上去，采样太勤就变成「部件自己造成了它测到的那部分负载」。

读不到时显示 `--`（与旁边温度部件的 `??ºC` 同一个约定）。

### 改动文件

| 文件 | 改动 |
| --- | --- |
| `src/controllers/WidgetManager.swift` | 枚举新增 `cpuUsage = 11`、`cpuFrequency = 12`；`WidgetDetails` 加名称与示例 |
| `src/widgets/WidgetManager.mm` | `host_processor_info` 差分 + 频率缓存读取；`formatParsedInfo` 加 `case 11` / `case 12` |
| `src/widgets/CPUFrequencyProbe.{h,mm}` | **新增**：周期计数探针（移植自 SysProbe，Apache-2.0） |
| `src/views/widget/WidgetPreferencesView.swift` | 两个部件的设置页 UI + 保存逻辑 |
| `src/views/widget/WidgetPreviewsView.swift` | 两个预览分支 |
| `layout/.../{en,zh-Hans}.lproj/Localizable.strings` | 各 +7 条 |

> `Makefile` **不用改**：它的 `$(wildcard $(SRC_DIR)/widgets/*.mm)` 会自动收下新文件。

---

# 原有内容（CPU温度部件）

## 这是什么（CPU温度）

一份**已经改好代码的完整 Helium 源码**，新增了「CPU 温度」状态栏悬浮部件。
你只需要在一台 Mac 上跑一条命令，就能得到可直接用巨魔（TrollStore）安装的 `.ipa`。

新增部件与现有「设备温度」部件完全同构：

| 项目 | 现有「设备温度」 | 新增「CPU温度」 |
| --- | --- | --- |
| 编号 | 3 | 10 |
| 数据源 | `IOPMPowerSource`（**电池**温度） | IOReport CPU die 通道（**SoC/CPU** 温度） |
| 显示格式 | `26.02ºC` | `42.50ºC` |
| 设置项 | 温度单位 → 摄氏 / 华氏 | 温度单位 → 摄氏 / 华氏 |
| 存储字段 | `useFahrenheit` | `useFahrenheit` |

> 关键点：现有 HUD 里的「设备温度」读的是**电池**温度，不是 CPU 温度。这是两个不同的东西，所以本补丁是**新增一个部件**，而不是修改原有的。

## 目录结构

```
build.sh                          ← 一键构建脚本（在 Mac 上运行这个）
README.md                         ← 本文件
Helium-CPUTemperature.patch       ← 代码补丁（unified diff，供对照/审阅）
Helium/                           ← 已打好补丁的完整源码树
  ├── Makefile  ipabuild.sh  ent.plist  hud-prefix.pch
  ├── src/                        ← Swift + ObjC++ 源码（改动在这里）
  └── layout/                     ← 资源、多语言文案
theos/                            ← 构建工具链（已内含，无需下载）
tools/                            ← ldid 签名工具（macOS arm64 + x86_64 各一份）
.github/workflows/build.yml       ← 备用：GitHub Actions 构建配置
```

> **构建全程离线**：工具链和签名工具都已打包在内，代编译时不需要访问 GitHub、不需要 Homebrew。
> 唯一前提是机器装了**完整版 Xcode**（提供 iOS SDK）。

改动共 6 个文件（+220 / −3）：

| 文件 | 改动内容 |
| --- | --- |
| `src/controllers/WidgetManager.swift` | 枚举新增 `cpuTemperature = 10`，加上名称与示例值 |
| `src/widgets/WidgetManager.mm` | IOReport 读取实现 + `case 10` 渲染分支 |
| `src/views/widget/WidgetPreferencesView.swift` | 设置页 UI + 保存逻辑 |
| `src/views/widget/WidgetPreviewsView.swift` | 预览分支 |
| `layout/.../en.lproj/Localizable.strings` | 英文文案 `CPU Temperature` |
| `layout/.../zh-Hans.lproj/Localizable.strings` | 中文文案 `CPU温度` |

## 怎么构建（选一条）

### 路线 A：有一台 Mac（自己/朋友/代编译）

macOS + **完整版 Xcode**（不能只有 Command Line Tools）即可。**不需要联网。**

```bash
chmod +x build.sh
./build.sh
```

全程自动：校验环境 → 装载内置 Theos → 匹配本机 iOS SDK → 部署内置 ldid → 编译 → 产出安装包。约 5-15 分钟。
跑完会在当前目录得到 `Statusbar.ipa`。

> 首次运行若弹出「ldid 来自身份不明的开发者」被系统拦截，到
> **系统设置 → 隐私与安全性** 点「仍要允许」，然后重跑一次即可。

常用参数：

```bash
./build.sh --sdk 17.0                       # 强制指定 iOS SDK 版本
./build.sh --theos ~/my-theos               # 改用自己已有的 Theos
./build.sh --proxy https://ghproxy.net/     # 仅在包内工具链缺失、需联网下载时用
```

### 路线 B：GitHub Actions（需要 GitHub 账号）

把 `Helium/` 整个目录推到一个自己的仓库，把下面这个文件放到仓库的
`.github/workflows/build.yml`，然后在 Actions 页点 `Run workflow`，产物在 Artifacts 里下载。

> workflow 内容见原包内 `.github/workflows/build-cputemp.yml`（若被删，可用 `Helium-CPUTemperature.patch` 对照重建）。

### 路线 C：云端 Mac（无 Mac 时）

租一台云端 macOS（如 MacinCloud 按小时计费），远程连上去后同样执行路线 A 的命令。

## 安装与使用

1. 把 `Statusbar.ipa` 传到 iPhone（隔空投送 / 微信 / 数据线均可）
2. 在 iPhone 上用「文件」或微信打开，选择 **TrollStore（巨魔）** 安装
3. 打开 Helium → **Customize** → 添加部件 → 列表里会出现「**CPU温度**」
4. 点进该部件可设置温度单位（摄氏 / 华氏），与现有温度部件用法一致

## 技术说明

读取走的是 iOS 私有框架 IOReport 的 CPU die 温度通道，并通过 `dlopen + dlsym`
**运行时动态解析**符号，因此：

- 符号不存在时**不会崩溃**，只显示 `??ºC`
- 做了三重兜底：多候选通道组名、温度单位自适应（℃ / 0.1℃ / 0.01℃ 按量级判定）、订阅缓存 + 失败退避重试
- 需要 `ent.plist` 里的 `no-sandbox` + `iokit-properties` 权限（源码里已带）

**若装完显示 `??ºC`**：说明该机型/系统版本的 IOReport 温度通道不可用，属预期降级行为，不是 bug。
把机型 + 系统版本反馈给开发者，可再补兜底通道。

## 开源许可

原项目 Helium 为 GPL-3.0（作者 leminlimez / AsakuraFuuko）。本补丁同样遵循 GPL-3.0。
