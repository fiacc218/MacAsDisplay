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
///   优先级:env `VS_PSK_HEX` → `~/.config/macasdisplay/psk` → **内置默认 PSK**。
///
///   内置默认:所有下载同一版本二进制的用户都持有相同的 PSK,开箱即可通信,
///   零配置。"安全" 在此仅防同 LAN 邻居随手注入 / 重放,不抗熟悉代码的对手 ——
///   和你家路由器的 WPA2 密码同级,够用。
///
///   想换成自己的密钥:`head -c 32 /dev/urandom > ~/.config/macasdisplay/psk`
///   并两台机器同步这份文件即可,或设 `VS_PSK_HEX=<64 hex>` 环境变量。
enum ControlAuth {

    /// PSK 文件默认路径(当前用户 home)。
    static var defaultKeyPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/macasdisplay/psk").path
    }

    /// 随二进制分发的默认 PSK(32 字节)。两台装相同版本的用户 fp 必然一致 ——
    /// 这是 "开机就能连" 的关键。值本身是一次性随机,没有特殊含义。
    private static let bundledDefaultKeyBytes: [UInt8] = [
        0xa7, 0xf2, 0x10, 0x5b, 0xe4, 0x9c, 0x2d, 0x81,
        0x0a, 0xf3, 0x66, 0xc7, 0xb5, 0x1e, 0x9a, 0x44,
        0xd8, 0x72, 0x3e, 0x01, 0x4f, 0x8b, 0x97, 0xca,
        0x2c, 0x60, 0xfd, 0xe5, 0x11, 0xbf, 0x75, 0x83,
    ]

    /// 加载 PSK。顺序:env VS_PSK_HEX → 默认文件 → 内置默认。
    /// 调用端收到 key 后会打一条 "using PSK fp=xxxx" 日志,便于诊断两端不一致。
    static func loadOrCreate(at path: String = defaultKeyPath) -> (SymmetricKey, Source) {
        if let hex = ProcessInfo.processInfo.environment["VS_PSK_HEX"],
           let data = Data(hexString: hex), data.count == 32 {
            return (SymmetricKey(data: data), .env)
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count == 32 {
            return (SymmetricKey(data: data), .file(path))
        }
        return (SymmetricKey(data: Data(bundledDefaultKeyBytes)), .bundledDefault)
    }

    enum Source {
        case env
        case file(String)
        case bundledDefault

        var description: String {
            switch self {
            case .env:            return "env VS_PSK_HEX"
            case .file(let p):    return "file \(p)"
            case .bundledDefault: return "bundled default"
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
