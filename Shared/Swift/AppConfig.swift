import Foundation
import CoreMedia

/// 两端共享的运行时配置。
///
/// 现阶段用字面量;后续可以切到 UserDefaults / JSON 热加载,
/// 接口保持 `static` 属性不变,改实现即可。
enum AppConfig {

    // MARK: - Network
    //
    // 推荐 Thunderbolt Bridge 直连:在两台 Mac 都插上 TB 线后,系统偏好里
    // Thunderbolt Bridge 会自动协商 169.254.x 地址,链路延迟 <1ms,基本零丢包。
    // 普通 Wi-Fi / 交换机局域网也能用,但画质和码率需要自己调。
    //
    // 零配置发现:Receiver 启动就 2s/次 把 Capability 往本机所有活动接口的广播
    // 地址打一份。Sender 收到首包立刻从源地址学到对端 IP,后续 unicast。
    // 用户通常不需要动 targetHost,Sender 菜单栏面板里填 IP 只是手工覆盖入口
    // (比如跨路由、过 NAT 的场景)。

    /// Sender UI 里 Target 输入框首次冷启动的占位默认。留空 → 走自动发现。
    static let targetHost: String = ""

    /// 视频 UDP 端口(Sender → Receiver,单向)。
    static let videoPort: UInt16 = 5001

    /// 控制信道 UDP 端口(双向,TLV 小包)。
    /// —— Hello / Capability / KeyframeRequest 全走这里。
    static let controlPort: UInt16 = 5002

    /// 路径 MTU 探测失败时的兜底值(单位字节,整个 IP 包含头)。
    /// Sender 正常跑起来会调 `NetworkDiscovery.interfaceMTU(toward:)`:
    ///   - TB Bridge(MTU=9000)→ payload ~8960,I-frame sendto() 次数 -5×
    ///   - Wi-Fi / 交换机(MTU=1500)→ payload 1456
    /// 这里的 1500 只是在 getifaddrs / getsockname 都拿不到时的保守回退。
    static let interfaceMTUFallback: Int = 1500

    // MARK: - Video
    //
    // 选型:**HEVC**(从 ProRes 422 Proxy 换过来)。
    //   - ProRes 在 3360x2100@30 纯软解把 Intel 10 代 VTDecoderXPCService 干到 150%
    //   - Intel QuickSync 有硬件 HEVC 解码,M2 Max 也有硬件 HEVC 编码,两端免费
    //   - 帧间编码,比 ProRes 多 ~33ms 延迟(P-frame 串行),副屏场景无感
    //   - I-frame 每秒一次,保证晚加入 Receiver / 丢帧后 ≤1s 能追上

    // Intel 16" MBP Retina 原生 3360x2100(1680x1050 @2x)。
    // 匹配原生像素,免去 Metal 端 1.75x 双线性插值,文字/UI 不糊。
    static let virtualWidth: Int = 3360
    static let virtualHeight: Int = 2100

    /// 副屏够用,省 CPU。
    static let frameRate: Int = 30

    /// VideoToolbox codec。
    static let videoCodec: CMVideoCodecType = kCMVideoCodecType_HEVC

    /// HEVC **峰值**码率上限(bps)。VideoEncoder 跑 Quality-VBR 模式:
    /// VT 按内容动态分配 —— 桌面静止 ~5 Mbps,大片刷新 / 拖窗时才吃到这个上限。
    /// 通过 `kVTCompressionPropertyKey_DataRateLimits` 传给 VT(1s 窗口)。
    ///
    /// 历史:之前硬设 AverageBitRate 30/60 Mbps 会卡,**根因不是 bitrate** 而是
    /// I-frame 在 1400-byte MTU 下拆成 ~1500 次 sendto(),syscall 队列爆。
    /// 改成按接口 MTU 动态算 payload(见 `interfaceMTUFallback` 注释)后,
    /// sendto 次数 -5×,80 Mbps 的峰值上限在 TB Bridge 下是安全的。
    static let videoBitratePeakBps: Int = 80_000_000

    // MARK: - Buffers
    //
    // 零丢包链路上不做 FEC / 重传:
    //   - 完整帧直接渲染
    //   - 未完成帧超时即丢,等下一帧(ProRes 每帧都是"关键帧")
    //   - 需要 FEC 时再加,架构上预留

    /// JitterBuffer 深度(帧)。TB Bridge 几乎无抖动,1 帧足矣。
    static let jitterDepth: Int = 1

    /// 帧重组超时(毫秒)。超过即丢整帧。
    /// ProRes 单帧 ~1.5MB → ~1100 个 1400-byte UDP 包,20ms 够了。
    static let frameReassembleTimeoutMs: Int = 20
}
