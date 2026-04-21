import Foundation
import CoreGraphics
import AppKit

/// CGVirtualDisplay 私有 API 封装。
///
/// 运行时通过 `NSClassFromString` 拿类对象,调用路由到
/// `VirtualDisplayRuntime.[hm]`(Obj-C)—— 这样既不给 linker 留私有符号,
/// 又能正确处理 `-initWithWidth:height:refreshRate:` 这类取 C 基本类型的 init。
///
/// 生命周期:
///   - `create` 成功后 `displayID != 0`,虚拟屏在系统里可见。
///   - Swift 对象析构时 `destroy` 会断所有强引用,系统自动回收虚拟屏。
///   - 也可以手动调 `destroy()` 立即释放(比如用户点 Stop)。
final class VirtualDisplay {

    struct Descriptor {
        var width:  Int    = AppConfig.virtualWidth
        var height: Int    = AppConfig.virtualHeight
        var hz:     Int    = AppConfig.frameRate
        var name:   String = "MacAsDisplay"
        // 任意填,自用不需要和真实硬件冲突检测。
        var productID: UInt32 = 0x1234
        var vendorID:  UInt32 = 0x3456
        var serialNum: UInt32 = 0x0001
    }

    enum Failure: Error, CustomStringConvertible {
        case classMissing(String)
        case modeInitFailed
        case displayInitFailed
        case applySettingsFailed
        case noDisplayID

        var description: String {
            switch self {
            case .classMissing(let n):    return "private class \(n) not found in this macOS"
            case .modeInitFailed:          return "CGVirtualDisplayMode init returned nil"
            case .displayInitFailed:       return "CGVirtualDisplay init returned nil"
            case .applySettingsFailed:     return "applySettings: returned NO"
            case .noDisplayID:             return "displayID is 0 after applySettings"
            }
        }
    }

    // Strong refs —— ARC 保住私有 Obj-C 对象,释放时系统自动清理虚拟屏。
    private var display:    NSObject?
    private var descriptor: NSObject?
    private var settings:   NSObject?
    private var modes:      [NSObject] = []

    /// 创建成功后填充;0 = 未创建。
    private(set) var displayID: CGDirectDisplayID = 0

    init() {}
    deinit { destroy() }

    /// 一次性 dump 私有 CGVirtualDisplay 类的 method / property / ivar 列表。
    static func dumpPrivateAPI() { VSDumpVirtualDisplayAPI() }

    /// 当前系统是否还支持 CGVirtualDisplay。
    /// 在 macOS 10.13 — 15 上一直可用,但私有 API 没有公开兼容性保证。
    static func isAvailable() -> Bool {
        return NSClassFromString("CGVirtualDisplay") != nil
            && NSClassFromString("CGVirtualDisplayDescriptor") != nil
            && NSClassFromString("CGVirtualDisplayMode") != nil
            && NSClassFromString("CGVirtualDisplaySettings") != nil
    }

    /// 创建虚拟屏。幂等:若已创建会先 destroy 再重建。
    func create(_ d: Descriptor = Descriptor()) throws {
        destroy()

        guard let DescCls = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type else {
            throw Failure.classMissing("CGVirtualDisplayDescriptor")
        }
        guard let ModeCls = NSClassFromString("CGVirtualDisplayMode") else {
            throw Failure.classMissing("CGVirtualDisplayMode")
        }
        guard let SettCls = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type else {
            throw Failure.classMissing("CGVirtualDisplaySettings")
        }
        guard let DispCls = NSClassFromString("CGVirtualDisplay") else {
            throw Failure.classMissing("CGVirtualDisplay")
        }

        // 1) Descriptor —— 用 KVC 设属性。
        let desc = DescCls.init()
        desc.setValue(d.name,              forKey: "name")
        desc.setValue(UInt32(d.width),     forKey: "maxPixelsWide")
        desc.setValue(UInt32(d.height),    forKey: "maxPixelsHigh")
        // sizeInMillimeters 决定 DPI —— 只有 Retina 级 DPI(≥ ~200)WindowServer 才会
        // 为这块屏自动生成 "pixel = 2× logical" 的 HiDPI 对。
        // 3360 px / 220 DPI ≈ 15.3" ≈ 388 mm —— 正好是 16" MBP 面板尺寸,系统很乐意
        // 把它当 Retina。公式: mm = px × 25.4 / DPI
        let targetDPI = 220.0
        let sizeMM = CGSize(width:  Double(d.width)  * 25.4 / targetDPI,
                            height: Double(d.height) * 25.4 / targetDPI)
        desc.setValue(NSValue(size: sizeMM), forKey: "sizeInMillimeters")
        desc.setValue(d.productID,         forKey: "productID")
        desc.setValue(d.vendorID,          forKey: "vendorID")
        desc.setValue(d.serialNum,         forKey: "serialNum")
        // queue + terminationHandler:CGVirtualDisplay 的两个"回调契约" 字段。
        // 没设,WindowServer 不把它视为完整硬件 —— 于是 Arrangement 不收,桌面 / menubar 不画。
        // 有了这两个,显示链才走完整注册路径。
        desc.setValue(DispatchQueue.main, forKey: "queue")
        let termHandler: @convention(block) (NSObject?) -> Void = { _ in
            Log.display.info("virtual display terminated by system")
        }
        desc.setValue(termHandler as AnyObject, forKey: "terminationHandler")
        self.descriptor = desc

        // 2) Modes —— 走 Obj-C helper(处理 uint32_t/double 参数)。
        //
        // 放**两条**:pixel 3360x2100(目标物理) + pixel 1680x1050(logical base)。
        // 加上 hiDPI=1 和 Retina 级 DPI,WindowServer 会识别出 3360 恰好 = 2× 1680,
        // 合并成 "pixel 3360 / logical 1680" 的 Retina 对 —— 这正是我们要的:
        // 编码链路仍然是全分辨率 3360x2100(sharp),但 UI 按 1680x1050 排布(big)。
        guard let modeFull = VSAllocVirtualDisplayMode(ModeCls,
                                                        UInt32(d.width),
                                                        UInt32(d.height),
                                                        Double(d.hz)) else {
            throw Failure.modeInitFailed
        }
        guard let modeHalf = VSAllocVirtualDisplayMode(ModeCls,
                                                        UInt32(d.width / 2),
                                                        UInt32(d.height / 2),
                                                        Double(d.hz)) else {
            throw Failure.modeInitFailed
        }
        self.modes = [modeFull, modeHalf]

        // 3) Settings
        let settings = SettCls.init()
        settings.setValue([modeFull, modeHalf], forKey: "modes")
        settings.setValue(UInt32(1),  forKey: "hiDPI")
        // refreshDeadline: 没设 → WindowServer 认为这屏"不需要刷新",framebuffer 冻结
        // 在初始帧 —— 即便用户操作屏内容,SCK/CG 的 capture 都读到同一帧。
        // 设一个远未来值,让 WS 持续绘制。
        settings.setValue(Double.greatestFiniteMagnitude, forKey: "refreshDeadline")
        settings.setValue(false,      forKey: "isReference")
        self.settings = settings

        // 4) Display(initWithDescriptor:)
        guard let display = VSAllocVirtualDisplay(DispCls, desc) else {
            throw Failure.displayInitFailed
        }
        self.display = display

        // 5) applySettings: 把 modes 装上,之后 displayID 才有效。
        guard VSVirtualDisplayApplySettings(display, settings) else {
            throw Failure.applySettingsFailed
        }

        let id = VSVirtualDisplayGetID(display)
        guard id != 0 else { throw Failure.noDisplayID }
        self.displayID = id

        Log.display.info(
            "virtual display created: id=\(id, privacy: .public) \(d.width)x\(d.height)@\(d.hz)Hz"
        )

        // 6) 把它真正塞进 Arrangement —— 给一个坐标,WS 就认它是外接屏,
        //    这时候才有壁纸 / menubar / 鼠标能进。坐标选主屏右边,
        //    用户事后在"显示器"偏好里还能拖。
        Self.joinArrangement(displayID: id)

        Self.dumpDisplayLayout()
    }

    /// CGVirtualDisplay + applySettings 只是**启动**系统注册 —— WindowServer/SkyLight
    /// 真正把它当成真屏是随后 async 完成的。所以 `CGConfigure*` 必须轮询重试:
    /// 等 `CGGetActiveDisplayList` 里出现这个 id,再一次性:
    ///   - 关 mirror(让它是独立第二屏,不是主屏的复制)
    ///   - 放到主屏右边(`CGConfigureDisplayOrigin`)
    private static func joinArrangement(displayID: CGDirectDisplayID) {
        DispatchQueue.global(qos: .userInitiated).async {
            // 轮询 2s,每 50ms 一次 —— 实测在 10ms 数量级就 OK。
            let deadline = Date().addingTimeInterval(2.0)
            while Date() < deadline {
                if isRegistered(displayID) { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard isRegistered(displayID) else {
                Log.display.error("arrangement: display \(displayID) never appeared in active list")
                return
            }

            let main = CGMainDisplayID()
            let mainBounds = CGDisplayBounds(main)
            let originX = Int32(mainBounds.origin.x + mainBounds.size.width)
            let originY = Int32(mainBounds.origin.y)

            var cfg: CGDisplayConfigRef?
            let beginErr = CGBeginDisplayConfiguration(&cfg)
            guard beginErr == .success, let cfg else {
                Log.display.error("CGBeginDisplayConfiguration: \(beginErr.rawValue)")
                return
            }

            // 1) 强制关 mirror —— 默认可能和主屏镜像。kCGNullDirectDisplay 表示"不镜像任何人"。
            let mirrorErr = CGConfigureDisplayMirrorOfDisplay(cfg, displayID, kCGNullDirectDisplay)
            if mirrorErr != .success {
                Log.display.error("CGConfigureDisplayMirrorOfDisplay: \(mirrorErr.rawValue)")
            }

            // 2) 放到主屏右边。
            let setErr = CGConfigureDisplayOrigin(cfg, displayID, originX, originY)
            if setErr != .success {
                Log.display.error("CGConfigureDisplayOrigin: \(setErr.rawValue)")
            }

            let completeErr = CGCompleteDisplayConfiguration(cfg, .forSession)
            if completeErr != .success {
                Log.display.error("CGCompleteDisplayConfiguration: \(completeErr.rawValue)")
                return
            }
            Log.display.info(
                "arrangement: id=\(displayID, privacy: .public) unmirrored, placed at (\(originX),\(originY))"
            )
            dumpDisplayLayout()

            // CGVirtualDisplay 创建时塞进去的 3360x2100 mode 并不会被自动选中 ——
            // macOS 有一套内建默认(常 1920x1200),applySettings 后得手动切:
            // 遍历 CGDisplayCopyAllDisplayModes,按 pixelWidth 精确匹配 AppConfig,
            // 然后 CGConfigureDisplayWithDisplayMode 切过去。切之前这块屏其实是
            // 1920x1200 内部 framebuffer 被 SCK 双线性 upscale 到 3360x2100 输出,
            // 1.75x 拉伸 = 文字全糊 —— 这步是本项目清晰度的关键根因。
            selectMode(displayID: displayID,
                       width: AppConfig.virtualWidth,
                       height: AppConfig.virtualHeight)
        }
    }

    /// 列出所有 display mode,找到 pixelWidth == want 的那条切过去。
    /// 没找到就打日志不 crash(next frame 仍会用默认 mode,只是糊)。
    private static func selectMode(displayID: CGDirectDisplayID,
                                   width want: Int,
                                   height wantH: Int) {
        // 默认 CGDisplayCopyAllDisplayModes 会**隐掉**低分辨率变体(同 pixelWidth
        // 但 logical 更小的那条 = Retina HiDPI 模式)。显式传这个 option 才能
        // 看到完整列表,里面才有 logical 1680x1050 / pixel 3360x2100 的 Retina 对。
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let cfarr = CGDisplayCopyAllDisplayModes(displayID, opts) else {
            Log.display.error("CGDisplayCopyAllDisplayModes returned nil")
            return
        }
        let count = CFArrayGetCount(cfarr)
        var target: CGDisplayMode? = nil
        var modesList: [String] = []
        // 优先选 Retina(pixelWidth == want 且 logical < pixel);
        // fallback 选 pixelWidth == want 的任意模式。
        var retinaMatch: CGDisplayMode? = nil
        var nativeMatch: CGDisplayMode? = nil
        for i in 0..<count {
            let raw = CFArrayGetValueAtIndex(cfarr, i)
            let mode = Unmanaged<CGDisplayMode>.fromOpaque(raw!).takeUnretainedValue()
            let pw = mode.pixelWidth, ph = mode.pixelHeight
            let lw = mode.width, lh = mode.height
            modesList.append("\(pw)x\(ph)(logical \(lw)x\(lh))")
            if pw == want && ph == wantH {
                if lw < pw { retinaMatch = mode }   // Retina: pixel > logical
                else        { nativeMatch = mode }
            }
        }
        target = retinaMatch ?? nativeMatch
        Log.display.info("available modes: \(modesList.joined(separator: ", "), privacy: .public)")
        guard let m = target else {
            Log.display.error("no mode matches \(want)x\(wantH); keeping default (blurry)")
            return
        }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return }
        let err = CGConfigureDisplayWithDisplayMode(cfg, displayID, m, nil)
        if err != .success {
            Log.display.error("CGConfigureDisplayWithDisplayMode: \(err.rawValue)")
            CGCancelDisplayConfiguration(cfg)
            return
        }
        let done = CGCompleteDisplayConfiguration(cfg, .forSession)
        if done == .success {
            Log.display.info("mode switched → \(m.pixelWidth)x\(m.pixelHeight)")
            dumpDisplayLayout()
        } else {
            Log.display.error("CGCompleteDisplayConfiguration (mode): \(done.rawValue)")
        }
    }

    /// 虚拟屏是否已在 `CGGetActiveDisplayList` 里。
    private static func isRegistered(_ id: CGDirectDisplayID) -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).contains(id)
    }

    /// 调试用 —— 把所有 active display 的 bounds 打出来,
    /// 方便判断虚拟屏是不是躲在主屏下面导致鼠标进不去。
    private static func dumpDisplayLayout() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        for i in 0..<Int(count) {
            let d = ids[i]
            let b = CGDisplayBounds(d)
            let w = CGDisplayPixelsWide(d)
            let h = CGDisplayPixelsHigh(d)
            Log.display.info("  display id=\(d, privacy: .public) bounds=(\(Int(b.origin.x)),\(Int(b.origin.y)) \(Int(b.size.width))x\(Int(b.size.height))) pixels=\(w)x\(h)")
        }
    }

    /// 幂等销毁。会在 deinit 时被调。
    func destroy() {
        if let display, displayID != 0 {
            Log.display.info("destroying virtual display id=\(self.displayID, privacy: .public)")
            // CGVirtualDisplay 没公开 invalidate —— 释放 strong ref 就会触发 dealloc,
            // 系统侧会拔掉这块虚拟屏。
            _ = display
        }
        display    = nil
        settings   = nil
        descriptor = nil
        modes      = []
        displayID  = 0
    }
}
