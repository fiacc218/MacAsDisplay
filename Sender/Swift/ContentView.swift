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

            // ── Stream 状态 ─────────────────────────────
            GroupBox {
                Text(controller.status)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Status").font(.caption2).foregroundStyle(.secondary)
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

                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: [.command])
                    .controlSize(.regular)
            }
        }
        .padding(12)
    }
}

#Preview {
    ContentView().environmentObject(SenderController())
}
