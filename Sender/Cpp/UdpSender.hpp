// 发送端 UDP socket 封装。线程模型:单线程发送(调用方保证)。
#pragma once

#include <sys/socket.h>
#include <netinet/in.h>

#include <cstddef>
#include <cstdint>
#include <string>

namespace vs {

/// 同步 sendto 封装。一个实例对应一个目标地址。
class UdpSender {
public:
    UdpSender();
    ~UdpSender();
    UdpSender(const UdpSender&)            = delete;
    UdpSender& operator=(const UdpSender&) = delete;

    /// 打开 socket(AF_INET, SOCK_DGRAM)。成功返回 true。
    bool open();

    /// 设置对端。host 只支持点分十进制 IPv4(Thunderbolt Bridge 场景足够)。
    bool set_target(const std::string& host, std::uint16_t port);

    /// 同步发一个包,返回 sendto 的返回值(-1 表示 errno 可查)。
    long send(const std::uint8_t* data, std::size_t size);

    /// 关闭 socket。析构时自动调用。
    void close();

private:
    int             fd_       = -1;
    sockaddr_in     addr_{};      // 只用 IPv4
    bool            has_addr_ = false;
};

}  // namespace vs
