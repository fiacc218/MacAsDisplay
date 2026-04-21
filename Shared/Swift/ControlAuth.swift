import Foundation
import CryptoKit

/// 控制信道的 PSK 认证。
///
/// 设计:
///   - 32 字节预共享密钥(PSK),对称密钥,两端相同。
///   - 每个 TLV 包带一个单调递增的 8 字节 nonce + 16 字节 HMAC-SHA256 tag。
///   - 接收端按对端 (ip:port) 记录 high-water nonce,拒绝 ≤ 的重放。
///   - tag 作用于 [header][nonce][payload],不含 tag 自己。
///
/// 威胁模型:
///   可信链路(TB Bridge / 受信局域网)+ 对抗被动窃听 / 主动重放 / 主动注入。
///   不抗:流量分析 / 时序侧信道 / PSK 泄露。
///
/// UX:
///   启动时尝试从 `~/.config/macasdisplay/psk` 加载;不存在则自动生成并落盘
///   (chmod 0600)。首次配对:把这个文件 scp 到另一台机器同路径。
///   也可以用 `VS_PSK_HEX=<64 hex>` 环境变量覆盖(跑集成测试方便)。
enum ControlAuth {

    /// PSK 文件默认路径(当前用户 home)。
    static var defaultKeyPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/macasdisplay/psk").path
    }

    /// 加载 PSK。顺序:env VS_PSK_HEX → 默认文件 → 生成新的并落盘。
    /// 调用端收到 key 后应该打一条 "using PSK fp=xxxx" 日志,便于诊断两端不一致。
    static func loadOrCreate(at path: String = defaultKeyPath) -> (SymmetricKey, Source) {
        if let hex = ProcessInfo.processInfo.environment["VS_PSK_HEX"],
           let data = Data(hexString: hex), data.count == 32 {
            return (SymmetricKey(data: data), .env)
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count == 32 {
            return (SymmetricKey(data: data), .file(path))
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
        _ = path.withCString { chmod($0, 0o600) }
        return (key, .generated(path))
    }

    enum Source {
        case env
        case file(String)
        case generated(String)

        var description: String {
            switch self {
            case .env:              return "env VS_PSK_HEX"
            case .file(let p):      return "file \(p)"
            case .generated(let p): return "generated at \(p) — copy to peer"
            }
        }
    }

    /// 前 8 字节的 hex,日志里对比两端一致性用。不是安全相关。
    static func fingerprint(_ key: SymmetricKey) -> String {
        let d = key.withUnsafeBytes { Data($0) }
        return d.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// HMAC-SHA256 over `data`,截断到 16 字节。
    static func tag(key: SymmetricKey, data: Data) -> Data {
        let h = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(Array(h).prefix(16))
    }

    /// 常时间比较。
    static func verify(key: SymmetricKey, data: Data, tag: Data) -> Bool {
        guard tag.count == 16 else { return false }
        let expected = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(Array(expected).prefix(16)).ctEquals(tag)
    }
}

extension Data {
    init?(hexString: String) {
        let s = hexString.filter { !$0.isWhitespace }
        guard s.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        self = Data(bytes)
    }

    func ctEquals(_ other: Data) -> Bool {
        guard self.count == other.count else { return false }
        var acc: UInt8 = 0
        for i in 0..<self.count { acc |= self[i] ^ other[i] }
        return acc == 0
    }
}
