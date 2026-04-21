// 发送端:把一个 H.264 帧切成多个 UDP 包。
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <vector>

namespace vs {

/// 网络包头,12 字节,所有多字节字段以大端序(网络序)存放。
/// 与 Shared/Swift/Protocol.swift 的 NetProtocol 保持一致。
struct PacketHeader {
    std::uint32_t seq;         // 包序号(单调递增)
    std::uint32_t timestamp;   // 帧时间戳(ms,相对 session 起点)
    std::uint16_t frag_idx;    // 本包在该帧内的分片下标,从 0 开始
    std::uint16_t frag_total;  // 该帧被切成的总分片数
};
static_assert(sizeof(PacketHeader) == 12, "PacketHeader layout");

/// 切片器。线程模型:由编码线程单线程使用。
class FrameFragmenter {
public:
    /// 每切出一个包就会以 (header-prepended buffer, size) 调用。
    /// 实现侧无需关心 socket,直接把 bytes 转交给 UdpSender。
    using Emitter = std::function<void(const std::uint8_t* packet,
                                       std::size_t size)>;

    /// `payload_max_size` 是去掉包头后的 payload 上限。
    /// 典型值:`AppConfig.udpPayloadSize - sizeof(PacketHeader)`。
    FrameFragmenter(std::size_t payload_max_size, Emitter emit);

    /// 提交整帧。函数返回时所有分片都已通过 emit_ 发出。
    void submit(std::uint32_t timestamp_ms,
                const std::uint8_t* frame_data,
                std::size_t frame_size);

private:
    std::size_t       payload_max_;
    Emitter           emit_;
    std::uint32_t     next_seq_ = 0;
    std::vector<std::uint8_t> scratch_;  // 复用的包 buffer
};

}  // namespace vs
