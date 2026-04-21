import Foundation
import os

/// 统一日志封装。
///
/// 用 `os.Logger`,输出走 unified logging。
/// 调试时:`log stream --process MacAsDisplaySender --style compact`。
enum Log {
    private static let subsystem: String =
        Bundle.main.bundleIdentifier ?? "xyz.dashuo.macasdisplay"

    static let app     = Logger(subsystem: subsystem, category: "app")
    static let net     = Logger(subsystem: subsystem, category: "net")
    static let video   = Logger(subsystem: subsystem, category: "video")
    static let display = Logger(subsystem: subsystem, category: "display")
    static let render  = Logger(subsystem: subsystem, category: "render")
}
