#include "SendPipeline.hpp"

#include <arpa/inet.h>
#include <algorithm>
#include <cstring>

namespace vs {

bool SendPipeline::configure(const std::string& host,
                             std::uint16_t port,
                             std::size_t payload_max_size) {
    if (!sender_.open())                 return false;
    if (!sender_.set_target(host, port)) return false;
    payload_max_ = payload_max_size;
    scratch_.assign(12 + payload_max_, 0);
    return true;
}

long SendPipeline::submit(std::uint32_t timestamp_ms,
                          const std::uint8_t* frame_data,
                          std::size_t frame_size) {
    if (payload_max_ == 0)                        return -1;
    if (frame_size == 0 || frame_data == nullptr) return 0;

    const std::size_t total =
        (frame_size + payload_max_ - 1) / payload_max_;
    if (total > 0xFFFFu) return 0;

    const std::uint16_t frag_total = static_cast<std::uint16_t>(total);
    const std::uint32_t ts_be      = htonl(timestamp_ms);
    const std::uint16_t total_be   = htons(frag_total);

    std::uint8_t* const hdr = scratch_.data();
    std::uint8_t* const pay = hdr + 12;

    long sent = 0;
    for (std::uint16_t idx = 0; idx < frag_total; ++idx) {
        const std::size_t off   = static_cast<std::size_t>(idx) * payload_max_;
        const std::size_t chunk = std::min(payload_max_, frame_size - off);

        const std::uint32_t seq_be = htonl(next_seq_++);
        const std::uint16_t idx_be = htons(idx);
        std::memcpy(hdr + 0,  &seq_be,   4);
        std::memcpy(hdr + 4,  &ts_be,    4);
        std::memcpy(hdr + 8,  &idx_be,   2);
        std::memcpy(hdr + 10, &total_be, 2);
        std::memcpy(pay, frame_data + off, chunk);

        const long r = sender_.send(hdr, 12 + chunk);
        if (r > 0) {
            bytes_sent_ += static_cast<std::uint64_t>(r);
            ++sent;
        }
    }
    return sent;
}

}  // namespace vs

// ============================================================
// C shim —— 供 Swift / 其它非 C++ 调用方。
// ============================================================

struct VSSendPipeline {
    vs::SendPipeline impl;
};

extern "C" {

VSSendPipeline* vs_pipeline_create(void) { return new VSSendPipeline(); }

void vs_pipeline_destroy(VSSendPipeline* p) { delete p; }

int vs_pipeline_configure(VSSendPipeline* p,
                          const char*     host,
                          uint16_t        port,
                          size_t          payload_max_size) {
    if (!p || !host) return 0;
    return p->impl.configure(std::string(host), port, payload_max_size) ? 1 : 0;
}

long vs_pipeline_submit(VSSendPipeline* p,
                        uint32_t        timestamp_ms,
                        const uint8_t*  frame_data,
                        size_t          frame_size) {
    if (!p) return -1;
    return p->impl.submit(timestamp_ms, frame_data, frame_size);
}

uint64_t vs_pipeline_bytes_sent(const VSSendPipeline* p) {
    return p ? p->impl.bytes_sent() : 0;
}

}  // extern "C"
