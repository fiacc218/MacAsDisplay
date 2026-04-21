// 接收管线:UdpReceiver + FrameAssembler 粘一起,按整帧回调。
//
// 提供两套 API:
//   1) C++ 侧:`vs::ReceivePipeline`
//   2) C 侧(extern "C"):给 Swift 用 —— 和 SendPipeline 一样的理由,
//      Swift-C++ Interop 对含 std::string/vector 的 non-copyable 类支持不稳,
//      走 C opaque 指针 + 函数指针回调最干净。
#pragma once

#include <cstddef>
#include <cstdint>

#ifdef __cplusplus
#include "UdpReceiver.hpp"
#include "FrameAssembler.hpp"
#include <chrono>
#include <memory>
#include <mutex>

namespace vs {

class ReceivePipeline {
public:
    ReceivePipeline();
    ~ReceivePipeline();
    ReceivePipeline(const ReceivePipeline&)            = delete;
    ReceivePipeline& operator=(const ReceivePipeline&) = delete;

    using OnFrame = FrameAssembler::OnFrame;

    /// 启动 UdpReceiver(绑定 0.0.0.0:port)+ 初始化 FrameAssembler。
    /// 完整帧在 worker 线程上回调。
    bool start(std::uint16_t port,
               std::chrono::milliseconds reassemble_timeout,
               OnFrame on_frame);

    void stop();

    std::uint64_t packets_received() const noexcept { return pkt_rx_.load(); }
    std::uint64_t frames_assembled() const noexcept { return frm_ok_.load(); }

private:
    UdpReceiver                   recv_;
    std::unique_ptr<FrameAssembler> assembler_;
    std::mutex                    mtx_;               // 保护 assembler_ 的 ingest/tick
    std::atomic<std::uint64_t>    pkt_rx_{0};
    std::atomic<std::uint64_t>    frm_ok_{0};
};

}  // namespace vs

extern "C" {
#endif  // __cplusplus

typedef struct VSRecvPipeline VSRecvPipeline;

/// 每完整一帧回调一次。frame_data 在回调返回后失效,需要 Swift 侧立刻拷走。
typedef void (*vs_recv_frame_cb)(void*             ctx,
                                 uint32_t          timestamp_ms,
                                 const uint8_t*    frame_data,
                                 size_t            frame_size);

VSRecvPipeline* vs_recv_pipeline_create(void);
void            vs_recv_pipeline_destroy(VSRecvPipeline* p);

/// 成功返回 1。reassemble_timeout_ms 推荐 200。
int vs_recv_pipeline_start(VSRecvPipeline* p,
                           uint16_t        port,
                           uint32_t        reassemble_timeout_ms,
                           vs_recv_frame_cb cb,
                           void*           ctx);

void     vs_recv_pipeline_stop(VSRecvPipeline* p);
uint64_t vs_recv_pipeline_packets(const VSRecvPipeline* p);
uint64_t vs_recv_pipeline_frames(const VSRecvPipeline*  p);

#ifdef __cplusplus
}  // extern "C"
#endif
