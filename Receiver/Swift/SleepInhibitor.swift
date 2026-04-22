import Foundation
import IOKit.pwr_mgt

/// 阻止系统在 Receiver 活着时触发屏保 / 关显示器。
///
/// 等同 `caffeinate -d`,只是由 app 进程自己持有 —— 不需要用户在终端跑命令,
/// app 退出 / 切角色的时候也会自动释放(进程死,内核自动清 assertion)。
///
/// 为什么只挡显示器睡眠,不挡系统睡眠:
///   - 用户合上盖子 / 主动睡眠应该照常生效,别赖皮
///   - 屏保触发的根因是 "display idle",挡这一条就解决绝大多数打断画面的问题
///   - 关显示器 == 屏保开始,两者在 IOKit 层是同一个时钟
///
/// 为什么不挡输入 idle(`PreventUserIdleSystemSleep`):
///   - 那个是"进入系统睡眠",比屏保粗一层
///   - 一起挡会导致笔记本长时间没动作时也不睡,副屏 Mac 常年挂着浪费电
final class SleepInhibitor {

    private var assertionID: IOPMAssertionID = 0
    private var held = false

    /// 幂等。重复调用不会多拿 assertion。
    func acquire(reason: String) {
        guard !held else { return }
        let rc = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        if rc == kIOReturnSuccess {
            held = true
            Log.app.info("sleep inhibitor acquired (display-idle), reason=\(reason, privacy: .public)")
        } else {
            Log.app.error("IOPMAssertionCreateWithName failed: \(rc)")
        }
    }

    func release() {
        guard held else { return }
        IOPMAssertionRelease(assertionID)
        held = false
        Log.app.info("sleep inhibitor released")
    }

    deinit { release() }
}
