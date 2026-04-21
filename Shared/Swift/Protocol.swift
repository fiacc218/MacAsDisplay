import Foundation

/// 网络协议常量。必须与 Shared/Cpp/FrameFragmenter.hpp 中的
/// `PacketHeader` 定义保持一致 —— 两边手工对齐。
enum NetProtocol {

    /// 魔数(调试用,可选 — 将来若加到包头开头,方便抓包识别)。
    /// 'V''S''C''N' 大端。
    static let magic: UInt32 = 0x5653_434E

    /// 包头字节数:seq(4) + timestamp(4) + frag_idx(2) + frag_total(2)。
    static let headerSize: Int = 12

    /// 协议版本。header 若演进,把 version 加到最前面以便双端协商。
    static let version: UInt8 = 1

    /// timestamp 特殊值:表示这不是视频帧,而是 **CMFormatDescription 侧信道**。
    /// Sender 每秒重发一次,新加入的 Receiver 也能握手上。
    /// 用 0xFFFFFFFF 不与真实 ms 时间戳冲突(ms 累加到该值需要 ~49 天)。
    static let formatDescTimestamp: UInt32 = 0xFFFF_FFFF
}
