# Helium — 新增「CPU温度」部件（已打补丁源码 + 一键构建包）

## 这是什么

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
跑完会在当前目录得到 `Helium-CPUTemperature.ipa`。

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

1. 把 `Helium-CPUTemperature.ipa` 传到 iPhone（隔空投送 / 微信 / 数据线均可）
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
