#include "JitterBuffer.hpp"

#include <algorithm>

namespace vs {

JitterBuffer::JitterBuffer(std::size_t depth) : depth_(depth) {}

bool JitterBuffer::push(Frame f) {
    // TODO: 找到正确插入位置保持 timestamp_ms 递增。
    // 当前占位实现:直接 push_back(包不会乱序时亦可)。
    if (!queue_.empty() && f.timestamp_ms < queue_.front().timestamp_ms) {
        return false;
    }
    queue_.push_back(std::move(f));
    return true;
}

std::optional<JitterBuffer::Frame> JitterBuffer::pop() {
    if (queue_.size() < depth_) return std::nullopt;
    Frame f = std::move(queue_.front());
    queue_.pop_front();
    return f;
}

}  // namespace vs
