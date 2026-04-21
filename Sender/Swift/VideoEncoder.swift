import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// VideoToolbox 编码器(默认 ProRes 422 Proxy,由 AppConfig.videoCodec 决定)。
///
/// 选 ProRes 的原因:
///   - **帧内编码** —— 每帧独立,解码不等参考帧,延迟最低
///   - 近无损,副屏文字 / UI 不糊
///   - ~45 Mbps @ 1920x1200 30fps,对 13.8 Gbps TB Bridge 毫无压力
///
/// ProRes 的输出不是 Annex-B —— 每帧是独立的压缩数据,直接整块发送即可。
/// 接收端用同样的 CMVideoFormatDescription 还原就能解码。
///
/// 输入 `CMSampleBuffer` 里的 `CVPixelBuffer` 就是 ScreenCaptureKit 吐出来的,
/// IOSurface-backed,整条链路零拷贝(直到这里 CMBlockBuffer→Data 拷一次)。
final class VideoEncoder {

    /// 编码回调:(frame data, pts)
    /// ProRes 不区分关键帧 —— 每帧都是完整独立帧。
    var onEncoded: ((Data, CMTime) -> Void)?

    /// 第一次拿到 CMFormatDescription 时回调(或每次重启编码器)。
    /// 上层拿它做 handshake,把解码参数发给 Receiver。
    var onFormatDescription: ((CMFormatDescription) -> Void)?

    private var session: VTCompressionSession?
    private var formatDescSent: Bool = false
    private let width: Int32
    private let height: Int32

    init(width: Int, height: Int) {
        self.width  = Int32(width)
        self.height = Int32(height)
    }

    deinit { stop() }

    func start() throws {
        // 强制硬件编码器 —— M2 Max Media Engine 有 HEVC 硬编,不走 CPU。
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
        ]

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width, height: height,
            codecType: AppConfig.videoCodec,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,          // 用 EncodeFrameWithOutputHandler,不用 C 回调
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        set(session, kVTCompressionPropertyKey_RealTime,             kCFBooleanTrue)
        set(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(session, kVTCompressionPropertyKey_ExpectedFrameRate,    AppConfig.frameRate as CFNumber)

        // HEVC 专属。ProRes 不需要这些(码率固定、每帧都是 I 帧)。
        if AppConfig.videoCodec == kCMVideoCodecType_HEVC ||
           AppConfig.videoCodec == kCMVideoCodecType_H264 {
            set(session, kVTCompressionPropertyKey_ProfileLevel,
                kVTProfileLevel_HEVC_Main_AutoLevel)

            // Quality-VBR:目标是"每帧画质不低于 0.90",VT 按内容动态分配码率 ——
            // 桌面静止 ~5 Mbps,大片刷新 / 拖窗时才吃到峰值。
            // 0.85→0.90 专门为副屏文字抗锯齿加预算:Quality 越高,chroma 边缘
            // (4:2:0 下彩色文字最明显)保留越多细节。0.95+ 收益递减明显。
            // ProRes 不支持 Quality(码率由 profile 锁死),这里只对 HEVC/H264 设。
            set(session, kVTCompressionPropertyKey_Quality, 0.90 as CFNumber)

            // 峰值钳制:DataRateLimits = [bytes, seconds] 告诉 VT 任一秒窗口
            // 最多吃 bytes 字节。单独的 Quality 模式**没有上限**,I-frame 在复杂
            // 内容下可能炸到 100+ Mbps,瞬时把 UDP sendto 挤爆。
            //
            // 历史教训(AppConfig 老注释里也有):
            //   hard-set AverageBitRate 30 Mbps → 卡顿
            //   这不是 30 Mbps 本身的错 —— 是 I-frame 在 1400-byte MTU 下拆成
            //   ~1500 次 sendto() 打在 ~1ms 里,syscall 队列/网卡队列爆掉。
            //   前端已改成按路径 MTU 动态算 payload,TB Bridge 下 payload≈8960,
            //   sendto 次数 -5×,所以 80 Mbps/s 的硬上限是安全的。
            let peakBytesPerSec = AppConfig.videoBitratePeakBps / 8
            let dataRateLimits: [Any] = [
                NSNumber(value: peakBytesPerSec),
                NSNumber(value: 1.0 as Double)
            ]
            set(session, kVTCompressionPropertyKey_DataRateLimits,
                dataRateLimits as CFArray)

            // I-frame 每秒一次 —— 晚加入的 Receiver 或丢帧恢复点。
            set(session, kVTCompressionPropertyKey_MaxKeyFrameInterval,
                AppConfig.frameRate as CFNumber)
            set(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                1.0 as CFNumber)
        }

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session        = session
        self.formatDescSent = false
        Log.video.info("VT compression session ready (\(self.width)x\(self.height))")
    }

    /// 喂一帧。从 `CMSampleBufferGetImageBuffer` 拿 CVPixelBuffer(零拷贝)。
    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dur = CMSampleBufferGetDuration(sampleBuffer)
        encode(pixelBuffer: imageBuffer, pts: pts, duration: dur)
    }

    /// 请求下一帧强制 I-frame。用于接收端丢包恢复:
    /// ControlChannel 收到 KeyframeRequest → 调这里 → 下一帧打上
    /// kVTEncodeFrameOptionKey_ForceKeyFrame,VT 把它编成独立 I-frame,
    /// 后续 P-frame 依赖链在该帧重建。
    func requestKeyframe() {
        forceKeyframeNext = true
    }

    private var forceKeyframeNext: Bool = false

    /// 直接喂 `CVPixelBuffer` —— 供 CGDisplayStream 路径使用(不经 SCK)。
    func encode(pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime = .invalid) {
        guard let session else { return }

        let props: CFDictionary?
        if forceKeyframeNext {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            forceKeyframeNext = false
        } else {
            props = nil
        }

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: props,
            infoFlagsOut: nil
        ) { [weak self] status, _, outSample in
            guard let self else { return }
            guard status == noErr, let outSample else {
                Log.video.error("encode callback status=\(status)")
                return
            }
            self.handleEncoded(outSample)
        }
        if status != noErr {
            Log.video.error("encode submit failed: \(status)")
        }
    }

    func stop() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        formatDescSent = false
    }

    // MARK: - Private

    private func handleEncoded(_ sample: CMSampleBuffer) {
        // 首帧抛 format description 出去(上层做 handshake)
        if !formatDescSent, let fdesc = CMSampleBufferGetFormatDescription(sample) {
            onFormatDescription?(fdesc)
            formatDescSent = true
        }

        guard let bb = CMSampleBufferGetDataBuffer(sample) else { return }
        let total = CMBlockBufferGetDataLength(bb)
        guard total > 0 else { return }

        var data = Data(count: total)
        let status: OSStatus = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(bb, atOffset: 0,
                                              dataLength: total,
                                              destination: base)
        }
        guard status == noErr else {
            Log.video.error("CMBlockBufferCopyDataBytes failed: \(status)")
            return
        }

        let outPts = CMSampleBufferGetPresentationTimeStamp(sample)
        onEncoded?(data, outPts)
    }

    @inline(__always)
    private func set(_ session: VTCompressionSession,
                     _ key: CFString, _ value: AnyObject) {
        VTSessionSetProperty(session, key: key, value: value)
    }
}
