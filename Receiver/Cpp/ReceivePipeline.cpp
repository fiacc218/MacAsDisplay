#include "ReceivePipeline.hpp"

#include <memory>

namespace vs {

ReceivePipeline::ReceivePipeline()  = default;
ReceivePipeline::~ReceivePipeline() { stop(); }

bool ReceivePipeline::start(std::uint16_t port,
                            std::chrono::milliseconds reassemble_timeout,
                            OnFrame on_frame) {
    auto user_cb = std::move(on_frame);
    assembler_ = std::make_unique<FrameAssembler>(
        reassemble_timeout,
        [this, user_cb](std::uint32_t ts,
                        const std::uint8_t* data,
                        std::size_t size) {
            frm_ok_.fetch_add(1, std::memory_order_relaxed);
            if (user_cb) user_cb(ts, data, size);
        });

    return recv_.start(port, [this](const std::uint8_t* data, std::size_t size) {
        pkt_rx_.fetch_add(1, std::memory_order_relaxed);
        std::lock_guard<std::mutex> lk(mtx_);
        if (assembler_) assembler_->ingest(data, size);
    });
}

void ReceivePipeline::stop() {
    recv_.stop();  // 先停 worker,保证回调不再进来
    std::lock_guard<std::mutex> lk(mtx_);
    assembler_.reset();
}

}  // namespace vs

// ============================================================
// C shim
// ============================================================

struct VSRecvPipeline {
    vs::ReceivePipeline impl;
};

extern "C" {

VSRecvPipeline* vs_recv_pipeline_create(void) { return new VSRecvPipeline(); }

void vs_recv_pipeline_destroy(VSRecvPipeline* p) { delete p; }

int vs_recv_pipeline_start(VSRecvPipeline* p,
                           uint16_t        port,
                           uint32_t        reassemble_timeout_ms,
                           vs_recv_frame_cb cb,
                           void*           ctx) {
    if (!p) return 0;
    auto cpp_cb = [cb, ctx](std::uint32_t ts,
                            const std::uint8_t* data,
                            std::size_t size) {
        if (cb) cb(ctx, ts, data, size);
    };
    return p->impl.start(port,
                         std::chrono::milliseconds(reassemble_timeout_ms),
                         std::move(cpp_cb)) ? 1 : 0;
}

void vs_recv_pipeline_stop(VSRecvPipeline* p) {
    if (p) p->impl.stop();
}

uint64_t vs_recv_pipeline_packets(const VSRecvPipeline* p) {
    return p ? p->impl.packets_received() : 0;
}

uint64_t vs_recv_pipeline_frames(const VSRecvPipeline* p) {
    return p ? p->impl.frames_assembled() : 0;
}

}  // extern "C"
