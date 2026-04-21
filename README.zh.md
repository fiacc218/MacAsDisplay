# MacAsDisplay

[English](README.md) | **中文**

把闲置的旧 Mac 变成新 Mac 的副屏 —— 通过 Thunderbolt Bridge 或 Wi-Fi。
HEVC 硬件编码，30 fps 原生 retina 分辨率，好链路下延迟约 1 帧。

> 状态: **alpha / 作者日常使用**。使用了 macOS 私有 API
> (`CGVirtualDisplay`),无法上架 App Store,未来 macOS 版本可能失效。
> 详见 [限制](#限制)。

---

## 这是什么

```
┌──────────────┐  HEVC/UDP + HMAC 控制   ┌──────────────┐
│   Sender     │──────────────────────▶  │   Receiver   │
│ (主 Mac)     │   Thunderbolt / Wi-Fi   │  (旧 Mac)    │
│              │                         │              │
│ 虚拟显示器   │                         │ 硬解码器     │
│ ScreenCapture│                         │ Metal 渲染   │
│ VT 编码器    │                         │ 全屏显示     │
└──────────────┘                         └──────────────┘
```

- **Sender**(发送端): 创建一个 headless 虚拟显示器,用 ScreenCaptureKit
  捕获,经 VideoToolbox 硬件编码为 HEVC,通过 UDP 发送。
- **Receiver**(接收端): 接收 / 重组,硬件解码,Metal 全屏渲染。
- **仅显示,不转发输入。** macOS 的多显示器原生光标路由处理剩下的一切。

## 为什么不用 …

| 工具 | 为什么不合适 |
|---|---|
| **Sidecar** | 只支持 iPad。 |
| **Universal Control** | Mac 间共享光标 / 键盘,不是副屏。 |
| **AirPlay to Mac** | 1080p 封顶,延迟高,Apple 独占。 |
| **Luna / Duet** | 商业,闭源,订阅。 |
| **DDC over USB-C** | 副屏面板需支持 DP-in(老 MBP 不支持)。 |

做 MacAsDisplay 是因为你有一台性能完好的旧 Mac 放在抽屉里,想免费把它
当成 ~3K 30fps 的副屏,用你手头已有的线。

## 环境要求

| 角色 | 要求 |
|---|---|
| 两端 | macOS 14+ (Sonoma)、Xcode 15+、[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) |
| Sender | Apple Silicon,或带 HEVC 硬编的较新 Intel |
| Receiver | 任何带 HEVC 硬解的 Mac(Intel 第 7 代以上 / 所有 Apple Silicon) |
| 链路 | **Thunderbolt Bridge** 直连(推荐),或共享 Wi-Fi |

## 构建

```sh
git clone https://github.com/fiacc218/MacAsDisplay.git
cd MacAsDisplay
xcodegen generate
open MacAsDisplay.xcodeproj
```

两个 scheme: **Sender** 和 **Receiver**,分别在对应机器上构建。

### 代码签名(可选,但强烈推荐)

默认签名是 ad-hoc (`CODE_SIGN_IDENTITY = -`),不配置 Apple ID 也能
`xcodebuild`。代价是 macOS TCC 每次 rebuild 都把签名身份视为新身份,
**你得在每次 rebuild 后重新授权一次"屏幕录制 / 本地网络"**。

避免做法:创建一个本地的 gitignored `Config.xcconfig`:

```sh
cp Config.xcconfig.example Config.xcconfig
# 编辑 Config.xcconfig,填入你自己的签名身份指纹
# (Apple Development 或 Developer ID)。
```

TCC 按签名身份绑定授权 —— 有稳定证书后 rebuild 无需重新授权。

## 部署和运行

### 1. Sender (在你的主 Mac 上)

```sh
xcodebuild -scheme Sender -configuration Debug \
    -derivedDataPath build build
open build/Build/Products/Debug/MacAsDisplaySender.app
```

首次启动会触发 **屏幕录制** 和 **本地网络** 的 TCC 弹窗。在"系统设置"里
授权后重启 app。

Sender 是**菜单栏 app**(`LSUIElement`,无 Dock 图标)。点图标打开气泡 ——
目标主机、开始 / 停止、状态。

> **刘海屏 MBP(14"/16") 用户注意:** 菜单栏图标可能被挤到刘海后面看
> 不见。可以用 `VS_AUTOSTART=1` 完全绕过 UI,见 [无头运行](#无头运行)。

### 2. Receiver (在你的旧 Mac 上)

```sh
# 如果从 Apple Silicon 交叉编译到 Intel:
xcodebuild -scheme Receiver -configuration Debug \
    -derivedDataPath build -arch x86_64 ONLY_ACTIVE_ARCH=NO build

# 然后把 .app 拷到旧 Mac,运行:
open /path/to/MacAsDisplayReceiver.app
```

Receiver 会打开一个全屏黑色窗口,每 2 秒广播一次自身能力。按 **ESC**
退出全屏,再按 ESC 退出 app。

## 首次配对(PSK)

MacAsDisplay 用 32 字节预共享密钥(PSK)认证控制信道(每个控制包做
HMAC-SHA256,基于 nonce 防重放)。首次启动时每端会自动生成 PSK 于:

```
~/.config/macasdisplay/psk
```

**把这个文件拷到另一台机器**(同路径)才能互通:

```sh
scp ~/.config/macasdisplay/psk user@receiver-mac:~/.config/macasdisplay/psk
```

两端都会在启动时打印 `PSK fp=<前 16 hex>`。**两端指纹必须一致**,否则
控制包会被静默丢弃。

临时测试可以用环境变量 `VS_PSK_HEX=<64 hex>` 覆盖文件。

## 指定目标主机

Sender 需要知道把包发到哪。三种方式:

### 方式 A —— 菜单栏气泡(交互式)

点状态栏图标,在 **Target** 里填 Receiver 的 IP,点 **Start**。
会持久化到 `defaults`,下次启动自动填。

### 方式 B —— `defaults` 命令行(脚本化)

```sh
defaults write xyz.dashuo.macasdisplay.sender VS.targetHost 192.168.1.99
```

查 Receiver IP:

- **Thunderbolt Bridge:** 在 Receiver 上 `ifconfig bridge0 | grep 'inet '`
  (通常是 `169.254.x.x` link-local)。
- **Wi-Fi:** 在 Receiver 上 `ipconfig getifaddr en0`。

### 方式 C —— 自动学习(零配置)

若 Receiver 先发 Hello / Capability 给已知主机,Sender 从 `recvfrom`
的源地址里学到对端 → 双向通。实际使用时还是用 A 或 B 设一次目标,
自动学习主要用来应对 IP 变化。

## Thunderbolt Bridge 配置(推荐)

TB Bridge 是点对点线缆,10+ Gbps,亚毫秒 RTT,不和 Wi-Fi / AWDL /
Bonjour 抢信道。

1. 两台 Mac 用 TB3/TB4 线连起来。
2. **系统设置 → 网络 → Thunderbolt Bridge → 详细信息 → TCP/IP →
   配置 IPv4: 手动** —— 分别设 `169.254.0.1` / `169.254.0.2`
   (或任意同一 /16 网段的一对地址)。
3. 验证:从对面 `ping -c 3 169.254.0.2`。
4. 把 Receiver 的 TB IP 设成 Sender 的 `VS.targetHost`。

**Jumbo frames (可选):** 两端都把 `bridge0` 的 MTU 调到 9000,大 I-frame
就不会爆成几百个 1500 字节分片,显著降低丢包敏感度。

```sh
sudo ifconfig bridge0 mtu 9000
```

## 使用

1. **先启动 Receiver** —— 进入全屏黑色窗口。
2. **启动 Sender** —— 菜单栏出现图标,`Target` 会从 Receiver 的广播里
   自动填上。
3. 点 **Start**。Sender 上出现一个 30fps 的新虚拟显示器,尺寸匹配
   Receiver 面板。拖一个窗口过去,亮了。

## 无头运行

```sh
VS_AUTOSTART=1 open -n /path/to/MacAsDisplaySender.app
```

Sender 不显示任何 UI,等 ~1.5 秒收到 Receiver 的 Capability 后自动开始推流。
适合菜单栏被刘海挤掉的情况。

## 疑难排查

### Receiver 一直黑屏

1. Sender 真的点了 **Start** 吗?(自动学习不会自动推流,你得主动启动。)
2. 两端 PSK 指纹一致吗?检查两端日志的 `PSK fp=...`。
3. 防火墙放行 UDP 52100 (视频) 和 52101 (控制) 了吗?
4. 试试两端用 `VS_PSK_HEX=...` 排除 PSK 文件问题。

### "用户拒绝了应用程序...捕捉的 TCC" (-3801)

Sender 需要 **屏幕录制** 权限。系统设置 → 隐私与安全 → 录屏与系统录音
→ 开关打开。如果开关已经是开的,关掉再开(TCC 缓存过期签名):

```sh
tccutil reset ScreenCapture xyz.dashuo.macasdisplay.sender
```

**重要:** 重命名过 bundle id 或换过签名身份后,Launch Services 可能
还缓存着旧的 TCC 拒绝记录,即使你在系统设置里勾上了也没用。需要:

```sh
/System/Library/Frameworks/CoreServices.framework/Versions/Current/\
Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
  -f -R -trusted /path/to/MacAsDisplaySender.app
```

然后重启 Sender。

### 旧 Mac 老进屏保

```sh
caffeinate -d -i -s -w $(pgrep MacAsDisplayReceiver)
```

在 Receiver 进程存活期间禁用屏保 / 待机 / 休眠。

### 菜单栏图标看不见

14"/16" MBP 的刘海会把右侧图标挤没。解决办法:

- 用 [Bartender](https://www.macbartender.com/) 或 [Hidden Bar](https://github.com/dwarvesf/hidden)。
- 用无头模式: `VS_AUTOSTART=1`。

### 偶发 `-17694` 解码错误

通常发生在丢包 / 网络抖动后;下一个关键帧到达后自动恢复(Receiver 会
主动请求)。不用管。

### 旧 Intel Mac 上 WindowServer 崩溃

已在 MetalRenderer 修复 —— 改用 displayLink 拉帧 + 2 帧 GPU 背压。
如果你还遇到,说明你在较旧的 commit 上,更新代码即可。

## 安全模型

- 控制信道 **经 PSK + HMAC-SHA256 认证** 且 **防重放**
  (按 peer 维护 nonce 高水位)。
- 视频负载 **未加密**。同一链路上的人可以嗅包还原画面。
- **不要在不受信任的网络上运行。** 用 Thunderbolt Bridge 或私有局域网。
  详见 [SECURITY.md](SECURITY.md)。

## 限制

- **`CGVirtualDisplay` 是 macOS 私有 API。** 运行时 `dlopen` 符号,Apple
  随时可能改 / 移除。无法上架 App Store。
- **不转发输入。** 刻意设计。用 Sender 自己的键鼠,macOS 原生就会把
  光标路由到虚拟显示器。
- **无音频。** 仅视频。
- **每个 Sender session 只支持单个虚拟显示器。**
- **链路差 → 关键帧变多。** Receiver 遇丢包会请求关键帧,消耗带宽。
  Wi-Fi 可用,TB Bridge 最佳。

## 贡献

欢迎 Issue 和 PR。提交涉及协议 / 认证的改动前请先读
[SECURITY.md](SECURITY.md)。

## 协议

Apache License 2.0。见 [LICENSE](LICENSE)。

MacAsDisplay 与 Apple Inc. 无任何隶属或背书关系。
