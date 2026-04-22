import AppKit

/// 全屏无边框黑底窗口。ESC 退出全屏,再按一次退出 app。
///
/// 定位:纯显示端。不转发输入 —— 你的鼠标 / 键盘留在 Sender 机器上,
/// 靠 macOS 原生多屏排列(M2 Max 光标滑过屏幕边界)来用。
final class FullScreenWindow: NSWindow {

    private var trackingArea: NSTrackingArea?
    private let hider = CursorAutoHider()
    private weak var controlBar: ReceiverControlBar?

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

        // fullscreen 状态迁移 → 控制条显隐 + 指针自动隐藏器联动。
        // 用 NotificationCenter(不接 delegate)因为 FullScreenWindow 未承诺
        // 完整 NSWindowDelegate,只监听这两个事件,接口面最小。
        NotificationCenter.default.addObserver(
            self, selector: #selector(didExitFullScreen),
            name: NSWindow.didExitFullScreenNotification, object: self
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(didEnterFullScreen),
            name: NSWindow.didEnterFullScreenNotification, object: self
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func installContentView(_ v: NSView) {
        v.frame = contentView?.bounds ?? frame
        v.autoresizingMask = [.width, .height]
        contentView = v
        installTracking(on: v)
    }

    /// 把 overlay 叠在当前 contentView(通常是 Metal view)之上,全尺寸铺满。
    /// overlay 的 `hitTest` 返回 nil,鼠标事件继续穿透到下层 tracking area。
    func addOverlay(_ overlay: NSView) {
        guard let host = contentView else { return }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: host.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    /// 顶部居中的小徽章 —— 用来挂 SignalLostBadge 一类的状态指示器。
    /// 18pt 顶部间距避开系统菜单栏(非全屏态)和观感边界。
    func addBadge(_ badge: NSView) {
        guard let host = contentView else { return }
        badge.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: host.topAnchor, constant: 18),
            badge.centerXAnchor.constraint(equalTo: host.centerXAnchor),
        ])
    }

    /// 退全屏后才露出来的控制条(Switch Role / Quit / Return to Fullscreen)。
    /// 初始透明,didExit/EnterFullScreenNotification 自动淡入淡出。
    ///
    /// 位置:屏幕竖直中线。放底部会被 Dock 挡(退全屏后窗口 level=.normal,
    /// Dock 浮在上面),放屏幕正中视觉冲击最强,也是"下一步干什么"决策点的
    /// 自然落点。
    func addControlBar(_ bar: ReceiverControlBar) {
        guard let host = contentView else { return }
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.alphaValue = 0
        host.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            bar.centerXAnchor.constraint(equalTo: host.centerXAnchor),
        ])
        controlBar = bar
    }

    @objc private func didExitFullScreen(_ n: Notification) {
        // 鼠标悬停在条上时别被 idle 计时器藏掉 —— 用户还在读按钮。
        hider.setPaused(true)
        controlBar?.setVisible(true)
    }

    @objc private func didEnterFullScreen(_ n: Notification) {
        controlBar?.setVisible(false)
        hider.setPaused(false)
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
        // ESC:第一次退全屏,第二次退 app。
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
        // Cmd+Shift+R:清角色并重启 —— 用户想把这台机器从"副屏"改回"主屏",
        // 或者在另一台上看走眼选错了,都靠这条路。全屏 app 没菜单栏入口,
        // 快捷键是唯一手段,hint 在 InfoOverlayView 里会提示用户记住。
        if event.charactersIgnoringModifiers?.lowercased() == "r"
            && event.modifierFlags.contains(.command)
            && event.modifierFlags.contains(.shift) {
            hider.forceShow()
            AppRole.resetAndRelaunch()
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
    private var paused: Bool = false
    private var idleTimer: Timer?
    private var lastMoveAt: Date = .distantPast
    private var burstAccum: CGFloat = 0

    /// 鼠标进窗口(或用户刚唤醒光标后)→ 启动 idle 倒计时。
    func armIdle() {
        if paused { return }
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleSeconds, repeats: false) {
            [weak self] _ in
            self?.hide()
        }
    }

    func onMove(dx: CGFloat, dy: CGFloat) {
        if paused { return }
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

    /// 退全屏 → 控制条显示期间暂停自动隐藏。true 时强制露出指针且不再进新 idle。
    func setPaused(_ p: Bool) {
        paused = p
        if p {
            idleTimer?.invalidate()
            idleTimer = nil
            show()
            burstAccum = 0
        }
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

/// ESC 退全屏后露出的浮动控制条。三枚按钮:Return to Fullscreen / Switch Role / Quit。
/// 回调由 FullScreenWindow / ReceiverAppDelegate 注入 —— 视图不直接碰 AppRole / NSApp,
/// 方便未来 Sender 复用或改接其它 action。
final class ReceiverControlBar: NSVisualEffectView {

    var onReturnFullscreen: (() -> Void)?
    var onSwitchRole:       (() -> Void)?
    var onQuit:             (() -> Void)?

    init() {
        super.init(frame: .zero)
        material     = .hudWindow
        blendingMode = .withinWindow
        state        = .active
        wantsLayer   = true
        layer?.cornerRadius = 14

        let ret  = Self.makeButton(title: String(localized: "Return to Fullscreen"),
                                   target: self, action: #selector(handleReturn))
        let role = Self.makeButton(title: String(localized: "Switch Role…"),
                                   target: self, action: #selector(handleSwitch))
        let quit = Self.makeButton(title: String(localized: "Quit"),
                                   target: self, action: #selector(handleQuit))
        // 默认按钮 = Return,空格键就能回去继续看。
        ret.keyEquivalent = "\r"

        let stack = NSStackView(views: [ret, role, quit])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func makeButton(title: String, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .regular
        return b
    }

    @objc private func handleReturn() { onReturnFullscreen?() }
    @objc private func handleSwitch() { onSwitchRole?() }
    @objc private func handleQuit()   { onQuit?() }

    /// 幂等淡入 / 淡出。0.25s 和 SignalLostBadge 对齐,视觉节奏一致。
    func setVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.allowsImplicitAnimation = true
            self.animator().alphaValue = visible ? 1 : 0
        }
    }
}
