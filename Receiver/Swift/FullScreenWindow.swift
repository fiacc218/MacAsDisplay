import AppKit

/// 全屏无边框黑底窗口。ESC 退出全屏,再按一次退出 app。
///
/// 定位:纯显示端。不转发输入 —— 你的鼠标 / 键盘留在 Sender 机器上,
/// 靠 macOS 原生多屏排列(M2 Max 光标滑过屏幕边界)来用。
final class FullScreenWindow: NSWindow {

    private var trackingArea: NSTrackingArea?
    private let hider = CursorAutoHider()

    init() {
        let screenRect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        super.init(
            contentRect: screenRect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed  = false
        backgroundColor       = .black
        level                 = .normal
        collectionBehavior    = [.fullScreenPrimary, .managed]
        isMovableByWindowBackground = false
        // NSWindow 默认不分发 mouseMoved,必须显式打开,后面的 tracking 才能工作。
        acceptsMouseMovedEvents = true

        let v = NSView(frame: screenRect)
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        contentView = v
        installTracking(on: v)
    }

    func installContentView(_ v: NSView) {
        v.frame = contentView?.bounds ?? frame
        v.autoresizingMask = [.width, .height]
        contentView = v
        installTracking(on: v)
    }

    /// Tracking area 装在 contentView 上,owner=self → mouseMoved/entered/exited
    /// 回到 NSWindow 的方法。`inVisibleRect` 让它跟着 view resize 自适应,不用手动重装。
    private func installTracking(on view: NSView) {
        // 老 contentView 被新 view 顶掉时会整体从视图树解引用,tracking area
        // 跟着一起回收 —— 这里只管给新 view 装新的就行。
        let ta = NSTrackingArea(
            rect: view.bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        view.addTrackingArea(ta)
        trackingArea = ta
    }

    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { true }

    override func mouseMoved(with event: NSEvent) {
        hider.onMove(dx: event.deltaX, dy: event.deltaY)
    }

    override func mouseEntered(with event: NSEvent) {
        hider.armIdle()
    }

    override func mouseExited(with event: NSEvent) {
        // 光标离开本窗口(切到 Sender 屏)—— 强制恢复,避免系统全局指针一直隐着。
        hider.forceShow()
    }

    override func resignKey() {
        super.resignKey()
        hider.forceShow()
    }

    override func keyDown(with event: NSEvent) {
        // ESC:第一次退全屏,第二次退 app。只有这一个按键本地拦截。
        if event.keyCode == 53 {
            hider.forceShow()
            if styleMask.contains(.fullScreen) {
                toggleFullScreen(nil)
            } else {
                close()
                NSApp.terminate(nil)
            }
            return
        }
        super.keyDown(with: event)
    }
}

/// 空闲 N 秒 → 藏光标;短时内累计位移超阈值(= "摇一下")→ 露出来。
///
/// 为什么不用 "任意移动就露":macOS 系统级微抖动 / trackpad 无意触碰会不断触发
/// mouseMoved,低阈值等于永远不藏。攒位移 + 时间窗能滤掉这种噪声。
private final class CursorAutoHider {

    /// 鼠标不动多久后隐藏(秒)。
    private let idleSeconds: TimeInterval = 3.0
    /// 摇动检测窗口内(deltaX+deltaY 的绝对值之和)达到这个阈值就认为是"摇"。
    /// 80 ≈ 快速拖约 2cm,正常阅读鼠标抖动远低于此。
    private let shakeThreshold: CGFloat = 80
    /// 摇动位移累计窗口(秒)。超过这个间隔没动,累计清零。
    private let shakeWindow: TimeInterval = 0.3

    private var hidden: Bool = false
    private var idleTimer: Timer?
    private var lastMoveAt: Date = .distantPast
    private var burstAccum: CGFloat = 0

    /// 鼠标进窗口(或用户刚唤醒光标后)→ 启动 idle 倒计时。
    func armIdle() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleSeconds, repeats: false) {
            [weak self] _ in
            self?.hide()
        }
    }

    func onMove(dx: CGFloat, dy: CGFloat) {
        let now = Date()
        if now.timeIntervalSince(lastMoveAt) > shakeWindow {
            burstAccum = 0    // 停顿超过窗口 → 重新开始计数
        }
        lastMoveAt = now
        burstAccum += abs(dx) + abs(dy)

        if burstAccum >= shakeThreshold {
            show()
            burstAccum = 0
            armIdle()
        }
    }

    func forceShow() {
        idleTimer?.invalidate()
        idleTimer = nil
        show()
        burstAccum = 0
    }

    // NSCursor.hide / unhide 是平衡的(多次 hide 要多次 unhide),自己记状态避免失衡。
    private func show() {
        guard hidden else { return }
        NSCursor.unhide()
        hidden = false
    }

    private func hide() {
        guard !hidden else { return }
        NSCursor.hide()
        hidden = true
    }
}
