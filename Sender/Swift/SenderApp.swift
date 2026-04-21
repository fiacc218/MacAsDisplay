import SwiftUI
import AppKit
import CoreMedia

/// 纯 AppKit 入口 —— 放弃 SwiftUI App lifecycle。
///
/// 为什么:菜单栏 app(LSUIElement=YES)下 @main struct App + MenuBarExtra 的
/// AppDelegate / StateObject 都是**懒加载**的,用户点开面板前 ControlChannel
/// 根本没起来 —— 对我们这套"Receiver 启动就要先收到 Capability"的流程是灾难。
///
/// 用 NSApplicationMain 走经典 AppDelegate 路径,生命周期回调保证进来。
/// UI 用 NSStatusItem + NSHostingView(SwiftUI ContentView) 承载。
@main
enum SenderMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = SenderAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // 无 Dock icon
        app.run()
    }
}

/// 应用生命周期 + 状态栏图标。
@MainActor
final class SenderAppDelegate: NSObject, NSApplicationDelegate {

    private(set) var controller: SenderController!
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var statusObserver: Any?

    override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 先构造 controller(会启动 ControlChannel / 打日志)。
        controller = SenderController()

        // 状态栏图标 + 点击弹出 ContentView。
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(toggleMenu)
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 440, height: 320)
        popover.contentViewController = NSHostingController(
            rootView: ContentView().environmentObject(controller)
        )

        // controller 状态变 → 更新图标(用 KVO 式 Combine 订阅 ObservableObject)。
        statusObserver = controller.objectWillChange.sink { [weak self] in
            // objectWillChange 在改前触发,下一 tick 再读最新状态。
            DispatchQueue.main.async { self?.updateIcon() }
        }
    }

    @objc private func toggleMenu() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateIcon() {
        guard let b = statusItem?.button else { return }
        b.image = NSImage(systemSymbolName: controller?.menuBarIcon ?? "display",
                          accessibilityDescription: "MacAsDisplay")
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}

// Combine.Cancellable 需要 import Combine。ObservableObject.objectWillChange 是
// Publisher,.sink 得到 AnyCancellable。
import Combine

/// 应用级控制器 —— 串起虚拟屏、捕获、编码、UDP 发送、ControlChannel。
@MainActor
final class SenderController: ObservableObject {

    @Published var status: String       = "Idle"
    @Published var targetHost: String   = SenderController.loadTargetHost()
    @Published var isStreaming: Bool    = false
    @Published var receiverConnected: Bool = false
    @Published var receiverCaps: ControlChannel.Capability? = nil

    private static let targetHostKey = "VS.targetHost"
    private static func loadTargetHost() -> String {
        UserDefaults.standard.string(forKey: targetHostKey) ?? AppConfig.targetHost
    }
    private func persistTargetHost() {
        UserDefaults.standard.set(targetHost, forKey: Self.targetHostKey)
    }

    /// 用户在 UI 里按回车提交 Target 时调。立刻持久化 + 把控制信道对端切过去。
    func saveTargetHostEdit() {
        persistTargetHost()
        control.setPeer(host: targetHost, port: AppConfig.controlPort)
        Log.net.info("target host manually set to \(self.targetHost, privacy: .public)")
    }

    private var virtualDisplay = VirtualDisplay()
    private let capture        = ScreenCapture()
    private var encoder: VideoEncoder?

    // 运行期实际用的分辨率 —— 优先取 Capability,未知则回退 AppConfig。
    private var currentWidth:  Int = AppConfig.virtualWidth
    private var currentHeight: Int = AppConfig.virtualHeight

    private var pipelinePtr: OpaquePointer? = nil

    private let control = ControlChannel()
    private var lastReceiverHello: Date = .distantPast
    private var helloTimer: Timer?

    private var encStatBytes: Int     = 0
    private var encStatFrames: Int    = 0
    private var encStatLastLog: Date  = .distantPast

    private var formatDescData: Data?
    private var formatDescTimer: Timer?

    var menuBarIcon: String {
        // 注意:SF Symbol 名字要选当前 macOS 真的有的,不然 NSImage 返回 nil,
        // NSStatusItem button 没 image = 透明按钮,肉眼等于图标消失。
        // `display.slash` 在 macOS 14 上没有 —— 踩过。
        if status.contains("FAILED") { return "display.trianglebadge.exclamationmark" }
        if isStreaming                { return "display.and.arrow.down" }
        if receiverConnected          { return "display" }
        return "rectangle.on.rectangle.slash"
    }

    init() {
        NSLog("[VS] SenderController.init")
        wireControlChannel()
        bootstrap()
    }

    private func bootstrap() {
        if let raw = vs.cpp_hello() {
            let msg = String(cString: raw)
            Log.app.info("[C++ Interop] \(msg, privacy: .public)")
        }

        if !VirtualDisplay.isAvailable() {
            Log.display.warning("CGVirtualDisplay private API not available on this system")
            status = "CGVirtualDisplay API missing"
        } else {
            VirtualDisplay.dumpPrivateAPI()
        }

        let (key, src) = ControlAuth.loadOrCreate()
        control.setKey(key)
        Log.net.info("PSK fp=\(ControlAuth.fingerprint(key), privacy: .public) source=\(src.description, privacy: .public)")

        if !control.start(listenPort: AppConfig.controlPort) {
            Log.net.error("control channel bind failed")
        }
        // 没手工指定目标时,等 Receiver 广播 Capability 过来,learnTarget 会自动填。
        if !targetHost.isEmpty {
            control.setPeer(host: targetHost, port: AppConfig.controlPort)
        } else {
            Log.net.info("no target host configured; waiting for receiver discovery broadcast")
        }

        helloTimer?.invalidate()
        helloTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.control.send(.hello) }
        }

        if ProcessInfo.processInfo.environment["VS_AUTOSTART"] == "1" {
            Log.app.info("VS_AUTOSTART=1 → will start() after caps window")
            Task { @MainActor [weak self] in
                // 给 Receiver 的 Capability 一个机会(它启动就立刻发一次)。
                for _ in 0..<15 {
                    if self?.receiverCaps != nil { break }
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }
                // 拿到第一包后再多等 500ms:Receiver 广播在每条接口上依次发送
                // (LAN + TB 在几 ms 内串行),网络栈顺序不可控。短等能让
                // learnTarget 有机会把 LAN 升级到 TB,避免 autostart 把视频
                // 永久锁在带宽低的 LAN 上。
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.start()
            }
        }
    }

    func start() {
        isStreaming = true
        status = "Starting..."

        if let caps = receiverCaps {
            currentWidth  = Int(caps.widthPx)
            currentHeight = Int(caps.heightPx)
            Log.app.info("using receiver-reported dims \(caps.widthPx)x\(caps.heightPx) @ \(caps.fps)fps")
        } else {
            currentWidth  = AppConfig.virtualWidth
            currentHeight = AppConfig.virtualHeight
            Log.app.info("no capability from receiver — using defaults \(self.currentWidth)x\(self.currentHeight)")
        }

        Task { @MainActor in
            do {
                var desc = VirtualDisplay.Descriptor()
                desc.width  = currentWidth
                desc.height = currentHeight
                desc.hz     = AppConfig.frameRate
                try virtualDisplay.create(desc)
                status = "VD id=\(virtualDisplay.displayID); requesting TCC..."

                guard await ScreenCapture.ensurePermission() else {
                    status = "Screen recording permission denied"
                    virtualDisplay.destroy()
                    isStreaming = false
                    return
                }

                // 路径 MTU 自适应:TB Bridge 下实测 9000,Wi-Fi/普通以太网 1500。
                // 把包尽量撑到接口 MTU,伺候大 I-frame —— 同样 2MB 的帧,8000 MTU
                // 下只需 ~260 次 sendto() 而不是 1500 次,burst 压力 -5×,这才是
                // 之前手工设 30 Mbps 就会卡的真原因(syscall 爆棚,不是 bitrate 本身)。
                let ifMtu = NetworkDiscovery.interfaceMTU(toward: targetHost)
                    ?? AppConfig.interfaceMTUFallback          // 探测失败 → 退回保守 1500
                // IP(20) + UDP(8) = 28 字节包头。另留 4 字节安全边界避免极端场景分片。
                let udpWireMax = max(1400, min(ifMtu - 28 - 4, 9000))
                let payloadMax = udpWireMax - 12               // 减 VS 分片头
                if pipelinePtr == nil {
                    pipelinePtr = vs_pipeline_create()
                }
                let ok = targetHost.withCString { cstr in
                    vs_pipeline_configure(pipelinePtr, cstr,
                                          AppConfig.videoPort, payloadMax) == 1
                }
                guard ok else {
                    status = "UDP configure failed"
                    virtualDisplay.destroy()
                    isStreaming = false
                    return
                }
                Log.net.info("UDP pipeline → \(self.targetHost, privacy: .public):\(AppConfig.videoPort) ifMTU=\(ifMtu) payload=\(payloadMax)")

                let enc = VideoEncoder(width: currentWidth, height: currentHeight)
                self.encoder = enc
                try enc.start()
                encStatBytes = 0; encStatFrames = 0; encStatLastLog = Date()

                enc.onFormatDescription = { [weak self] fdesc in
                    guard let self else { return }
                    let sub = CMFormatDescriptionGetMediaSubType(fdesc)
                    let subStr = String(
                        format: "%c%c%c%c",
                        (sub >> 24) & 0xff, (sub >> 16) & 0xff,
                        (sub >> 8)  & 0xff,  sub        & 0xff
                    )
                    Log.video.info("formatDescription ready, subtype=\(subStr, privacy: .public)")

                    guard let bytes = FormatDescCodec.encode(fdesc) else {
                        Log.video.error("FormatDescCodec.encode failed")
                        return
                    }
                    Task { @MainActor [weak self] in
                        self?.formatDescData = bytes
                        self?.sendFormatDescOnce()
                        self?.startFormatDescTimer()
                    }
                }
                enc.onEncoded = { [weak self] data, pts in
                    guard let self, let ptr = self.pipelinePtr else { return }
                    let tsMs = UInt32(truncatingIfNeeded:
                        Int64(pts.seconds * 1000.0))
                    let bytes = data.count
                    data.withUnsafeBytes { raw in
                        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                        _ = vs_pipeline_submit(ptr, tsMs, base, bytes)
                    }
                    Task { @MainActor [weak self] in
                        self?.noteEncoded(bytes: bytes)
                    }
                }

                capture.onFrame = { [weak self] sample in
                    self?.encoder?.encode(sample)
                }
                capture.onError = { [weak self] err in
                    Task { @MainActor [weak self] in
                        self?.status = "Capture error: \(err)"
                        self?.isStreaming = false
                    }
                }

                try await capture.start(
                    displayID: virtualDisplay.displayID,
                    width: currentWidth,
                    height: currentHeight,
                    fps: AppConfig.frameRate
                )
                status = "Capturing+Encoding id=\(virtualDisplay.displayID) @ \(AppConfig.frameRate)fps"
            } catch {
                Log.app.error("start failed: \(String(describing: error), privacy: .public)")
                status = "FAILED: \(error)"
                await capture.stop()
                encoder?.stop(); encoder = nil
                virtualDisplay.destroy()
                isStreaming = false
            }
        }
    }

    func stop() {
        status = "Stopping..."
        formatDescTimer?.invalidate(); formatDescTimer = nil
        formatDescData = nil
        Task { @MainActor in
            await capture.stop()
            encoder?.stop(); encoder = nil
            virtualDisplay.destroy()
            if let p = pipelinePtr {
                vs_pipeline_destroy(p)
                pipelinePtr = nil
            }
            status = "Stopped"
            isStreaming = false
        }
    }

    // MARK: - Control channel wiring

    private func wireControlChannel() {
        control.onHello = { [weak self] src in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastReceiverHello = Date()
                self.learnTarget(from: src)
                if !self.receiverConnected {
                    self.receiverConnected = true
                    Log.net.info("receiver online (hello) from \(self.targetHost, privacy: .public)")
                }
            }
        }
        control.onCapability = { [weak self] caps, src in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receiverCaps = caps
                self.receiverConnected = true
                self.lastReceiverHello = Date()
                self.learnTarget(from: src)
                Log.net.info("receiver caps \(caps.widthPx)x\(caps.heightPx) scaleX1000=\(caps.scaleX1000) fps=\(caps.fps)")
            }
        }
        control.onKeyframeRequest = { [weak self] in
            Task { @MainActor [weak self] in
                Log.video.info("← keyframe request from receiver; forcing I-frame")
                self?.encoder?.requestKeyframe()
            }
        }
    }

    /// 从 Receiver 包的源地址学习 targetHost,并持久化。
    ///
    /// 两端同时连着 TB Bridge **和** 普通 LAN 时,Receiver 会在两条链路都广播
    /// Capability。规则(按优先级):
    ///   1. 已 streaming → 永远不切,避免运行中链路突变
    ///   2. 当前是 link-local (169.254.x.x) → 不降级到 LAN
    ///   3. 新来的是 link-local,而当前是 LAN → **升级**到 TB(关键:冷启动时
    ///      LAN 广播可能先到,必须能在随后的 TB 广播进来时切过去)
    ///   4. 同类(LAN→LAN / TB→TB)变化:更新,尊重最新
    private func learnTarget(from src: sockaddr_in) {
        guard let ip = ControlChannel.ipString(from: src), !ip.isEmpty else { return }
        if ip == targetHost { return }
        if isStreaming {
            Log.net.info("discovered receiver IP \(ip, privacy: .public) but streaming → keeping \(self.targetHost, privacy: .public)")
            return
        }
        let curIsLinkLocal = targetHost.hasPrefix("169.254.")
        let newIsLinkLocal = ip.hasPrefix("169.254.")
        if !targetHost.isEmpty && curIsLinkLocal && !newIsLinkLocal {
            // 规则 2:已在 TB 不降级到 LAN
            Log.net.info("prefer TB \(self.targetHost, privacy: .public) over LAN \(ip, privacy: .public)")
            return
        }
        let from = targetHost.isEmpty ? "<none>" : targetHost
        let reason = (!targetHost.isEmpty && !curIsLinkLocal && newIsLinkLocal)
            ? " (upgrade LAN→TB)" : ""
        Log.net.info("auto-target: \(from, privacy: .public) → \(ip, privacy: .public)\(reason, privacy: .public)")
        targetHost = ip
        persistTargetHost()
        control.setPeer(host: ip, port: AppConfig.controlPort)
    }

    // MARK: - FormatDesc sidechannel

    private func startFormatDescTimer() {
        formatDescTimer?.invalidate()
        formatDescTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sendFormatDescOnce() }
        }
    }

    private func sendFormatDescOnce() {
        guard let data = formatDescData, let ptr = pipelinePtr else { return }
        let ts = NetProtocol.formatDescTimestamp
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = vs_pipeline_submit(ptr, ts, base, data.count)
        }
    }

    fileprivate func noteEncoded(bytes: Int) {
        encStatBytes  += bytes
        encStatFrames += 1
        let now = Date()
        let dt = now.timeIntervalSince(encStatLastLog)
        if dt >= 1.0 {
            let mbps = Double(encStatBytes) * 8.0 / dt / 1_000_000.0
            let fps  = Double(encStatFrames) / dt
            let line = String(format: "enc: %.1ffps %.1fMb/s", fps, mbps)
            Log.video.info("\(line, privacy: .public)")
            status = String(format: "enc %.1ffps %.1fMb/s", fps, mbps)
            encStatBytes = 0
            encStatFrames = 0
            encStatLastLog = now
        }
    }
}
