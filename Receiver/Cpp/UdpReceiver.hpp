// 接收端 UDP socket + kqueue 异步 I/O 封装。
// 内部持有一个 worker 线程,回调在该线程上触发。
#pragma once

#include <sys/socket.h>
#include <netinet/in.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <thread>

namespace vs {

class UdpReceiver {
public:
    /// 回调参数:完整 UDP 包的字节区。
    using OnPacket = std::function<void(const std::uint8_t* data,
                                         std::size_t size)>;

    UdpReceiver();
    ~UdpReceiver();
    UdpReceiver(const UdpReceiver&)            = delete;
    UdpReceiver& operator=(const UdpReceiver&) = delete;

    /// 绑定到 `0.0.0.0:port` 并启动 worker。
    bool start(std::uint16_t port, OnPacket cb);

    /// 停止 worker 并 close socket。idempotent。
    void stop();

    bool is_running() const noexcept { return running_.load(); }

private:
    void run();   // worker 主循环

    int               fd_      = -1;
    int               kq_      = -1;
    std::atomic<bool> running_{false};
    std::thread       worker_;
    OnPacket          on_packet_;
};

}  // namespace vs
