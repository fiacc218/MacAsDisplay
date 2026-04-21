import Foundation
import Darwin

/// 本机网络工具:目前只用来查发到给定 host 的路由出站接口 MTU,
/// Sender 据此挑选合适的 UDP payload 分片大小。
enum NetworkDiscovery {

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
