#include "FrameAssembler.hpp"

#include <arpa/inet.h>  // ntohl/ntohs
#include <cstring>

namespace vs {

FrameAssembler::FrameAssembler(std::chrono::milliseconds timeout, OnFrame cb)
    : timeout_(timeout), on_frame_(std::move(cb)) {}

void FrameAssembler::ingest(const std::uint8_t* packet, std::size_t size) {
    if (packet == nullptr || size < sizeof(PacketHeader)) return;

    // 逐字段读取 —— 不依赖结构体 padding/ABI。
    std::uint32_t seq_be, ts_be;
    std::uint16_t idx_be, total_be;
    std::memcpy(&seq_be,   packet + 0,  4);
    std::memcpy(&ts_be,    packet + 4,  4);
    std::memcpy(&idx_be,   packet + 8,  2);
    std::memcpy(&total_be, packet + 10, 2);

    const std::uint32_t ts    = ntohl(ts_be);
    const std::uint16_t idx   = ntohs(idx_be);
    const std::uint16_t total = ntohs(total_be);
    (void)seq_be;  // 当前版本不用做丢包统计;后续可加。

    if (total == 0 || idx >= total) return;

    const std::uint8_t* pay  = packet + sizeof(PacketHeader);
    const std::size_t   plen = size - sizeof(PacketHeader);

    auto& a = pending_[ts];
    if (a.total == 0) {
        a.total      = total;
        a.parts.assign(total, {});
        a.first_seen = std::chrono::steady_clock::now();
    } else if (a.total != total) {
        // total 不一致 —— 上游换了 payload_max 或这是哈希碰撞。丢弃重建。
        a = Assembly{};
        a.total      = total;
        a.parts.assign(total, {});
        a.first_seen = std::chrono::steady_clock::now();
    }

    if (!a.parts[idx].empty()) return;  // 重复包
    a.parts[idx].assign(pay, pay + plen);
    a.received++;

    if (a.received == a.total) {
        std::size_t frame_size = 0;
        for (auto& p : a.parts) frame_size += p.size();

        std::vector<std::uint8_t> buf;
        buf.reserve(frame_size);
        for (auto& p : a.parts) buf.insert(buf.end(), p.begin(), p.end());

        if (on_frame_) on_frame_(ts, buf.data(), buf.size());
        pending_.erase(ts);
    }
}

void FrameAssembler::tick() {
    const auto now = std::chrono::steady_clock::now();
    for (auto it = pending_.begin(); it != pending_.end(); ) {
        if (now - it->second.first_seen > timeout_) {
            it = pending_.erase(it);
        } else {
            ++it;
        }
    }
}

}  // namespace vs
