#include "FrameFragmenter.hpp"

#include <arpa/inet.h>  // htonl/htons
#include <algorithm>
#include <cstring>

namespace vs {

FrameFragmenter::FrameFragmenter(std::size_t payload_max_size, Emitter emit)
    : payload_max_(payload_max_size), emit_(std::move(emit)) {
    scratch_.resize(sizeof(PacketHeader) + payload_max_);
}

void FrameFragmenter::submit(std::uint32_t timestamp_ms,
                              const std::uint8_t* frame_data,
                              std::size_t frame_size) {
    if (frame_size == 0 || frame_data == nullptr || payload_max_ == 0) return;

    // total = ceil(frame_size / payload_max_)。限制在 uint16_t。
    const std::size_t total =
        (frame_size + payload_max_ - 1) / payload_max_;
    if (total > 0xFFFFu) return;  // 一帧切出来超过 65535 片,直接丢(不会发生,除非配置出错)

    const std::uint16_t frag_total = static_cast<std::uint16_t>(total);
    const std::uint32_t ts_be      = htonl(timestamp_ms);
    const std::uint16_t total_be   = htons(frag_total);

    std::uint8_t* const hdr = scratch_.data();
    std::uint8_t* const pay = hdr + sizeof(PacketHeader);

    for (std::uint16_t idx = 0; idx < frag_total; ++idx) {
        const std::size_t off   = static_cast<std::size_t>(idx) * payload_max_;
        const std::size_t chunk = std::min(payload_max_, frame_size - off);

        // 逐字段写入 network byte order —— 不依赖结构体 padding/ABI。
        const std::uint32_t seq_be      = htonl(next_seq_++);
        const std::uint16_t idx_be      = htons(idx);
        std::memcpy(hdr + 0,  &seq_be,   4);
        std::memcpy(hdr + 4,  &ts_be,    4);
        std::memcpy(hdr + 8,  &idx_be,   2);
        std::memcpy(hdr + 10, &total_be, 2);
        std::memcpy(pay, frame_data + off, chunk);

        emit_(hdr, sizeof(PacketHeader) + chunk);
    }
}

}  // namespace vs
