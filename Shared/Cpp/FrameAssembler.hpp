// 接收端:按 timestamp + frag_idx 把 UDP 包重组成完整帧。
#pragma once

#include "FrameFragmenter.hpp"  // 复用 PacketHeader

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <unordered_map>
#include <vector>

namespace vs {

/// 帧重组器。线程模型:由接收线程单线程使用。
class FrameAssembler {
public:
    /// 完整帧就绪回调。
    using OnFrame = std::function<void(std::uint32_t timestamp_ms,
                                        const std::uint8_t* frame_data,
                                        std::size_t frame_size)>;

    FrameAssembler(std::chrono::milliseconds timeout, OnFrame on_frame);

    /// 输入一个完整 UDP 包(包头 + payload)。
    void ingest(const std::uint8_t* packet, std::size_t size);

    /// 由外部循环周期性调用(~每 10ms),淘汰超时的未完成帧。
    void tick();

    /// 诊断。
    std::size_t pending_count() const noexcept { return pending_.size(); }

private:
    struct Assembly {
        std::uint16_t total    = 0;
        std::uint16_t received = 0;
        std::vector<std::vector<std::uint8_t>> parts;  // 按 frag_idx 索引
        std::chrono::steady_clock::time_point first_seen;
    };

    std::unordered_map<std::uint32_t /*timestamp*/, Assembly> pending_;
    std::chrono::milliseconds timeout_;
    OnFrame on_frame_;
};

}  // namespace vs
