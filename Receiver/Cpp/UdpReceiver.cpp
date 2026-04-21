#include "UdpReceiver.hpp"

#include <sys/event.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>

#include <array>
#include <cerrno>
#include <cstring>

namespace vs {

UdpReceiver::UdpReceiver() = default;

UdpReceiver::~UdpReceiver() { stop(); }

bool UdpReceiver::start(std::uint16_t port, OnPacket cb) {
    if (running_.load()) return false;
    on_packet_ = std::move(cb);

    fd_ = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (fd_ < 0) return false;

    // 扩大接收缓冲。
    int rcvbuf = 4 * 1024 * 1024;
    ::setsockopt(fd_, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));

    // 非阻塞:kevent 只保证 1 个包可读,但我们想循环 drain 队列。
    int flags = ::fcntl(fd_, F_GETFL, 0);
    ::fcntl(fd_, F_SETFL, flags | O_NONBLOCK);

    sockaddr_in addr{};
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port        = htons(port);
    if (::bind(fd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        ::close(fd_); fd_ = -1;
        return false;
    }

    kq_ = ::kqueue();
    if (kq_ < 0) {
        ::close(fd_); fd_ = -1;
        return false;
    }
    struct kevent ev;
    EV_SET(&ev, fd_, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, nullptr);
    ::kevent(kq_, &ev, 1, nullptr, 0, nullptr);

    running_ = true;
    worker_ = std::thread([this] { run(); });
    return true;
}

void UdpReceiver::stop() {
    running_ = false;
    if (worker_.joinable()) worker_.join();
    if (fd_ >= 0) { ::close(fd_); fd_ = -1; }
    if (kq_ >= 0) { ::close(kq_); kq_ = -1; }
}

void UdpReceiver::run() {
    std::array<std::uint8_t, 65536> buf{};
    while (running_.load()) {
        struct kevent ev;
        struct timespec ts{0, 50 * 1000 * 1000};  // 50ms 唤醒一次,便于响应 stop
        int n = ::kevent(kq_, nullptr, 0, &ev, 1, &ts);
        if (n <= 0) continue;
        if (ev.filter == EVFILT_READ) {
            // 尽量一次性把内核队列里所有包读完。
            while (true) {
                sockaddr_in src{};
                socklen_t   slen = sizeof(src);
                ssize_t r = ::recvfrom(fd_, buf.data(), buf.size(), 0,
                                       reinterpret_cast<sockaddr*>(&src), &slen);
                if (r <= 0) {
                    if (errno != EAGAIN && errno != EWOULDBLOCK) {
                        // 真错误:记下就好,不退出 worker。
                    }
                    break;
                }
                if (on_packet_) on_packet_(buf.data(), static_cast<std::size_t>(r));
            }
        }
    }
}

}  // namespace vs
