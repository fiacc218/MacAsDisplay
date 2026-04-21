#include "UdpSender.hpp"

#include <arpa/inet.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>

namespace vs {

UdpSender::UdpSender() = default;

UdpSender::~UdpSender() { close(); }

bool UdpSender::open() {
    if (fd_ >= 0) return true;
    fd_ = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (fd_ < 0) return false;

    // 扩大发送缓冲,降低突发下丢包。
    int sndbuf = 4 * 1024 * 1024;
    ::setsockopt(fd_, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
    return true;
}

bool UdpSender::set_target(const std::string& host, std::uint16_t port) {
    std::memset(&addr_, 0, sizeof(addr_));
    addr_.sin_family = AF_INET;
    addr_.sin_port   = htons(port);
    if (::inet_pton(AF_INET, host.c_str(), &addr_.sin_addr) != 1) {
        has_addr_ = false;
        return false;
    }
    has_addr_ = true;
    return true;
}

long UdpSender::send(const std::uint8_t* data, std::size_t size) {
    if (fd_ < 0 || !has_addr_) { errno = EINVAL; return -1; }
    return ::sendto(fd_, data, size, 0,
                    reinterpret_cast<const sockaddr*>(&addr_), sizeof(addr_));
}

void UdpSender::close() {
    if (fd_ >= 0) {
        ::close(fd_);
        fd_ = -1;
    }
    has_addr_ = false;
}

}  // namespace vs
