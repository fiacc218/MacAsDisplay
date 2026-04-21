import Metal
import MetalKit
import QuartzCore
import CoreVideo
import AppKit

/// Metal 渲染器。挂在 FullScreenWindow.contentView 上。
///
/// 关键:
///   - `displaySyncEnabled = false`  不等 VSync,最小延迟
///   - `framebufferOnly     = false`  允许把 texture 当 blit 源
///   - `CVMetalTextureCache` 从 IOSurface-backed CVPixelBuffer 直接拿 MTLTexture,零拷贝
///   - aspect-fit:源 / 目标不同比例时上下或左右留黑
final class MetalRenderer: NSObject, MTKViewDelegate {

    /// 把这个 view 作为 window.contentView。用 MTKView —— AppKit 官方路径,
    /// 我们之前手工搭 NSView + CAMetalLayer 在全屏/borderless 组合下屏幕全黑,
    /// 疑似 layer 没进合成树。MTKView 内部把这些坑都处理好了。
    let view: NSView  // 实际是 MTKView,外面只看 NSView 接口。

    private let mtkView: MTKView
    private let device: MTLDevice
    private let queue:  MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?

    // 待渲染的帧 —— render() 写入,MTKView delegate 的 draw(in:) 读出并画。
    private var pendingPixelBuffer: CVPixelBuffer?
    private var pendingIsNew = false
    private let pendingLock = NSLock()

    // GPU 背压:最多 2 帧在飞,超了就 drop 当前帧 —— 绝不阻塞主线程等 GPU,
    // 否则主线程一堵,WindowServer compose 等不到 present,就 watchdog 崩。
    private let inFlight = DispatchSemaphore(value: 2)

    // CVMetalTextureCache 内部持 IOSurface ref。长时间运行要定期 flush,
    // 否则 cache 会持续积压,Intel iGPU 共享 VRAM 会被吃满。
    private var lastFlush = CACurrentMediaTime()

    override init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue  = device.makeCommandQueue() else {
            Log.render.error("Metal device / queue unavailable")
            fatalError("Metal unavailable")
        }
        self.device = device
        self.queue  = queue

        // 编译 shader —— 源码字符串,避免新增 .metal 文件和构建步骤。
        guard let lib = try? device.makeLibrary(source: Self.shaderSrc, options: nil),
              let vsf = lib.makeFunction(name: "fsq_vs"),
              let fsf = lib.makeFunction(name: "fsq_fs") else {
            Log.render.error("shader compile/lookup failed")
            fatalError("shader compile failed")
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction   = vsf
        desc.fragmentFunction = fsf
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipe = try? device.makeRenderPipelineState(descriptor: desc) else {
            Log.render.error("render pipeline create failed")
            fatalError("pipeline create failed")
        }
        self.pipeline = pipe

        // MTKView:官方 CAMetalLayer 封装。走 displayLink 自己按 VSync 拉帧 ——
        // 解码再快都不直接 push draw,避免主线程被背压堵死。
        let mv = MTKView(frame: .zero, device: device)
        mv.colorPixelFormat         = .bgra8Unorm
        mv.framebufferOnly          = false
        mv.isPaused                 = false
        mv.enableSetNeedsDisplay    = false
        mv.preferredFramesPerSecond = AppConfig.frameRate
        mv.presentsWithTransaction  = false
        mv.autoResizeDrawable       = true     // 让 MTKView 自动按 view scale 调 drawableSize
        mv.clearColor               = MTLClearColorMake(0, 0, 0, 1)
        mv.layer?.isOpaque          = true
        self.mtkView = mv
        self.view    = mv

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

        super.init()
        mv.delegate = self
    }

    private var didLogFirst = false

    /// 接 VideoDecoder 的输出。可在任意线程调用。
    /// 只更新 pending buffer,实际渲染由 MTKView 的 displayLink 在 draw(in:) 里拉。
    func render(_ pixelBuffer: CVPixelBuffer) {
        pendingLock.lock()
        pendingPixelBuffer = pixelBuffer
        pendingIsNew = true
        pendingLock.unlock()
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // 背压:GPU 没消化完 2 帧就 drop 当前 tick —— timeout=.now() 立即返回,不阻塞主线程。
        guard inFlight.wait(timeout: .now()) == .success else { return }
        var didCommit = false
        defer { if !didCommit { inFlight.signal() } }

        pendingLock.lock()
        let pb = pendingPixelBuffer
        let isNew = pendingIsNew
        pendingIsNew = false
        pendingLock.unlock()
        // 没有新帧就跳过,避免无谓地耗 currentDrawable + GPU 功耗。
        guard isNew, let pixelBuffer = pb,
              let textureCache,
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }

        // 每秒 flush 一次纹理缓存,释放过期 IOSurface ref。
        let now = CACurrentMediaTime()
        if now - lastFlush > 1.0 {
            CVMetalTextureCacheFlush(textureCache, 0)
            lastFlush = now
        }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let pf = CVPixelBufferGetPixelFormatType(pixelBuffer)

        if !didLogFirst {
            let pfStr = String(
                format: "%c%c%c%c",
                (pf >> 24) & 0xff, (pf >> 16) & 0xff,
                (pf >> 8)  & 0xff,  pf        & 0xff
            )
            let iosurface = CVPixelBufferGetIOSurface(pixelBuffer) != nil
            Log.render.info("first render: pb=\(w)x\(h) pf=\(pfStr, privacy: .public) iosurface=\(iosurface) viewBounds=\(Int(view.bounds.width))x\(Int(view.bounds.height)) drawable=\(Int(view.drawableSize.width))x\(Int(view.drawableSize.height))")
            didLogFirst = true
        }

        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm, w, h, 0, &cvTex
        )
        guard status == kCVReturnSuccess, let cvTex,
              let srcTex = CVMetalTextureGetTexture(cvTex) else {
            Log.render.error("CVMetalTextureCacheCreateTextureFromImage: \(status)")
            return
        }

        // aspect-fit viewport
        let dstTex = drawable.texture
        let srcAspect = Double(srcTex.width)  / Double(srcTex.height)
        let dstW      = Double(dstTex.width)
        let dstH      = Double(dstTex.height)
        let dstAspect = dstW / dstH
        var vpW = dstW, vpH = dstH, vpX = 0.0, vpY = 0.0
        if srcAspect > dstAspect {
            vpH = dstW / srcAspect
            vpY = (dstH - vpH) / 2.0
        } else {
            vpW = dstH * srcAspect
            vpX = (dstW - vpW) / 2.0
        }

        // 用 MTKView 给的 renderPassDescriptor(已配好 clear / store)。
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setViewport(MTLViewport(
            originX: vpX, originY: vpY,
            width: vpW, height: vpH,
            znear: 0, zfar: 1
        ))
        enc.setFragmentTexture(srcTex, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        cmd.addCompletedHandler { [weak self] _ in
            self?.inFlight.signal()
        }
        cmd.present(drawable)
        cmd.commit()
        didCommit = true
    }

    // MARK: - Shader source

    /// 全屏四边形 + 采样 —— 2 个三角形组成 triangleStrip,通过 vertex_id 查表取顶点。
    private static let shaderSrc: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct V2F {
        float4 position [[position]];
        float2 uv;
    };

    vertex V2F fsq_vs(uint vid [[vertex_id]]) {
        const float2 positions[4] = {
            float2(-1.0, -1.0), float2(1.0, -1.0),
            float2(-1.0,  1.0), float2(1.0,  1.0)
        };
        // flip Y:Metal 的 NDC 和纹理 UV 都是 +Y 向上,但 CVPixelBuffer 是 +Y 向下
        const float2 uvs[4] = {
            float2(0.0, 1.0), float2(1.0, 1.0),
            float2(0.0, 0.0), float2(1.0, 0.0)
        };
        V2F o;
        o.position = float4(positions[vid], 0.0, 1.0);
        o.uv       = uvs[vid];
        return o;
    }

    fragment float4 fsq_fs(V2F in [[stage_in]],
                           texture2d<float> tex [[texture(0)]]) {
        // nearest —— drawable 与 pb 都是 3360x2100 时 1:1 采样,无 sub-pixel
        // 误差;bilinear 在 1:1 也会软化文字边缘。
        constexpr sampler s(mag_filter::nearest,
                            min_filter::nearest,
                            address::clamp_to_edge);
        return tex.sample(s, in.uv);
    }
    """
}
