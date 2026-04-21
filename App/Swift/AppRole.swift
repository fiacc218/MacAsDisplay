import Foundation
import AppKit

/// 这台电脑在 MacAsDisplay 配对里扮演的角色。
///
/// - mainMac:"我是主力机,要把别的 Mac 当副屏用" → 等同旧 Sender。
///   菜单栏常驻,创建虚拟屏并推流。
/// - secondaryDisplay:"我是副屏,显示别的 Mac 的画面" → 等同旧 Receiver。
///   启动即全屏,接收 UDP 并渲染。
///
/// 用户首启看到 RoleChooser 选一次,之后 UserDefaults 记住;菜单里有
/// "Switch Role…" 可以随时重选(改完会自动 relaunch 到新模式)。
enum AppRole: String {
    case mainMac          = "mainMac"
    case secondaryDisplay = "secondaryDisplay"

    private static let defaultsKey = "VS.appRole"

    /// nil = 从未选过 → 需要弹 RoleChooser。
    static var persisted: AppRole? {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        return AppRole(rawValue: raw)
    }

    static func persist(_ role: AppRole) {
        UserDefaults.standard.set(role.rawValue, forKey: defaultsKey)
    }

    /// 清掉持久化的角色,下次启动重新选。调用后通常要 relaunch。
    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    var displayName: String {
        switch self {
        case .mainMac:          return "Main Mac"
        case .secondaryDisplay: return "Secondary Display"
        }
    }

    /// 原地重启本进程。用 `open -n` 走 Launch Services —— 新进程的 TCC /
    /// activation policy / menubar 图标都从头初始化,和用户双击 app 的状态一致,
    /// 比 Process launch 稳得多。
    static func relaunchSelf() {
        let bundleURL = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundleURL.path]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.terminate(nil)
        }
    }

    /// 清角色 + relaunch —— 重启后 AppMain 看到 persisted == nil 就进 RoleChooser。
    static func resetAndRelaunch() {
        clear()
        relaunchSelf()
    }
}
