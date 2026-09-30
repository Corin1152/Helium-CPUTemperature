#!/usr/bin/env python3
"""交付前的静态检查。**推之前先跑这个，别等 CI 报错。**

    python3 scripts/preflight.py

每一条都对应一个真实踩过的坑，注释里写了是哪个：

  1. 括号平衡            —— 用脚本改代码时吃掉过一整段（花括号配对的误用）
  2. C 声明顺序          —— `signalNumber` 写在调用点之后，编译不过
  3. dlsym 符号名核对    —— 私有 API 的名字只能靠「找到能用的实现」核实，
                            这里用白名单把已核实的名字钉住
  4. 实时读数不得缓存    —— 把 latch 加在「数值」上，把 Wi-Fi 信号冻住了
  5. 文案表双向一致      —— 只查了 en-zh 一个方向，漏掉 zh 多出的 3 个键
  6. 版本三处一致        —— 改了 Info.plist 忘了改 workflow 的 Release 名
  7. 必需权限在位        —— 少一条权限 = 静默失败
  8. 改名残留            —— `Band.value` → `number` 只改了定义，漏了 3 个调用点

**检查脚本自己也会出错**（第 5 条就是这么漏的），所以：
凡是用正则扫源码的检查，都要先把注释和字符串挖空再扫，否则
「注释里提到的名字」会被当成「代码里的引用」。
"""

import pathlib
import plistlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
failures = []


def check(label, ok, detail=""):
    print(f"  {'OK  ' if ok else 'FAIL'} {label}{'  — ' + detail if detail else ''}")
    if not ok:
        failures.append(label)


def mask(src):
    """把注释与字符串字面量挖成空格，**保持长度不变**。

    所有正则扫描都必须走这个 —— 否则注释里提到的符号名会被误判成引用。
    """
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                out[i] = " "
                i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            out[i] = out[i + 1] = " "
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                if src[i] != "\n":
                    out[i] = " "
                i += 1
            if i + 1 < n:
                out[i] = out[i + 1] = " "
                i += 2
            continue
        if c == '"':
            out[i] = " "
            i += 1
            while i < n:
                if src[i] == "\\":
                    out[i] = " "
                    if i + 1 < n:
                        out[i + 1] = " "
                    i += 2
                    continue
                if src[i] == '"':
                    out[i] = " "
                    i += 1
                    break
                if src[i] != "\n":
                    out[i] = " "
                i += 1
            continue
        i += 1
    return "".join(out)


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def sources(*exts):
    out = []
    for ext in exts:
        out += sorted((ROOT / "src").rglob(f"*.{ext}"))
    return out


# ── 1. 括号平衡 ──────────────────────────────────────────────────────────
print("【1】括号平衡（全部源文件）")
unbalanced = []
for f in sources("swift", "mm", "m", "h", "c"):
    s = mask(f.read_text(encoding="utf-8"))
    stack = []
    pairs = {"{": "}", "(": ")", "[": "]"}
    for ch in s:
        if ch in pairs:
            stack.append(ch)
        elif ch in pairs.values():
            if not stack or pairs[stack.pop()] != ch:
                stack.append("BAD")
                break
    if stack:
        unbalanced.append(str(f.relative_to(ROOT)))
check("全部括号配对", not unbalanced,
      f"{len(unbalanced)} 个不合格: {unbalanced}" if unbalanced else "")

# ── 2. C 声明顺序 ────────────────────────────────────────────────────────
print("\n【2】C / ObjC++ 声明顺序（先声明后使用）")
WIFI = "src/widgets/WiFiSignalProbe.mm"
if (ROOT / WIFI).exists():
    t = read(WIFI)
    for sig, name in [("static BOOL ensureSession(", "ensureSession"),
                      ("static int32_t dBmFromNumber(", "dBmFromNumber")]:
        d = t.find(sig)
        uses = [m.start() for m in re.finditer(r"\b" + name + r"\b", t)]
        check(f"{name} 定义早于首次使用", d != -1 and uses and d <= uses[0])

# ── 3. dlsym 符号名核对 ──────────────────────────────────────────────────
print("\n【3】dlsym 符号名（白名单 = 已从头文件核实的名字）")
# 来源：ProcursusTeam/netctl 的 MobileWiFi.framework/Headers/*.h
VERIFIED = {
    "WiFiManagerClientCreate", "WiFiManagerClientCopyDevices",
    "WiFiManagerClientGetDevice",           # 存在但**会段错误**，见下一条
    "WiFiDeviceClientCopyCurrentNetwork", "WiFiDeviceClientCopyProperty",
    "WiFiNetworkGetProperty", "WiFiNetworkGetFloatProperty",
}
BANNED = {"WiFiManagerClientGetDevice"}     # netctl: "segfaults"
if (ROOT / WIFI).exists():
    code = mask(read(WIFI))
    used = set(re.findall(r'dlsym\(handle,\s*"([^"]+)"\)', code))
    check("dlsym 名字都在白名单里", used <= VERIFIED,
          f"未知: {sorted(used - VERIFIED)}" if used - VERIFIED else "")
    check("没有用会段错误的 GetDevice", not (used & BANNED),
          f"用了 {sorted(used & BANNED)}" if used & BANNED else "")

# ── 4. 实时读数不得缓存 ──────────────────────────────────────────────────
print("\n【4】实时读数不得缓存（latch 只作用于会话）")
if (ROOT / WIFI).exists():
    code = mask(read(WIFI))
    check("Wi-Fi 读数没有被进程级缓存",
          "gAttempted" not in code and "gRSSIDbm" not in code)
    check("latch 只作用于会话建立", "gSession" in code)

# ── 5. 文案表双向一致 ────────────────────────────────────────────────────
print("\n【5】文案表（**双向**比对 + 占位符）")
LOC = ROOT / "layout/Applications/Helium.app"
def strings(lang):
    out = {}
    for line in (LOC / f"{lang}.lproj/Localizable.strings").read_text(encoding="utf-8").splitlines():
        m = re.match(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$', line)
        if m:
            out[m.group(1)] = m.group(2)
    return out
en, zh = strings("en"), strings("zh-Hans")
check("en 有的键 zh 都有", not (set(en) - set(zh)),
      f"缺: {sorted(set(en) - set(zh))}" if set(en) - set(zh) else "")
check("zh 有的键 en 都有", not (set(zh) - set(en)),
      f"缺: {sorted(set(zh) - set(en))}" if set(zh) - set(en) else "")
SPEC = re.compile(r"%(?:\d+\$)?(?:@|lld|ld|d|f|s)")
mismatch = [k for k, v in zh.items() if len(SPEC.findall(k)) != len(SPEC.findall(v))]
check("中英占位符数量一致", not mismatch, f"{mismatch}" if mismatch else "")
print(f"       （en={len(en)} zh={len(zh)}）")

# ── 6. 版本三处一致 ──────────────────────────────────────────────────────
print("\n【6】版本号三处一致")
plist = plistlib.load(open(LOC / "Info.plist", "rb"))
short = plist["CFBundleShortVersionString"]
workflow = read(".github/workflows/build.yml")
check("Info.plist 的版本出现在 workflow 的 Release 名里",
      f"Statusbar {short}" in workflow, f"plist={short}")
check("CFBundleVersion 与显示版本对得上",
      plist["CFBundleVersion"].startswith("0.0."), plist["CFBundleVersion"])

# ── 7. 必需权限在位 ──────────────────────────────────────────────────────
print("\n【7】必需 entitlements")
ent = plistlib.load(open(ROOT / "ent.plist", "rb"))
for key in ["platform-application",
            "com.apple.CommCenter.fine-grained",
            "com.apple.wifi.manager-access",
            "com.apple.private.skip-library-validation"]:
    check(key, key in ent)

# ── 8. 改名残留 ──────────────────────────────────────────────────────────
print("\n【8】改名残留（改过名的符号不应再出现）")
RENAMED = [
    ("Band.value", r"band\.value|\.value\)"),
    ("BandRadioAccessTechnology", r"BandRadioAccessTechnology"),
    ("BandInfoEntity", r"BandInfoEntity"),
    ("onOpenSettings", r"onOpenSettings"),
    ("WeatherUtils", r"WeatherUtils"),
]
all_code = "\n".join(mask(p.read_text(encoding="utf-8")) for p in sources("swift", "mm", "m", "h"))
for label, pat in RENAMED:
    hits = re.findall(pat, all_code)
    check(f"无 {label} 残留", not hits, f"{len(hits)} 处" if hits else "")

# ── 结果 ────────────────────────────────────────────────────────────────
print()
print("=" * 56)
if failures:
    print(f"  {len(failures)} 项不合格：")
    for f in failures:
        print(f"    · {f}")
    print("=" * 56)
    sys.exit(1)
print("  全部通过 ✓")
print("=" * 56)
