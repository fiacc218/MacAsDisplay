import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// VideoToolbox 解码器(对称 VideoEncoder,默认 ProRes 422 Proxy)。
///
/// 输入:一整帧 ProRes 压缩数据 + 建立 session 所需的 CMVideoFormatDescription。
/// 输出:`CVPixelBuffer`(IOSurface-backed)→ 供 MetalRenderer 零拷贝渲染。
///
/// 和 H.264 解码不同:
///   - 没有 Annex-B / SPS / PPS。
///   - 每帧都是独立完整帧,无需区分 IDR。
///   - formatDesc 由发送端每秒通过侧信道(ts = 0xFFFFFFFF)传一次。
final class VideoDecoder {

    /// 解码成功回调,在 VT 解码线程上触发。
    var onDecoded: ((CVPixelBuffer, CMTime) -> Void)?

    /// 解码失败 / 回调 status != noErr 时触发,参数是 OSStatus。
    /// 通常意味着 HEVC P-frame 参考链断了 —— 上层应当立刻请求 keyframe 恢复。
    var onDecodeError: ((OSStatus) -> Void)?

    private var session:    VTDecompressionSession?
    private var formatDesc: CMFormatDescription?

    /// 收到 formatDesc 侧信道包时调用。幂等:同一个 desc 不会重建 session。
    func configure(formatDescBytes: Data) {
        guard let fd = FormatDescCodec.decode(formatDescBytes) else {
            Log.video.error("FormatDescCodec.decode failed (bytes=\(formatDescBytes.count))")
            return
        }
        if let old = formatDesc, CMFormatDescriptionEqual(old, otherFormatDescription: fd) {
            return
        }
        formatDesc = fd

        let sub = CMFormatDescriptionGetMediaSubType(fd)
        let subStr = String(
            format: "%c%c%c%c",
            (sub >> 24) & 0xff, (sub >> 16) & 0xff,
            (sub >> 8)  & 0xff,  sub        & 0xff
        )
        let dim = CMVideoFormatDescriptionGetDimensions(fd)
        Log.video.info("formatDesc received: \(subStr, privacy: .public) \(dim.width)x\(dim.height)")

        rebuildSession()
    }

    /// 喂一整帧 ProRes 数据。`configure` 还没进就悄悄丢帧。
    func decode(_ frame: Data, pts: CMTime) {
        guard let fd = formatDesc, let session else { return }
        if frame.isEmpty { return }

        let size = frame.count

        // 1) 分配一个装 frame bytes 的 CMBlockBuffer。
        //    CM 自己 malloc,用完 sample 释放时连带释放。
        var bb: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: size,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: size,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &bb
        )
        guard createStatus == noErr, let bb else {
            Log.video.error("CMBlockBufferCreate failed: \(createStatus)")
            return
        }

        let copyStatus: OSStatus = frame.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: bb,
                offsetIntoDestination: 0, dataLength: size
            )
        }
        guard copyStatus == noErr else {
            Log.video.error("CMBlockBufferReplaceDataBytes: \(copyStatus)")
            return
        }

        // 2) 包一个 CMSampleBuffer。
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleSize = size
        var sb: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: fd,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sb
        )
        guard sbStatus == noErr, let sb else {
            Log.video.error("CMSampleBufferCreateReady: \(sbStatus)")
            return
        }

        // 3) 解码。用 outputHandler;异步解码让 VT 自己并行。
        var flagsOut: UInt32 = 0
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sb,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &flagsOut
        ) { [weak self] status, _, imgBuf, outPts, _ in
            guard let self else { return }
            guard status == noErr, let imgBuf else {
                Log.video.error("decode status=\(status)")
                self.onDecodeError?(status)
                return
            }
            self.onDecoded?(imgBuf, outPts)
        }
        if status != noErr {
            Log.video.error("VTDecompressionSessionDecodeFrame: \(status)")
        }
    }

    func stop() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session    = nil
        formatDesc = nil
    }

    deinit { stop() }

    // MARK: - Private

    private func rebuildSession() {
        if let old = session {
            VTDecompressionSessionWaitForAsynchronousFrames(old)
            VTDecompressionSessionInvalidate(old)
            session = nil
        }
        guard let fd = formatDesc else { return }

        // 输出像素格式:32BGRA,IOSurface + Metal 兼容 → 渲染零拷贝。
        let pbAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        var out: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fd,
            decoderSpecification: nil,
            imageBufferAttributes: pbAttrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &out
        )
        guard status == noErr, let out else {
            Log.video.error("VTDecompressionSessionCreate: \(status)")
            return
        }
        session = out
        Log.video.info("VT decompression session ready")
    }
}
