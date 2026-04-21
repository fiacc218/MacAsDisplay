// 接收端:平滑抖动的定深 FIFO。
#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
#include <optional>
#include <vector>

namespace vs {

/// 固定深度 JitterBuffer。
/// - push: 按 timestamp_ms 插入保持有序(乱序包在此处被纠正)。
/// - pop:  只有当 size() >= depth 时才出队最早的一帧。
class JitterBuffer {
public:
    struct Frame {
        std::uint32_t             timestamp_ms;
        std::vector<std::uint8_t> data;
    };

    explicit JitterBuffer(std::size_t depth);

    /// timestamp 比最早元素还老 → 说明过期,忽略并返回 false。
    bool push(Frame frame);

    /// 未填满返回 nullopt;否则返回队首帧。
    std::optional<Frame> pop();

    std::size_t size()  const noexcept { return queue_.size(); }
    std::size_t depth() const noexcept { return depth_; }

private:
    std::deque<Frame> queue_;
    std::size_t       depth_;
};

}  // namespace vs
