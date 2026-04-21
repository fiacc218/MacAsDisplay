import Foundation
import Darwin
import SystemConfiguration

/// 枚举本机活动 IPv4 接口并给出"人话"显示名(Wi-Fi / Thunderbolt Bridge /
/// Ethernet …),用于 Receiver 启动屏展示,方便用户眼读后填到 Sender。
///
/// 友好名来自 `SCNetworkInterfaceCopyAll` + `SCNetworkInterfaceGetLocalizedDisplayName`,
/// 和"系统设置 → 网络"面板里写的一模一样。SC 查不到时(罕见,比如 bridge0 有时
/// 不在 SC 列表里)走前缀启发式兜底。
enum InterfaceIPs {

    struct Entry: Equatable {
        let bsdName: String       // "en0" / "bridge0"
        let displayName: String   // "Wi-Fi" / "Thunderbolt Bridge"
        let ipv4: String          // "192.168.1.42"
    }

    /// 按接口类型稳定排序(TB 优先 → Ethernet → Wi-Fi → 其他),同类内按 BSD 名排。
    /// 顺序影响 Receiver 屏上展示先后 —— TB Bridge 放最上,因为连副屏场景用户
    /// 更常用它。
    static func active() -> [Entry] {
        let scNames = currentSCDisplayNames()

        var out: [Entry] = []
        var seen: Set<String> = []

        var ifapPtr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifapPtr) == 0, let first = ifapPtr else { return [] }
        defer { freeifaddrs(ifapPtr) }

        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cur {
            let e = ptr.pointee
            cur = e.ifa_next

            let flags = Int32(e.ifa_flags)
            if (flags & IFF_UP) == 0 { continue }
            if (flags & IFF_LOOPBACK) != 0 { continue }

            guard let sa = e.ifa_addr else { continue }
            if sa.pointee.sa_family != sa_family_t(AF_INET) { continue }

            let bsd = String(cString: e.ifa_name)
            if shouldHide(bsd) { continue }

            // 读 IPv4
            let ip: String? = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin -> String? in
                var a = sin.pointee.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                let s = String(cString: buf)
                return (s.isEmpty || s.hasPrefix("0.")) ? nil : s
            }
            guard let ipStr = ip else { continue }

            let key = "\(bsd):\(ipStr)"
            guard seen.insert(key).inserted else { continue }

            let display = scNames[bsd] ?? friendlyGuess(bsd)
            out.append(Entry(bsdName: bsd, displayName: display, ipv4: ipStr))
        }

        out.sort { lhs, rhs in
            let lp = sortPriority(lhs)
            let rp = sortPriority(rhs)
            if lp != rp { return lp < rp }
            return lhs.bsdName < rhs.bsdName
        }
        return out
    }

    // MARK: - Classification

    /// 虚拟 / 内部接口 —— 用户看了也没用,屏上不显示。
    ///   awdl* : AirDrop peer-to-peer
    ///   llw*  : 低延迟无线(AWDL 亲戚)
    ///   anpi* : Apple 私有 peering
    ///   utun* : VPN / system tunnel
    ///   ap1   : 私有 AP(共享网络时系统创建)
    ///   vmnet*/vnic*/bridge1+ : VMware / Parallels / 虚拟化桥
    ///   gif0/stf0 : 隧道接口
    private static func shouldHide(_ name: String) -> Bool {
        let hidden = ["awdl", "llw", "anpi", "utun", "vmnet", "vnic", "gif", "stf"]
        for p in hidden where name.hasPrefix(p) { return true }
        // "ap1/ap2" 过滤,但别碰以 ap 开头的其他真实接口(macOS 上目前没有)
        if name.hasPrefix("ap"), name.count >= 3,
           let c = name.last, c.isNumber { return true }
        return false
    }

    /// SystemConfiguration 查不到接口名时的启发式兜底。
    private static func friendlyGuess(_ bsd: String) -> String {
        if bsd == "en0" { return "Wi-Fi" }          // 绝大多数 Mac 的惯例
        if bsd.hasPrefix("en") { return "Ethernet" }
        if bsd.hasPrefix("bridge") { return "Thunderbolt Bridge" }
        return bsd
    }

    /// 排序优先级:TB 最上,接着 Ethernet,再 Wi-Fi,最后其他。
    private static func sortPriority(_ e: Entry) -> Int {
        let name = e.displayName.lowercased()
        if name.contains("thunderbolt") || e.bsdName.hasPrefix("bridge") { return 0 }
        if name.contains("ethernet") { return 1 }
        if name.contains("wi-fi") || name.contains("wifi") { return 2 }
        return 3
    }

    /// 本机每个活动 IPv4 接口的 (索引, 广播地址) 对。
    /// 广播发现:Receiver 启动后没对端,对每个接口定向广播 Hello/Capability。
    /// 索引配合 `IP_BOUND_IF` 把 sendto 锁到指定接口 —— 否则 OS 默认路由会把
    /// 所有"广播"都从同一张网卡(通常 Wi-Fi)出去,TB 桥上的 169.254/16 永远
    /// 播不到,Sender 侧就只能看到 Wi-Fi 那个 IP。
    ///
    /// 只收 `IFF_BROADCAST` 且非 `IFF_POINTOPOINT` 的接口。
    struct BroadcastTarget: Equatable {
        let ifIndex: UInt32
        let address: String
    }

    static func broadcastAddresses() -> [BroadcastTarget] {
        var out: [BroadcastTarget] = []
        var seen: Set<String> = []

        var ifapPtr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifapPtr) == 0, let first = ifapPtr else { return [] }
        defer { freeifaddrs(ifapPtr) }

        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cur {
            let e = ptr.pointee
            cur = e.ifa_next

            let flags = Int32(e.ifa_flags)
            if (flags & IFF_UP) == 0 { continue }
            if (flags & IFF_LOOPBACK) != 0 { continue }
            if (flags & IFF_BROADCAST) == 0 { continue }
            if (flags & IFF_POINTOPOINT) != 0 { continue }

            guard let sa = e.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let bsd = String(cString: e.ifa_name)
            if shouldHide(bsd) { continue }

            // ifa_dstaddr 在 BROADCAST 接口上含广播地址(BSD union,name 源自 PtP)。
            guard let ba = e.ifa_dstaddr, ba.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let ip: String? = ba.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin -> String? in
                var a = sin.pointee.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                let s = String(cString: buf)
                return (s.isEmpty || s == "0.0.0.0") ? nil : s
            }
            guard let ipStr = ip, seen.insert(ipStr).inserted else { continue }

            let idx = if_nametoindex(bsd)
            guard idx != 0 else { continue }
            out.append(BroadcastTarget(ifIndex: idx, address: ipStr))
        }
        return out
    }

    // MARK: - SystemConfiguration lookup

    private static func currentSCDisplayNames() -> [String: String] {
        var map: [String: String] = [:]
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return map }
        for iface in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { continue }
            guard let name = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? else { continue }
            map[bsd] = name
        }
        return map
    }
}
