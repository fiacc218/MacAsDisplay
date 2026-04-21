// 发送管线:切片 + UDP,一次 submit 把整帧打出去。
//
// 提供**两套 API**:
//   1) C++ 侧:`vs::SendPipeline` class,C++ 代码直接用
//   2) C 侧(extern "C"):用于 Swift —— Swift-C++ Interop 对含有 std::vector/
//      std::string 等成员的 non-copyable class 支持不稳,走 C opaque 指针最省心
#pragma once

#include <cstddef>
#include <cstdint>

#ifdef __cplusplus
#include "UdpSender.hpp"
#include <string>
#include <vector>

namespace vs {

class SendPipeline {
public:
    SendPipeline()  = default;
    ~SendPipeline() = default;
    SendPipeline(const SendPipeline&)            = delete;
    SendPipeline& operator=(const SendPipeline&) = delete;

    /// 打开 socket + 设置目标 + 分配 scratch。
    /// `payload_max_size` = UDP payload 去掉 12B PacketHeader 后的上限。
    bool configure(const std::string& host,
                   std::uint16_t port,
                   std::size_t payload_max_size);

    /// 提交整帧,返回成功 sendto 的包数(-1 = 未配置)。
    long submit(std::uint32_t timestamp_ms,
                const std::uint8_t* frame_data,
                std::size_t frame_size);

    std::uint64_t bytes_sent() const { return bytes_sent_; }

private:
    UdpSender                 sender_;
    std::size_t               payload_max_ = 0;
    std::uint32_t             next_seq_    = 0;
    std::uint64_t             bytes_sent_  = 0;
    std::vector<std::uint8_t> scratch_;
};

}  // namespace vs

extern "C" {
#endif  // __cplusplus

typedef struct VSSendPipeline VSSendPipeline;

VSSendPipeline* vs_pipeline_create(void);
void            vs_pipeline_destroy(VSSendPipeline* p);

/// 成功返回 1。host 是点分 IPv4。
int  vs_pipeline_configure(VSSendPipeline* p,
                           const char*     host,
                           uint16_t        port,
                           size_t          payload_max_size);

/// 返回发出的包数。size == 0 返回 0;未配置返回 -1。
long vs_pipeline_submit(VSSendPipeline*       p,
                        uint32_t              timestamp_ms,
                        const uint8_t*        frame_data,
                        size_t                frame_size);

uint64_t vs_pipeline_bytes_sent(const VSSendPipeline* p);

#ifdef __cplusplus
}  // extern "C"
#endif
