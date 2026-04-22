# MacAsDisplay

[English](README.md) | **中文**

两台 Mac 的副屏 App。旧 Mac 作为新 Mac 的第二显示器,走 Wi-Fi 或
Thunderbolt Bridge。

> alpha · 使用 `CGVirtualDisplay`(私有 macOS API)· 不可上架 App
> Store · 见[限制](#限制)

```
┌──────────────┐   HEVC over UDP + HMAC   ┌──────────────┐
│   主 Mac     │ ───────────────────────▶ │   副屏 Mac   │
│  (Sender)    │    Wi-Fi / Thunderbolt   │  (Receiver)  │
└──────────────┘                          └──────────────┘
```

## 技术亮点

- **HEVC 硬件编解码**(VideoToolbox)· 30 fps · 原生 retina 分辨率 ·
  良好链路下 ~1 帧延迟
- **一个已公证 DMG** · 两台 Mac 装同一份 `.app` · 首启选角色 ·
  Developer ID 签名,无 Gatekeeper 警告
- **零配置配对** · 内置 PSK · HMAC-SHA256 认证的控制信道 + nonce 抗重放
- **自动发现** · 主 Mac 通过 UDP 广播在局域网 / 雷雳桥上发现副屏
- **Universal 二进制**(arm64 + x86_64)· 两端都支持 Apple Silicon 和
  支持 HEVC 的 Intel Mac
- **多语言** · 简体中文 / English,跟随系统语言
- **免费、开源** · MIT

## 要求

| | |
|---|---|
| **主 Mac** | macOS 14+,支持 HEVC 硬编(Apple Silicon / Intel 第 7 代+) |
| **副屏 Mac** | macOS 14+,支持 HEVC 硬解(Apple Silicon / Intel 第 7 代+) |
| **链路** | 同一 Wi-Fi,或 Thunderbolt 3/4 线 |

## 安装

1. 下载 **[MacAsDisplay.dmg](https://github.com/fiacc218/MacAsDisplay/releases/latest)**
2. 打开 DMG,把 `MacAsDisplay.app` 拖到**两台 Mac 的**应用程序文件夹
3. 双击启动

## 使用

每台 Mac 首启时选角色:

- **Main Mac** —— 发送屏幕(Sender),驻留在菜单栏
- **Secondary Display** —— 接收并全屏渲染(Receiver)

之后:

1. 先启动**副屏 Mac** —— 会全屏并广播身份,屏幕上列出本机 IP。
2. 启动**主 Mac** —— `Target` 自动填入副屏 IP(多网卡场景从下拉
   菜单里选)。
3. 提示时授予**录屏**权限。
4. 点 **Start**。出现一个 30 fps 的虚拟显示器 —— 把窗口拖过去即可。

切换角色:菜单栏图标 → **Switch Role…**,或副屏 Receiver 全屏时按
**ESC** 显示控制条。

## 网络

同一 Wi-Fi 开箱即用,自动发现副屏。HEVC 30 fps retina 大约 ~20-50 Mbps。

Thunderbolt Bridge(可选,追求最大带宽):

1. 两台 Mac 用 TB3/TB4 线连起来。
2. **系统设置 → 网络 → Thunderbolt Bridge → 详细信息 → TCP/IP →
   使用 DHCP 并填手动地址** —— 给两台分配 `169.254.0.1` / `169.254.0.2`
   (或同一 /16 的任一对)。
3. `sudo ifconfig bridge0 mtu 9000` 两端都跑启用 jumbo frames。

## 安全模型

- 控制信道:HMAC-SHA256 + 对端 nonce 高水位,抗重放。
- 内置默认 PSK,首装零配置即可通信。
- 视频负载**不加密** —— 用可信 Wi-Fi 或雷雳直连,**别在公网上跑**。
- 自定义 PSK:
  `head -c 32 /dev/urandom > ~/.config/macasdisplay/psk`,再 `scp` 到另
  一台。详情见 [SECURITY.md](SECURITY.md)。

## 故障排查

**副屏一直黑屏。** 主 Mac 上点了 **Start** 吗?两端日志找一下 `PSK fp=…`
—— 指纹必须一致。

**授权了录屏仍报 "User denied screen capture"。** 旧版本签名在 TCC 里
留了条过时条目:
```sh
tccutil reset ScreenCapture xyz.dashuo.macasdisplay
```
大版本首装会遇到一次,之后升级都会保留授权。

**刘海屏 MBP 看不到菜单栏图标。** 用
[Bartender](https://www.macbartender.com/) /
[Hidden Bar](https://github.com/dwarvesf/hidden),或 `VS_AUTOSTART=1`
跑无界面模式。

## 限制

- `CGVirtualDisplay` 是私有 macOS API,Apple 可能随时改动。不能上
  App Store。
- **不转发输入**(设计如此)。用主 Mac 的鼠标键盘,macOS 原生会跨虚拟
  显示器路由鼠标。
- 无音频。
- 每个主 Mac 会话只开一个虚拟显示器。

## 从源码构建

```sh
git clone https://github.com/fiacc218/MacAsDisplay.git
cd MacAsDisplay
brew install xcodegen
./build.sh                    # → build/Build/Products/Debug/MacAsDisplay.app
```

`build.sh` 会在 `project.yml` 变动时重新生成 xcodeproj。想用 IDE:
`xcodegen generate && open MacAsDisplay.xcodeproj`。

改有线协议或认证相关的 PR 前请先看 [SECURITY.md](SECURITY.md)。

## 许可

MIT。见 [LICENSE](LICENSE)。

本项目与 Apple Inc. 无关。
