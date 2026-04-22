import SwiftUI
import AppKit
import CoreMedia
import CoreImage

/// Receiver 角色(Secondary Display)的 AppDelegate。
///
/// 由统一入口 `AppMain` 在 role=.secondaryDisplay 时 instantiate 并装为 NSApp 的
/// delegate,activation policy 设成 .regular(常规 app,全屏窗口接管屏幕)。
final class ReceiverAppDelegate: NSObject, NSApplicationDelegate {

    private var window:   FullScreenWindow?
    private var renderer: MetalRenderer?
    private var overlay:  InfoOverlayView?
    private var signalBadge: SignalLostBadge?
    private var overlayDismissed = false
    private var signalTimer: Timer?
    /// 心跳静默多久算 "Sender 掉线"。Hello 1Hz 发送,3s = 容忍 2 个丢包。
    private let signalLostThreshold: TimeInterval = 3.0
    private let decoder = VideoDecoder()

    // 阻止系统屏保 / 关显示器打断画面,进程退出自动释放。
    private let sleepInhibitor = SleepInhibitor()

    // C 接收管线,opaque 指针。
    private var recvPtr: OpaquePointer? = nil

    // Control channel(双向 UDP 5002)。从启动就一直跑。
    private let control = ControlChannel()
    private var helloTimer: Timer?
    private var capabilityTimer: Timer?
    private var lastKeyframeRequestAt: Date = .distantPast
    private var peerHelloAt: Date = .distantPast

    // 计数(worker / 解码 / 渲染线程都会碰,走锁)。
    private let stats = Stats()
    private var statTimer: Timer?

    // 调试:设 VS_DUMP_FRAMES=1 环境变量,每 2s 把最近解出帧存 /tmp/rx_dump.png,
    // 用于不打开屏幕就检查传输+压缩后的真实像素(绕开 WindowServer 的物理面板降采样)。
    private let ciContext = CIContext()
    private var lastDumpAt: Date = .distantPast
    private let dumpEnabled: Bool = ProcessInfo.processInfo.environment["VS_DUMP_FRAMES"] == "1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let raw = vs.cpp_hello() {
            Log.app.info("[C++ Interop] \(String(cString: raw), privacy: .public)")
        }

        // Receiver 活着的时候别让屏保 / 关显示器打断画面。
        sleepInhibitor.acquire(reason: "MacAsDisplay Receiver is showing a remote Mac")

        // 窗口 + renderer
        let w = FullScreenWindow()
        let r = MetalRenderer()
        renderer = r
        w.installContentView(r.view)

        // 首屏提示 overlay —— 等第一帧解出来再淡出,让用户开屏就能抄 IP。
        let ov = InfoOverlayView()
        ov.setPorts(video: AppConfig.videoPort, control: AppConfig.controlPort)
        w.addOverlay(ov)
        overlay = ov

        // 顶部 "No signal" 徽章 —— 首帧到达后才开始根据 Hello 心跳判定显隐。
        let badge = SignalLostBadge()
        w.addBadge(badge)
        signalBadge = badge

        // ESC 退全屏后底部浮出的控制条 —— 不再需要用户记 ⇧⌘R。
        let bar = ReceiverControlBar()
        bar.onReturnFullscreen = { [weak w] in w?.toggleFullScreen(nil) }
        bar.onSwitchRole = { AppRole.resetAndRelaunch() }
        bar.onQuit = { NSApp.terminate(nil) }
        w.addControlBar(bar)

        w.makeKeyAndOrderFront(nil)
        window = w

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // 真 fullscreen —— 之前只是 borderless 铺满屏幕大小,菜单栏还在、
        // 别的 app 窗口能浮上来,副屏体验是半成品。下一 runloop 切进系统
        // 全屏,macOS 会给它一个独立 Space,独占整屏,用户 ESC 回桌面。
        DispatchQueue.main.async { w.toggleFullScreen(nil) }

        decoder.onDecoded = { [weak self] pb, _ in
            guard let self else { return }
            self.stats.incRender()
            self.renderer?.render(pb)
            if self.dumpEnabled { self.maybeDumpFrame(pb) }
            if !self.overlayDismissed {
                self.overlayDismissed = true
                Task { @MainActor [weak self] in self?.overlay?.dismiss() }
            }
        }
        // 解码器报错 = P-frame 链真的断了,这是唯一可靠的"丢包"信号。
        //
        // 不用"N ms 没新帧"的 watchdog —— ScreenCaptureKit 只在画面变化时才
        // 吐帧,静止桌面可能 >1s 没新帧,但完全没丢包。100ms 阈值会把这种
        // 正常空窗误判成 loss,每 500ms 打一次 keyframeRequest:
        //   - Quality-VBR 的 1s 码率窗口被 I-frame 吃光,P-frame 没预算渲细节
        //   - 编码器永远在"恢复"状态,文字边缘和 UI 线条持续糊
        decoder.onDecodeError = { [weak self] status in
            Task { @MainActor [weak self] in
                Log.video.info("decode error \(status); requesting keyframe")
                self?.requestKeyframeDebounced()
            }
        }

        startControlChannel()
        startReceive()
    }

    // MARK: - Control channel

    private func startControlChannel() {
        let (key, src) = ControlAuth.loadOrCreate()
        control.setKey(key)
        let fp = ControlAuth.fingerprint(key)
        overlay?.setPSKFingerprint(fp)
        Log.net.info("PSK fp=\(fp, privacy: .public) source=\(src.description, privacy: .public)")

        if !control.start(listenPort: AppConfig.controlPort) {
            Log.net.error("control channel bind failed")
            return
        }
        // Receiver 不主动 setPeer —— 靠 Sender 的 Hello/KeyframeRequest 建立对端地址。
        // 好处:Receiver 不需要知道 Sender IP,装哪台机器哪台机器就能当副屏。

        control.onHello = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.peerHelloAt = Date()
            }
        }

        // 首次 Capability 立刻报一次,然后 2s 一次(Sender 可能晚启动)。
        sendCapability()
        capabilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sendCapability() }
        }

        // 心跳 + 广播发现。
        //   - control.send(.hello): 已有 peer(收过 Sender 包)时发到 peer
        //   - sendToVia(ifIndex, bcast): 每秒对每条网卡定向广播一份 Hello。用
        //     IP_BOUND_IF 逐接口出,不走默认路由 —— 否则 Sender 只会看到
        //     Wi-Fi 那个源 IP,TB Bridge 上的 169.254/16 永远发现不了。
        helloTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.control.send(.hello)
                for t in InterfaceIPs.broadcastAddresses() {
                    self.control.sendToVia(ifIndex: t.ifIndex, .hello,
                                           host: t.address, port: AppConfig.controlPort)
                }
            }
        }

        // Hello 静默监视 —— 仅在首帧过后生效(之前 overlay 自己已经在说 "Waiting")。
        // 0.5s 轮询足够细腻,无感。
        signalTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateSignalBadge() }
        }
    }

    private func updateSignalBadge() {
        guard overlayDismissed, let badge = signalBadge else { return }
        let lost = Date().timeIntervalSince(peerHelloAt) > signalLostThreshold
        badge.setVisible(lost)
    }

    private func sendCapability() {
        // 用窗口所在屏(应该是 Intel 自己的主屏)的 backing 分辨率。
        let screen = window?.screen ?? NSScreen.main
        guard let s = screen else { return }
        let backingScale = s.backingScaleFactor
        let pxWidth  = Int32(s.frame.width  * backingScale)
        let pxHeight = Int32(s.frame.height * backingScale)
        let cap = ControlChannel.Capability(
            widthPx:  pxWidth,
            heightPx: pxHeight,
            scaleX1000: Int32(backingScale * 1000),
            fps: Int32(AppConfig.frameRate)
        )
        let payload = cap.encode()

        // unicast 到已知 peer + 对每条接口定向广播。用 IP_BOUND_IF 保证每张
        // 网卡都真的出一次包,Sender 才能看见所有候选 IP(TB Bridge + Wi-Fi)。
        control.send(.capability, payload: payload)
        for t in InterfaceIPs.broadcastAddresses() {
            control.sendToVia(ifIndex: t.ifIndex, .capability, payload: payload,
                              host: t.address, port: AppConfig.controlPort)
        }
    }

    private func maybeDumpFrame(_ pb: CVPixelBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastDumpAt) > 2.0 else { return }
        lastDumpAt = now
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/rx_dump.png"))
    }

    private func requestKeyframeDebounced() {
        let now = Date()
        guard now.timeIntervalSince(lastKeyframeRequestAt) > 0.5 else { return }
        lastKeyframeRequestAt = now
        control.send(.keyframeRequest)
        Log.net.info("→ keyframeRequest")
    }

    // MARK: - Video receive

    private func startReceive() {
        recvPtr = vs_recv_pipeline_create()

        let cb: vs_recv_frame_cb = { ctx, ts, bytes, size in
            guard let ctx, let bytes else { return }
            let me = Unmanaged<ReceiverAppDelegate>
                .fromOpaque(ctx).takeUnretainedValue()
            me.onFrame(timestamp: ts, bytes: bytes, size: size)
        }
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        let ok = vs_recv_pipeline_start(
            recvPtr,
            AppConfig.videoPort,
            UInt32(AppConfig.frameReassembleTimeoutMs),
            cb, ctx
        ) == 1
        guard ok else {
            Log.net.error("UDP receive start failed (bind?)")
            return
        }
        Log.net.info("UDP receive listening on :\(AppConfig.videoPort)")

        statTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] _ in self?.logStats()
        }
    }

    private func onFrame(timestamp: UInt32,
                          bytes: UnsafePointer<UInt8>,
                          size: Int) {
        stats.addFrame(bytes: size)

        let data = Data(bytes: bytes, count: size)

        if timestamp == NetProtocol.formatDescTimestamp {
            decoder.configure(formatDescBytes: data)
            return
        }

        let pts = CMTime(value: CMTimeValue(timestamp), timescale: 1000)
        decoder.decode(data, pts: pts)
    }

    private func logStats() {
        let s = stats.snapshotAndReset()
        guard s.dt > 0 else { return }
        let pkt  = UInt64(vs_recv_pipeline_packets(recvPtr))
        let frm  = UInt64(vs_recv_pipeline_frames(recvPtr))
        let line = String(
            format: "rx: frames=%.1ffps  %.1fMb/s  render=%.1ffps  (pkt=%llu frm=%llu)",
            Double(s.frames) / s.dt,
            Double(s.bytes) * 8.0 / s.dt / 1_000_000.0,
            Double(s.renders) / s.dt,
            pkt, frm
        )
        Log.net.info("\(line, privacy: .public)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        sleepInhibitor.release()
        statTimer?.invalidate(); statTimer = nil
        helloTimer?.invalidate(); helloTimer = nil
        capabilityTimer?.invalidate(); capabilityTimer = nil
        signalTimer?.invalidate(); signalTimer = nil
        control.stop()
        if let p = recvPtr {
            vs_recv_pipeline_stop(p)
            vs_recv_pipeline_destroy(p)
            recvPtr = nil
        }
        decoder.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private final class Stats {
    struct Snapshot { let frames, bytes, renders: UInt64; let dt: TimeInterval }

    private var frames: UInt64 = 0
    private var bytes:  UInt64 = 0
    private var renders: UInt64 = 0
    private var last: Date = Date()
    private let lock = NSLock()

    func addFrame(bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        frames &+= 1
        self.bytes &+= UInt64(bytes)
    }
    func incRender() {
        lock.lock(); defer { lock.unlock() }
        renders &+= 1
    }
    func snapshotAndReset() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let dt = now.timeIntervalSince(last)
        let snap = Snapshot(frames: frames, bytes: bytes, renders: renders, dt: dt)
        frames = 0; bytes = 0; renders = 0
        last = now
        return snap
    }
}
