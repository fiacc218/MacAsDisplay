import AppKit

/// Receiver 首屏提示层 —— 没有视频帧到达之前,展示"等待连接 + 本机 IP 列表
/// + PSK 指纹"。第一帧解出来后淡出。目的是让用户不再需要 `ipconfig` 查
/// Receiver 的 IP,抬眼就能看到。
final class InfoOverlayView: NSVisualEffectView {

    private let titleLabel   = NSTextField(labelWithString: "MacAsDisplay Receiver")
    private let statusLabel  = NSTextField(labelWithString: "Waiting for Sender…")
    private let ipStack      = NSStackView()
    private let pskLabel     = NSTextField(labelWithString: "")
    private let hintLabel    = NSTextField(labelWithString: "Enter any IP address above into the Sender to connect · Press ESC for options (switch role / quit)")
    private let portLabel    = NSTextField(labelWithString: "")

    private var refreshTimer: Timer?
    private var dismissed = false

    init() {
        super.init(frame: .zero)
        material     = .hudWindow     // 暗色磨砂,不影响视觉主题
        blendingMode = .withinWindow
        state        = .active
        wantsLayer   = true
        buildUI()
        refreshIPs()
        // 3s 轮询 —— IP 能变(DHCP 换租约、拔 TB 线),让首屏实时准
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshIPs()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { refreshTimer?.invalidate() }

    // 让点击 / 鼠标事件穿透到 MetalView(tracking area 在它上面)。否则
    // overlay 一挡,全屏光标自动隐藏/唤醒逻辑全失效。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Public

    func setPSKFingerprint(_ fp: String) {
        pskLabel.stringValue = "PSK fp:  \(fp)"
    }

    func setPorts(video: UInt16, control: UInt16) {
        portLabel.stringValue = "UDP ports:  \(video) · \(control)"
    }

    /// 淡出 0.4s 后从视图树摘掉。idempotent。
    func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        refreshTimer?.invalidate(); refreshTimer = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            ctx.allowsImplicitAnimation = true
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.removeFromSuperview()
        })
    }

    // MARK: - Build

    private func buildUI() {
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 42, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center

        statusLabel.font = .systemFont(ofSize: 18, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center

        ipStack.orientation = .vertical
        ipStack.alignment = .centerX
        ipStack.spacing = 10

        portLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        portLabel.textColor = .tertiaryLabelColor
        portLabel.alignment = .center

        pskLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pskLabel.textColor = .tertiaryLabelColor
        pskLabel.alignment = .center

        hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .center

        // 给 IP 列表一个 "标题"
        let ipHeader = NSTextField(labelWithString: "Enter one of these addresses into the Sender:")
        ipHeader.font = .systemFont(ofSize: 14, weight: .medium)
        ipHeader.textColor = .secondaryLabelColor
        ipHeader.alignment = .center

        let container = NSStackView(views: [
            titleLabel,
            statusLabel,
            spacer(24),
            ipHeader,
            ipStack,
            spacer(20),
            portLabel,
            pskLabel,
            spacer(8),
            hintLabel,
        ])
        container.orientation = .vertical
        container.alignment = .centerX
        container.spacing = 8
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: centerXAnchor),
            container.centerYAnchor.constraint(equalTo: centerYAnchor),
            container.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -120),
        ])
    }

    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    // MARK: - IP rendering

    private func refreshIPs() {
        for v in ipStack.arrangedSubviews {
            ipStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        let entries = InterfaceIPs.active()
        if entries.isEmpty {
            let l = NSTextField(labelWithString: "No active network interfaces — check Wi-Fi / Thunderbolt")
            l.textColor = .systemRed
            l.font = .systemFont(ofSize: 16)
            l.alignment = .center
            ipStack.addArrangedSubview(l)
            return
        }

        for e in entries {
            ipStack.addArrangedSubview(makeIPRow(displayName: e.displayName, ipv4: e.ipv4))
        }
    }

    /// 一行 "Wi-Fi · 192.168.1.42" —— 接口名灰色 + IP 大号等宽白色。
    private func makeIPRow(displayName: String, ipv4: String) -> NSView {
        let nameLabel = NSTextField(labelWithString: displayName)
        nameLabel.font = .systemFont(ofSize: 14, weight: .medium)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.alignment = .right
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let ipLabel = NSTextField(labelWithString: ipv4)
        ipLabel.font = .monospacedSystemFont(ofSize: 28, weight: .semibold)
        ipLabel.textColor = .labelColor
        ipLabel.alignment = .left
        ipLabel.isSelectable = true    // 允许用户鼠标选中 —— 远程桌面场景下能复制

        let row = NSStackView(views: [nameLabel, ipLabel])
        row.orientation = .horizontal
        row.spacing = 16
        row.alignment = .firstBaseline
        // 让接口名列宽度统一,IP 对齐
        nameLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        return row
    }
}

/// "信号丢失" 徽章 —— 顶部居中小药丸,红点闪烁 + "No signal"。
/// Sender 心跳断 >N 秒时显示,心跳恢复就隐藏。判定依据是控制信道 Hello,
/// 不是视频帧 —— 静止桌面 ScreenCaptureKit 本来就不吐帧,按帧数判会误报。
final class SignalLostBadge: NSVisualEffectView {

    private let dot = NSView()
    private let label = NSTextField(labelWithString: "No signal")
    private var blinkTimer: Timer?

    init() {
        super.init(frame: .zero)
        material     = .hudWindow
        blendingMode = .withinWindow
        state        = .active
        wantsLayer   = true
        layer?.cornerRadius = 14
        translatesAutoresizingMaskIntoConstraints = false
        alphaValue = 0   // 默认隐藏

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor

        let stack = NSStackView(views: [dot, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { blinkTimer?.invalidate() }

    // 徽章本身不拦截鼠标 —— 和 InfoOverlayView 一样,让事件透过去给 tracking area。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 幂等。true 淡入并开始闪烁;false 停止闪烁并淡出。
    func setVisible(_ visible: Bool) {
        if visible {
            guard blinkTimer == nil else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.allowsImplicitAnimation = true
                self.animator().alphaValue = 1
            }
            startBlink()
        } else {
            guard blinkTimer != nil || alphaValue > 0 else { return }
            stopBlink()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.allowsImplicitAnimation = true
                self.animator().alphaValue = 0
            }
        }
    }

    private func startBlink() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self else { return }
            let target: CGFloat = self.dot.alphaValue > 0.5 ? 0.2 : 1.0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.allowsImplicitAnimation = true
                self.dot.animator().alphaValue = target
            }
        }
    }

    private func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        dot.alphaValue = 1.0
    }
}
