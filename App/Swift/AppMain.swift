import AppKit

/// 统一入口。按持久化的 AppRole 分发到 SenderAppDelegate 或 ReceiverAppDelegate;
/// 从未选过角色时先跑 RoleChooser,选完存起来并 relaunch 到正确模式。
///
/// 为什么 relaunch 而不是运行时切:
///   两种角色对 `NSApp.setActivationPolicy` 的要求不同(.accessory vs .regular),
///   菜单栏 app 和全屏 app 的窗口/生命周期差异又大 —— 一次进程只承担一种角色
///   最干净,也避免 TCC / Window Server 状态残留。
///
/// Bundle Id 现在是统一的 `xyz.dashuo.macasdisplay`,两台机器(Intel / Apple
/// Silicon)装同一份 .app 就能自动配对,不再分 .sender / .receiver。
@main
enum AppMain {
    static func main() {
        let app = NSApplication.shared

        if let role = AppRole.persisted {
            switch role {
            case .mainMac:
                let d = SenderAppDelegate()
                app.delegate = d
                app.setActivationPolicy(.accessory)   // 菜单栏,无 Dock icon
            case .secondaryDisplay:
                let d = ReceiverAppDelegate()
                app.delegate = d
                app.setActivationPolicy(.regular)     // 常规 app,全屏窗口
            }
        } else {
            // 首启:还没选过角色,跑 RoleChooser。它选完会存进 UserDefaults
            // 然后 relaunch 本进程,下一次启动就走 if 分支。
            let d = RoleChooserAppDelegate()
            app.delegate = d
            app.setActivationPolicy(.regular)         // 选角色窗口要可见
        }

        app.run()
    }
}
