// Header-only 单生产者 / 单消费者无锁环形队列。
// 用在"捕获线程 → 编码线程"、"接收线程 → 解码线程"之间。
#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <optional>
#include <utility>

namespace vs {

/// SPSC 无锁环形队列。
/// - `Capacity` 必须是 2 的幂,用位与替代取模。
/// - `push` 由生产者线程独占,`pop` 由消费者线程独占,互相之间 lock-free。
template <typename T, std::size_t Capacity>
class RingBuffer {
    static_assert(Capacity >= 2, "Capacity must be >= 2");
    static_assert((Capacity & (Capacity - 1)) == 0,
                  "Capacity must be a power of two");

public:
    RingBuffer() = default;
    RingBuffer(const RingBuffer&) = delete;
    RingBuffer& operator=(const RingBuffer&) = delete;

    /// 满时返回 false。
    bool push(T value) noexcept {
        const auto tail = tail_.load(std::memory_order_relaxed);
        const auto next = (tail + 1) & kMask;
        if (next == head_.load(std::memory_order_acquire)) {
            return false;
        }
        buffer_[tail] = std::move(value);
        tail_.store(next, std::memory_order_release);
        return true;
    }

    /// 空时返回 nullopt。
    std::optional<T> pop() noexcept {
        const auto head = head_.load(std::memory_order_relaxed);
        if (head == tail_.load(std::memory_order_acquire)) {
            return std::nullopt;
        }
        T value = std::move(buffer_[head]);
        head_.store((head + 1) & kMask, std::memory_order_release);
        return value;
    }

    bool empty() const noexcept {
        return head_.load(std::memory_order_acquire) ==
               tail_.load(std::memory_order_acquire);
    }

private:
    static constexpr std::size_t kMask = Capacity - 1;

    std::array<T, Capacity> buffer_{};
    // 避免 false sharing。
    alignas(64) std::atomic<std::size_t> head_{0};
    alignas(64) std::atomic<std::size_t> tail_{0};
};

}  // namespace vs
