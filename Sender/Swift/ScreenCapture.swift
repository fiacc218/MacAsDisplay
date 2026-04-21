import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics
import CoreImage
import AppKit

/// 基于 ScreenCaptureKit 的屏幕捕获。
///
/// 必须**精确**捕获指定 `CGDirectDisplayID`(由 VirtualDisplay 造出来的那块),
/// 不然主屏内容会被串流过去。
///
/// 输出的 `CMSampleBuffer` 里的 `CVPixelBuffer` 由 IOSurface 承载,
/// 直接交给 VideoToolbox 编码即可零拷贝。
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {

    /// 每帧回调(在 `queue` 上)。已经过滤掉无图像内容的"idle"帧。
    var onFrame: ((CMSampleBuffer) -> Void)?
    /// stream 自己停了(比如系统级错误)。
    var onError: ((Error) -> Void)?

    /// 累计捕到的有效帧数。
    private(set) var frameCount: Int = 0

    private var stream: SCStream?
    private let queue = DispatchQueue(
        label: "xyz.dashuo.macasdisplay.capture",
        qos: .userInteractive
    )

    /// 每满一秒打一行日志(约等于 fps 帧)。
    private var logCountdown: Int = 0
    private var logInterval: Int  = 30
    private var loggedFirstSize: Bool = false

    /// 询问 / 触发"屏幕录制"权限。
    /// 第一次调用会触发系统弹窗;用户同意后**需要重启 app** 才生效(macOS TCC 的脾气)。
    static func ensurePermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            return true
        } catch {
            Log.display.error(
                "screen recording permission denied: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    /// 启动捕获。
    ///
    /// 注意:VirtualDisplay 刚 `create` 完,SCShareableContent 未必立刻感知,
    /// 所以用一个小的 100ms × 20 次的重试循环。TB Bridge 场景下通常 1~2 次就命中。
    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        var foundDisplay: SCDisplay?
        for attempt in 0..<20 {
            let content = try await SCShareableContent.current
            if let d = content.displays.first(where: { $0.displayID == displayID }) {
                foundDisplay = d
                break
            }
            Log.display.info("waiting for SC to see display \(displayID) (attempt \(attempt + 1))")
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        guard let display = foundDisplay else {
            throw NSError(
                domain: "ScreenCapture", code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                            "display \(displayID) not enumerated by SCShareableContent"]
            )
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // 虚拟屏像素尺寸我们自己定的,不用再猜 scale。
        config.width       = width
        config.height      = height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth  = 5
        config.showsCursor = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()

        self.stream        = stream
        self.frameCount    = 0
        self.logInterval   = max(1, fps)
        self.logCountdown  = self.logInterval

        Log.display.info(
            "capture started: display=\(displayID, privacy: .public) \(width)x\(height)@\(fps)"
        )
    }

    func stop() async {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            Log.display.error("stopCapture error: \(String(describing: error), privacy: .public)")
        }
        self.stream = nil
        Log.display.info("capture stopped (total frames=\(self.frameCount))")
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // idle / blank / suspended 等都没有 imageBuffer,跳过
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if !loggedFirstSize {
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            Log.display.info("first captured pb: \(w)x\(h)")
            loggedFirstSize = true

            // 顺便把第一帧 dump 成 PNG,直接看 SCK 送过来的原始像素锐利度。
            if ProcessInfo.processInfo.environment["VS_DUMP_FRAMES"] == "1" {
                let ci = CIImage(cvPixelBuffer: pb)
                let ctx = CIContext()
                if let cg = ctx.createCGImage(ci, from: ci.extent) {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    if let d = rep.representation(using: .png, properties: [:]) {
                        try? d.write(to: URL(fileURLWithPath: "/tmp/tx_capture.png"))
                    }
                }
            }
        }

        frameCount &+= 1
        logCountdown -= 1
        if logCountdown <= 0 {
            Log.display.info("captured \(self.frameCount) frames so far")
            logCountdown = logInterval
        }

        onFrame?(sampleBuffer)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.display.error("stream stopped: \(String(describing: error), privacy: .public)")
        self.stream = nil
        onError?(error)
    }
}
