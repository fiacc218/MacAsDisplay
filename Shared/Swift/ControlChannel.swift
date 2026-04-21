import Foundation
import Darwin
import CryptoKit

/// 双向控制信道。一个 UDP socket,同时接收 / 发送 TLV 小包。
///
/// **包格式**
/// ```
/// [magic:4 'VSCC'][version:1][type:1][len:2 BE][payload:N]   // 8 字节定长头
/// ```
///
/// magic 仅为抓包识别用,收包时做宽容匹配(不匹配直接丢)。
/// version 用于未来结构升级;现在固定 1,不兼容即丢。
///
/// **类型**
///   - 0x01 Hello:peer 启动 / 心跳,payload 空
///   - 0x02 Capability:Receiver → Sender 报告原生分辨率 / scale / 目标 fps
///   - 0x03 KeyframeRequest:Receiver → Sender,请求下一帧强制 I-frame
///          (收到后 VideoEncoder 在下一次 encode 打 kVTEncodeFrameOptionKey_ForceKeyFrame)
///
/// 线程模型:
///   - 一个 DispatchSourceRead 在后台队列上读包、解 TLV、派发回调
///   - 回调都在该后台队列上 —— owner 负责必要的主线程 hop
///   - send() 在调用线程同步 sendto
final class ControlChannel {

    /// 'V''S''C''C'
    static let magic: UInt32 = 0x5653_4343
    /// 协议版本。v1 = 无认证(已废);v2 = PSK + HMAC + nonce。
    static let version: UInt8 = 2
    static let headerSize: Int = 8
    /// 每包附带的 8 字节单调递增 nonce。
    static let nonceSize: Int = 8
    /// 每包附带的 16 字节 HMAC-SHA256(截断)。
    static let tagSize: Int = 16
    /// 有效包最小长度(header + nonce + tag,空 payload)。
    static let minPacketSize: Int = headerSize + nonceSize + tagSize

    enum PacketType: UInt8 {
        case hello            = 0x01
        case capability       = 0x02
        case keyframeRequest  = 0x03
        // 0x05 历史上是 InputEvent;当前版本纯显示,不做反向输入注入,因此保留
        // 编号作为占位,避免未来复用歧义,不在代码里列出。
    }

    // MARK: - Payloads

    /// Receiver → Sender:我这屏是多大的,用这个建 VirtualDisplay。
    struct Capability {
        var widthPx:  Int32
        var heightPx: Int32
        /// backing scale × 1000。2000 = @2x Retina。
        var scaleX1000: Int32
        var fps: Int32

        /// 固定 16 字节 LE。
        func encode() -> Data {
            var d = Data(count: 16)
            d.withUnsafeMutableBytes { raw in
                let p = raw.baseAddress!.assumingMemoryBound(to: Int32.self)
                p[0] = widthPx.littleEndian
                p[1] = heightPx.littleEndian
                p[2] = scaleX1000.littleEndian
                p[3] = fps.littleEndian
            }
            return d
        }
        static func decode(_ d: Data) -> Capability? {
            guard d.count >= 16 else { return nil }
            return d.withUnsafeBytes { raw -> Capability in
                let p = raw.baseAddress!.assumingMemoryBound(to: Int32.self)
                return Capability(
                    widthPx:    Int32(littleEndian: p[0]),
                    heightPx:   Int32(littleEndian: p[1]),
                    scaleX1000: Int32(littleEndian: p[2]),
                    fps:        Int32(littleEndian: p[3])
                )
            }
        }
    }

    // MARK: - Callbacks (fire on recv queue)

    var onHello:            ((sockaddr_in) -> Void)?
    var onCapability:       ((Capability, sockaddr_in) -> Void)?
    var onKeyframeRequest:  (() -> Void)?

    // MARK: - State

    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "xyz.dashuo.macasdisplay.control", qos: .userInitiated)
    private var readSource: DispatchSourceRead?
    private let peerLock = NSLock()
    private var peer: sockaddr_in?   // 最近一次收到包的对端 —— send() 默认发到这里

    // --- auth state ---
    private var key: SymmetricKey?

    /// 发送端单调计数器。用 host time (ns) 做初值,进程重启不会回退。
    private var sendNonce: UInt64 = {
        var t = timespec()
        clock_gettime(CLOCK_REALTIME, &t)
        return UInt64(t.tv_sec) &* 1_000_000_000 &+ UInt64(t.tv_nsec)
    }()
    private let sendNonceLock = NSLock()

    /// 每对端记录已见 nonce high-water,拒绝 ≤ 的重放。key = "ip:port"
    private var lastSeenNonce: [String: UInt64] = [:]
    private let lastSeenNonceLock = NSLock()

    /// 诊断计数。
    private(set) var rxAccepted: UInt64 = 0
    private(set) var rxRejectedAuth: UInt64 = 0
    private(set) var rxRejectedReplay: UInt64 = 0
    private(set) var rxRejectedFormat: UInt64 = 0

    /// 安装 PSK。start() 之前必须调;没 key 的话 send/recv 全丢。
    func setKey(_ key: SymmetricKey) {
        self.key = key
    }

    // MARK: - Lifecycle

    /// 绑定 0.0.0.0:port 并开始接收。成功返回 true。
    func start(listenPort: UInt16) -> Bool {
        stop()

        let s = socket(AF_INET, SOCK_DGRAM, 0)
        if s < 0 {
            Log.net.error("ControlChannel socket() failed errno=\(errno)")
            return false
        }

        var reuse: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // 需要往 255.255.255.255 / 169.254.255.255 / 子网广播地址发现发现包。
        // Darwin 要求显式开 SO_BROADCAST,否则 sendto 返回 EACCES。
        var bcast: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_BROADCAST, &bcast, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family      = sa_family_t(AF_INET)
        addr.sin_port        = listenPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        let bindOK = withUnsafePointer(to: &addr) { p -> Bool in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        if !bindOK {
            Log.net.error("ControlChannel bind(:\(listenPort)) failed errno=\(errno)")
            close(s); return false
        }

        // 非阻塞 —— DispatchSourceRead 触发后 drain 到 EAGAIN。
        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)

        fd = s

        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.drain() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        src.resume()
        readSource = src

        Log.net.info("ControlChannel listening on :\(listenPort)")
        return true
    }

    func stop() {
        readSource?.cancel()
        readSource = nil
        // fd 在 cancel handler 里 close
        peerLock.lock(); peer = nil; peerLock.unlock()
    }

    deinit { stop() }

    // MARK: - Send

    /// 从 sockaddr_in 里掏 "a.b.c.d" 字符串。解析失败返回 nil。
    static func ipString(from addr: sockaddr_in) -> String? {
        var a = addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let ok = withUnsafePointer(to: &a.sin_addr) { p in
            inet_ntop(AF_INET, p, &buf, socklen_t(INET_ADDRSTRLEN)) != nil
        }
        return ok ? String(cString: buf) : nil
    }

    /// 手工指定对端;也可以不调,第一次收到 peer 包后会自动记住。
    func setPeer(host: String, port: UInt16) {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = port.bigEndian
        if inet_pton(AF_INET, host, &addr.sin_addr) == 1 {
            peerLock.lock(); peer = addr; peerLock.unlock()
        }
    }

    func send(_ type: PacketType, payload: Data = Data()) {
        peerLock.lock(); let dst = peer; peerLock.unlock()
        guard var addr = dst else { return }
        guard let pkt = buildPacket(type: type, payload: payload) else { return }
        rawSendto(pkt, to: &addr)
    }

    /// 发到指定 host:port,**不改变 peer**。用于主动发现广播 / 定向探测。
    /// host 支持常规 IPv4 字面量,也支持 255.255.255.255 / 169.254.255.255 / 子网广播。
    func sendTo(_ type: PacketType, payload: Data = Data(), host: String, port: UInt16) {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return }
        guard let pkt = buildPacket(type: type, payload: payload) else { return }
        rawSendto(pkt, to: &addr)
    }

    /// 把同一包向本机每个活动接口的广播地址各发一次,帮对端做零配置发现。
    /// 每次广播用一个独立 nonce(接收端按源 IP:port 维护 high-water,互不干扰)。
    ///
    /// **关键:每个目标临时起一个 socket 并 `IP_BOUND_IF` 绑到对应接口**。
    /// 不这样做的话,Darwin 路由表只会让广播从默认接口出去,TB Bridge 一侧的
    /// 169.254.255.255 包根本不会进 bridge0,对端收不到。实测过:Sender 只看见
    /// LAN 广播到达,TB 广播静默丢失 —— 就是这个原因。
    func broadcast(_ type: PacketType, payload: Data = Data(), port: UInt16) {
        guard let pkt = buildPacket(type: type, payload: payload) else { return }

        var dst = sockaddr_in()
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port   = port.bigEndian

        for t in NetworkDiscovery.localBroadcastTargets() {
            guard inet_pton(AF_INET, t.address, &dst.sin_addr) == 1 else { continue }
            let s = socket(AF_INET, SOCK_DGRAM, 0)
            if s < 0 { continue }
            var yes: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
            if t.ifIndex != 0 {
                var idx = t.ifIndex
                // IP_BOUND_IF 强制包从该接口出,不走默认路由。
                setsockopt(s, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout<UInt32>.size))
            }
            _ = pkt.withUnsafeBytes { raw -> Int in
                withUnsafePointer(to: &dst) { p -> Int in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(s, raw.baseAddress, raw.count, 0,
                               sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            close(s)
        }
    }

    // MARK: packet build / raw sendto

    private func buildPacket(type: PacketType, payload: Data) -> Data? {
        guard payload.count <= 0xFFFF else { return nil }
        guard let key = self.key, fd >= 0 else { return nil }

        // 取一个全新 nonce。
        sendNonceLock.lock()
        sendNonce &+= 1
        let nonce = sendNonce
        sendNonceLock.unlock()

        // 头 8 字节
        var hdr = Data(count: Self.headerSize)
        hdr.withUnsafeMutableBytes { raw in
            let b = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let magicBE = Self.magic.bigEndian
            withUnsafeBytes(of: magicBE) { _ = memcpy(b, $0.baseAddress, 4) }
            b[4] = Self.version
            b[5] = type.rawValue
            let lenBE = UInt16(payload.count).bigEndian
            withUnsafeBytes(of: lenBE) { _ = memcpy(b + 6, $0.baseAddress, 2) }
        }
        // nonce 8 字节 BE
        var nonceBlob = Data(count: Self.nonceSize)
        nonceBlob.withUnsafeMutableBytes { raw in
            let nonceBE = nonce.bigEndian
            withUnsafeBytes(of: nonceBE) { _ = memcpy(raw.baseAddress, $0.baseAddress, 8) }
        }

        // HMAC 覆盖 [header][nonce][payload]
        let signed = hdr + nonceBlob + payload
        let tag = ControlAuth.tag(key: key, data: signed)
        return signed + tag
    }

    private func rawSendto(_ pkt: Data, to addr: inout sockaddr_in) {
        guard fd >= 0 else { return }
        _ = pkt.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &addr) { p -> Int in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, raw.baseAddress, raw.count, 0,
                           sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    // MARK: - Recv

    private func drain() {
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            var src = sockaddr_in()
            var slen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n: ssize_t = buf.withUnsafeMutableBufferPointer { b -> ssize_t in
                withUnsafeMutablePointer(to: &src) { ps -> ssize_t in
                    ps.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(fd, b.baseAddress, b.count, 0, sa, &slen)
                    }
                }
            }
            if n <= 0 { break }

            // 记录对端(无论 Sender 是先手还是后手)
            peerLock.lock(); peer = src; peerLock.unlock()

            parse(Data(bytes: buf, count: Int(n)), from: src)
        }
    }

    private func parse(_ d: Data, from src: sockaddr_in) {
        guard let key = self.key else { rxRejectedAuth &+= 1; return }
        guard d.count >= Self.minPacketSize else { rxRejectedFormat &+= 1; return }

        let start = d.startIndex

        let magic: UInt32 = d.withUnsafeBytes { raw in
            raw.baseAddress!.assumingMemoryBound(to: UInt32.self).pointee
        }
        guard UInt32(bigEndian: magic) == Self.magic else { rxRejectedFormat &+= 1; return }
        let version = d[start + 4]
        guard version == Self.version else { rxRejectedFormat &+= 1; return }
        let typeRaw = d[start + 5]
        guard let type = PacketType(rawValue: typeRaw) else { rxRejectedFormat &+= 1; return }
        let lenBE: UInt16 = d.dropFirst(6).withUnsafeBytes { raw in
            raw.baseAddress!.assumingMemoryBound(to: UInt16.self).pointee
        }
        let len = Int(UInt16(bigEndian: lenBE))
        let totalExpected = Self.headerSize + Self.nonceSize + len + Self.tagSize
        guard d.count >= totalExpected else { rxRejectedFormat &+= 1; return }

        let nonceStart = start + Self.headerSize
        let payloadStart = nonceStart + Self.nonceSize
        let tagStart = payloadStart + len

        // 恒时间 HMAC 验证。
        let signed = d.subdata(in: start..<tagStart)
        let tag    = d.subdata(in: tagStart..<(tagStart + Self.tagSize))
        guard ControlAuth.verify(key: key, data: signed, tag: tag) else {
            rxRejectedAuth &+= 1
            return
        }

        // 解 nonce + 反重放。
        let nonceBE: UInt64 = d.subdata(in: nonceStart..<(nonceStart + Self.nonceSize))
            .withUnsafeBytes { raw in raw.baseAddress!.assumingMemoryBound(to: UInt64.self).pointee }
        let nonce = UInt64(bigEndian: nonceBE)
        let peerKey = Self.peerKey(src)
        lastSeenNonceLock.lock()
        let prev = lastSeenNonce[peerKey] ?? 0
        if nonce <= prev {
            lastSeenNonceLock.unlock()
            rxRejectedReplay &+= 1
            return
        }
        lastSeenNonce[peerKey] = nonce
        lastSeenNonceLock.unlock()

        rxAccepted &+= 1

        let payload = d.subdata(in: payloadStart..<tagStart)
        switch type {
        case .hello:
            onHello?(src)
        case .capability:
            if let cap = Capability.decode(payload) { onCapability?(cap, src) }
        case .keyframeRequest:
            onKeyframeRequest?()
        }
        _ = payload   // silence unused-warning for empty-payload types
    }

    private static func peerKey(_ a: sockaddr_in) -> String {
        "\(Self.ipString(from: a) ?? "?"):\(UInt16(bigEndian: a.sin_port))"
    }
}
