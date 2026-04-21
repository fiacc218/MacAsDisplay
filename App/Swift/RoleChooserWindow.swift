import AppKit
import SwiftUI

/// 首启角色选择。用户看到两个大卡片,点一个 → 持久化 → relaunch。
///
/// 为什么不用 NSAlert:
///   要展示两个大图标 + 两段说明文字,NSAlert 只能放单行,呈现不够清楚。
///   SwiftUI Window + 大按钮能让用户**一眼**看懂两个角色的差别。
final class RoleChooserAppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = RoleChooserView { role in
            AppRole.persist(role)
            AppRole.relaunchSelf()
        }
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = "MacAsDisplay — Choose role"
        w.styleMask = [.titled, .closable]   // 允许关,关 = 退
        w.setContentSize(NSSize(width: 640, height: 380))
        w.center()
        w.isReleasedWhenClosed = false
        window = w

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true    // 用户关了选择窗口 = 退出
    }
}

/// 选择窗口的 SwiftUI 实现。
private struct RoleChooserView: View {
    let onSelect: (AppRole) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Welcome to MacAsDisplay")
                .font(.system(size: 26, weight: .semibold))
            Text("What is this Mac's role?")
                .font(.title3)
                .foregroundStyle(.secondary)

            HStack(spacing: 20) {
                RoleCard(
                    icon: "display.and.arrow.down",
                    title: "Main Mac",
                    subtitle: "Use another Mac as a second display for this one.",
                    action: { onSelect(.mainMac) }
                )
                RoleCard(
                    icon: "display",
                    title: "Secondary Display",
                    subtitle: "Show another Mac's screen on this one.",
                    action: { onSelect(.secondaryDisplay) }
                )
            }

            Text("You can switch roles later from the app menu.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(minWidth: 600, minHeight: 360)
    }
}

/// 卡片式大按钮。
private struct RoleCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 46, weight: .regular))
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(width: 240, height: 200)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.gray.opacity(hovering ? 0.18 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.gray.opacity(hovering ? 0.5 : 0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
