import Foundation
import Darwin

/// 本机活动接口的 IPv4 广播地址枚举。
///
/// 用于 Receiver 在未知 Sender IP 时广播 Capability —— Sender 收包即学到对端,
/// 无需手工填 `VS.targetHost`。
enum NetworkDiscovery {

    /// (ifindex, 广播地址) —— broadcast 时用 IP_BOUND_IF 绑到该接口发送,
    /// 否则 Darwin 路由表只会把包丢给默认接口,TB Bridge 的广播根本出不去。
    struct BroadcastTarget {
        let ifIndex: UInt32   // 0 表示未知,忽略 bind
        let ifName:  String
        let address: String
    }

    /// 扫描 `getifaddrs`,返回所有 up / 非 loopback / 支持 broadcast 的 IPv4
    /// 接口对应的 **子网广播地址**,带接口 index 以便精确绑定出口。
    ///
    /// macOS 的 `<ifaddrs.h>` 用 `#define ifa_broadaddr ifa_dstaddr` —— 这个宏
    /// 不会随 Swift 模块 import 过来,所以直接读 `ifa_dstaddr`(在 IFF_BROADCAST
    /// 的接口上它就是广播地址)。
    static func localBroadcastTargets() -> [BroadcastTarget] {
        var out: [BroadcastTarget] = []
        var seen: Set<String> = []

        var ifapPtr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifapPtr) == 0, let first = ifapPtr else { return [] }
        defer { freeifaddrs(ifapPtr) }

        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cur {
            let entry = ptr.pointee
            cur = entry.ifa_next

            let flags = Int32(entry.ifa_flags)
            if (flags & IFF_UP)        == 0 { continue }
            if (flags & IFF_LOOPBACK)  != 0 { continue }
            if (flags & IFF_BROADCAST) == 0 { continue }

            guard let saPtr = entry.ifa_dstaddr else { continue }
            if saPtr.pointee.sa_family != sa_family_t(AF_INET) { continue }

            let ifName = String(cString: entry.ifa_name)
            let ifIdx  = if_nametoindex(ifName)   // 0 on failure

            let bcast: String? = saPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin -> String? in
                var a = sin.pointee.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                let s = String(cString: buf)
                return (s.isEmpty || s == "0.0.0.0") ? nil : s
            }
            guard let addr = bcast else { continue }

            let key = "\(ifIdx):\(addr)"
            if seen.insert(key).inserted {
                out.append(BroadcastTarget(ifIndex: ifIdx, ifName: ifName, address: addr))
            }
        }
        return out
    }

    /// 旧签名 —— 只要地址字符串。保持兼容,但新代码应优先用
    /// `localBroadcastTargets()` 以便做接口绑定。
    static func localBroadcastAddresses() -> [String] {
        var s: Set<String> = ["169.254.255.255"]
        for t in localBroadcastTargets() { s.insert(t.address) }
        return Array(s)
    }

    /// 返回去 `host` 这条路由**出站接口**的 IPv4 MTU(bytes)。探测失败 → nil。
    ///
    /// 工作原理:
    ///   1. 开一个 dummy UDP socket,`connect()` 到 host —— Darwin 会选路由并绑本地地址
    ///   2. `getsockname()` 读出本地被绑到哪个 IP
    ///   3. 在 `getifaddrs` 链表里找 AF_INET 项地址与步骤 2 一致的接口,记下 `ifa_name`
    ///   4. 再扫 AF_LINK 项匹配同名,从 `ifa_data` 里的 `if_data.ifi_mtu` 拿 MTU
    ///
    /// 不走 `ioctl(SIOCGIFMTU)` —— Swift 里 `ifreq` 的 union 字段不好操作;
    /// AF_LINK 的 `if_data` 路径更干净,没有 ioctl 参数打包的坑。
    static func interfaceMTU(toward host: String) -> Int? {
        // ── 1) dummy UDP 连到目标,让内核选路由
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return nil }
        defer { close(s) }

        var dst = sockaddr_in()
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port   = UInt16(9).bigEndian   // 任意端口,不会真正发包
        guard inet_pton(AF_INET, host, &dst.sin_addr) == 1 else { return nil }

        let connOK = withUnsafePointer(to: &dst) { p -> Bool in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connOK else { return nil }

        // ── 2) 问内核:你给我选了哪个本地 IP
        var local = sockaddr_in()
        var len   = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameOK = withUnsafeMutablePointer(to: &local) { p -> Bool in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(s, sa, &len) == 0
            }
        }
        guard nameOK else { return nil }
        let localAddr = local.sin_addr.s_addr

        // ── 3) ifaddrs 扫一遍:AF_INET 匹配 IP 找接口名,AF_LINK 同名找 MTU
        var ifapPtr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifapPtr) == 0, let first = ifapPtr else { return nil }
        defer { freeifaddrs(ifapPtr) }

        // pass 1:找接口名
        var ifName: String? = nil
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cur {
            let e = p.pointee
            cur = e.ifa_next
            guard let sa = e.ifa_addr else { continue }
            if sa.pointee.sa_family != sa_family_t(AF_INET) { continue }
            let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr
            }
            if a == localAddr {
                ifName = String(cString: e.ifa_name)
                break
            }
        }
        guard let name = ifName else { return nil }

        // pass 2:AF_LINK 同名读 if_data.ifi_mtu
        cur = first
        while let p = cur {
            let e = p.pointee
            cur = e.ifa_next
            guard let sa = e.ifa_addr else { continue }
            if sa.pointee.sa_family != sa_family_t(AF_LINK) { continue }
            if String(cString: e.ifa_name) != name { continue }
            guard let data = e.ifa_data else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            return Int(d.ifi_mtu)
        }
        return nil
    }
}
