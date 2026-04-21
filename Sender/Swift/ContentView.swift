import SwiftUI
import AppKit
import CoreMedia

/// 菜单栏弹出面板。
///
/// 布局优先考虑"一眼看状态":
///   - 顶部:连接状态 + 编解码配置
///   - 中间:目标主机 / 端口
///   - 底部:Start/Stop / Quit
struct ContentView: View {
    @EnvironmentObject var controller: SenderController

    private var codecName: String {
        switch AppConfig.videoCodec {
        case kCMVideoCodecType_HEVC:                  return "HEVC"
        case kCMVideoCodecType_H264:                  return "H.264"
        case kCMVideoCodecType_AppleProRes422Proxy:   return "ProRes 422 Proxy"
        case kCMVideoCodecType_AppleProRes422LT:      return "ProRes 422 LT"
        case kCMVideoCodecType_AppleProRes422:        return "ProRes 422"
        case kCMVideoCodecType_AppleProRes422HQ:      return "ProRes 422 HQ"
        case kCMVideoCodecType_AppleProRes4444:       return "ProRes 4444"
        default:
            let c = AppConfig.videoCodec
            return String(format: "%c%c%c%c",
                          (c >> 24) & 0xff, (c >> 16) & 0xff,
                          (c >> 8)  & 0xff,  c        & 0xff)
        }
    }

    private var dimsSummary: String {
        if let c = controller.receiverCaps {
            let scale = Double(c.scaleX1000) / 1000.0
            return String(format: "%d × %d @%.2gx", c.widthPx, c.heightPx, scale)
        } else {
            return "\(AppConfig.virtualWidth) × \(AppConfig.virtualHeight) (default)"
        }
    }

    /// 用 controller 实时轮询的授权状态。不再依赖 status 字符串,
    /// 这样即便用户**没点过 Start**(status 还是 "Idle")也能提前警告;
    /// 用户授权后状态自动翻转、banner 自动消失;用户后悔回系统设置关掉
    /// 授权也能在 2s 内被检测到重新弹 banner。
    private var isScreenRecordingDenied: Bool {
        !controller.hasScreenRecordingPermission
    }

    private func openScreenRecordingSettings() {
        // 这个 URL 直达"隐私与安全 → 屏幕录制"面板,所有 macOS 13+ 都认。
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // ── Receiver 状态 ────────────────────────────
            HStack(spacing: 8) {
                Circle()
                    .fill(controller.receiverConnected ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(controller.receiverConnected ? "Receiver online" : "Receiver offline")
                    .font(.callout)
                Spacer()
                Text(codecName).font(.caption).monospaced().foregroundStyle(.secondary)
            }

            // ── Stream 状态 / 权限警告 ───────────────────
            if isScreenRecordingDenied {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("Screen Recording permission required")
                            .font(.callout).bold()
                    }
                    Text("Enable MacAsDisplay under System Settings → Privacy & Security → Screen Recording, then click Start again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        openScreenRecordingSettings()
                    } label: {
                        Label("Open Screen Recording settings", systemImage: "arrow.up.forward.app")
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.yellow.opacity(0.15))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.yellow.opacity(0.5), lineWidth: 1)
                )
            } else {
                GroupBox {
                    Text(controller.status)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Status").font(.caption2).foregroundStyle(.secondary)
                }
            }

            // ── Display dims (capability-aware) ─────────
            HStack {
                Text("Display").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(dimsSummary).font(.caption).monospaced()
            }

            // ── Target host ─────────────────────────────
            HStack {
                Text("Target").font(.caption2).foregroundStyle(.secondary)
                TextField("host", text: $controller.targetHost)
                    .textFieldStyle(.roundedBorder)
                    .disabled(controller.isStreaming)
                    .monospaced()
                    .onSubmit { controller.saveTargetHostEdit() }
                // 广播发现到的候选。只要列表非空就常驻显示,0/1 条也给同样
                // 的图标入口 —— 保持 UI 位置稳定,用户不用猜"今天怎么没按钮"。
                if !controller.discoveredPeers.isEmpty {
                    Menu {
                        ForEach(controller.discoveredPeers, id: \.self) { ip in
                            Button(ip) {
                                controller.targetHost = ip
                                controller.saveTargetHostEdit()
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(controller.isStreaming)
                    .help("Pick from receivers discovered via broadcast")
                }
                Text(":\(AppConfig.videoPort)")
                    .foregroundStyle(.secondary)
                    .monospaced()
                    .font(.caption)
            }

            Divider()

            // ── Actions ────────────────────────────────
            HStack {
                Button(controller.isStreaming ? "Stop" : "Start") {
                    if controller.isStreaming { controller.stop() }
                    else                       { controller.start() }
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(controller.status.contains("FAILED"))
                .controlSize(.regular)

                Spacer()

                // Switch Role 放按钮形式而非菜单项 —— menubar popover 没挂 NSMenu,
                // 多加菜单要搞 NSEvent monitor 复杂,按钮直观。
                // .bordered + .secondary 让它视觉上退居其后,不抢 Start / Quit。
                Button("Switch Role…") { AppRole.resetAndRelaunch() }
                    .controlSize(.small)
                    .help("Re-choose whether this Mac is the Main or Secondary display")

                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: [.command])
                    .controlSize(.regular)
            }
        }
        .padding(12)
        // 锁死宽度。不加会被内部 `.frame(maxWidth: .infinity)` 连带 TextField
        // 撑到 NSHostingController 给出的 ideal size 上限,popover 弹成半个屏幕宽、
        // 离 menubar 视觉距离巨大。440 是 NSPopover contentSize 的初始值,对齐。
        .frame(width: 420)
    }
}

#Preview {
    ContentView().environmentObject(SenderController())
}
