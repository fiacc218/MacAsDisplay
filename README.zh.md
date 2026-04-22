# MacAsDisplay

[English](README.md) | **中文**

把一台旧 Mac 当成新 Mac 的第二显示器,走 Thunderbolt Bridge 或 Wi-Fi。
HEVC 硬编码,30 fps 原生 retina 分辨率,好链路下 ~1 帧延迟。

> 状态:**alpha / 作者自用日常**。用了私有 API(`CGVirtualDisplay`),
> 不能上 App Store,后续 macOS 版本可能变。见[限制](#限制)。

```
┌──────────────┐  HEVC/UDP + HMAC ctrl   ┌──────────────┐
│   主 Mac     │──────────────────────▶  │   副屏 Mac   │
│  (Sender)    │  Thunderbolt / Wi-Fi    │  (Receiver)  │
└──────────────┘                         └──────────────┘
```

一个 `.app` 双角色。两台 Mac 装同一份 DMG,首启选角色。

支持 Wi-Fi(同一网段自动发现)和 Thunderbolt Bridge(更大带宽,亚毫秒 RTT)。

## 为什么不用现成的

| 方案 | 不合适的原因 |
|---|---|
| **Sidecar** | 只支持 iPad。 |
| **随航** / Universal Control | 只共享鼠标键盘,不是副屏。 |
| **AirPlay to Mac** | 1080p 上限,延迟高。 |
| **Luna / Duet** | 商业订阅。 |

## 要求

| | |
|---|---|
| **主 Mac** | macOS 14+,Apple Silicon 或有 HEVC 硬编的 Intel |
| **副屏 Mac** | macOS 14+,任何有 HEVC 硬解的 Mac(Intel 第 7 代+ / Apple Silicon) |
| **链路** | 同一个 Wi-Fi(最方便)或 Thunderbolt Bridge 直连 |

## 安装

1. 下载 **[MacAsDisplay.dmg](https://github.com/fiacc218/MacAsDisplay/releases/latest)**
2. 打开 DMG,把 `MacAsDisplay.app` 拖到**应用程序**文件夹 —— **两台 Mac 都要装**
3. 双击启动。已做 Developer ID 签名 + Apple 公证,**无 Gatekeeper 警告**。

## 首次启动

每台 Mac 首启时选角色:

- **Main Mac** —— 这台 Mac 的屏幕会被采集发送(Sender)
- **Secondary Display** —— 这台 Mac 当副屏(Receiver)

之后想换角色:菜单栏图标 → **Switch Role…**,或副屏 Receiver 全屏时按
**ESC** 调出控制条。

### 主 Mac 额外步骤

- 提示时授予**录屏**权限(或点菜单栏面板里黄色 banner → *Open Screen
  Recording settings*)。
- 菜单栏会出现图标,点开显示状态、目标主机、Start/Stop。
- 同一 LAN / TB Bridge 上的 Receiver 会**自动发现**,点 `Target` 右边下拉
  直接选。

## 网络

两台 Mac 在同一个 Wi-Fi 上就能用 —— 启动副屏,主 Mac 自动发现,IP 出
现在 `Target` 下拉菜单里。HEVC 30fps retina 大概 ~20-50 Mbps,Wi-Fi 5+
在正常网络下都够。

### Thunderbolt Bridge(可选,追求最大带宽时)

点对点,10+ Gbps,亚毫秒 RTT,不跟 Wi-Fi 抢。

1. 两台 Mac 用 TB3/TB4 线连起来。
2. **系统设置 → 网络 → Thunderbolt Bridge → 详细信息 → TCP/IP →
   配置 IPv4:使用 DHCP 并填手动地址** —— 给两台分配
   `169.254.0.1` / `169.254.0.2`(或同一 /16 的任一对)。
3. `sudo ifconfig bridge0 mtu 9000` 两端都跑一下启用 jumbo frames
   (大 I-frame 不会被拆成一堆小包)。

## 使用

1. 先在**副屏 Mac** 启动 —— 会全屏黑并开始广播身份。
2. 再启动**主 Mac**。`Target` 会自动填充;多网卡就从下拉菜单里选。
3. 点 **Start**。主 Mac 出现一个 30 fps 虚拟显示器,把窗口拖过去就显示在
   副屏上。

副屏上任何时候按 **ESC** 退出全屏,露出控制条(**返回全屏** /
**切换角色** / **退出**)。

## 安全模型

- 控制信道用 HMAC-SHA256 + nonce 抗重放认证。
- 内置默认 PSK,首装零配置开箱即用。
- 视频负载**不加密**。**别在不可信网络上用。**TB Bridge 或私有 LAN 才行。
- 想换自己的 PSK:一台机器跑
  `head -c 32 /dev/urandom > ~/.config/macasdisplay/psk`,再 `scp` 到另一台。
  详情见 [SECURITY.md](SECURITY.md)。

## 故障排查

**副屏一直黑屏。** 主 Mac 上点了 **Start** 吗?光启动是不会自动推流的。
两边日志里都看一下 `PSK fp=...`,指纹必须一致。

**授权了录屏仍报 "User denied screen capture"。** 旧版本的签名在 TCC 里
留了条过时条目,清一下:
```sh
tccutil reset ScreenCapture xyz.dashuo.macasdisplay
```
再重新授权。**只有大版本首装时遇到一次**,之后升级都会保留授权。

**副屏屏保跳出来打断画面。**
```sh
caffeinate -d -i -s -w $(pgrep MacAsDisplay)
```

**刘海屏 MBP 看不到菜单栏图标。** 刘海挤掉了右侧图标。用
[Bartender](https://www.macbartender.com/) /
[Hidden Bar](https://github.com/dwarvesf/hidden),或 `VS_AUTOSTART=1`
跑无界面模式。

## 限制

- **`CGVirtualDisplay` 是私有 API**,Apple 可能随时改,不能上 App Store。
- **不转发输入**(设计如此)。用主 Mac 的鼠标键盘,macOS 原生会跨虚拟显
  示器路由鼠标。
- **无音频**。
- **每次主 Mac 会话只能开一个虚拟显示器。**

## 从源码构建

给贡献者看的。一般用户直接下 DMG 就好。

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

Apache License 2.0。见 [LICENSE](LICENSE)。

本项目与 Apple Inc. 无关。
