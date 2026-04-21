import Foundation
import CoreMedia

/// CMVideoFormatDescription 的轻量序列化 —— 仅用于 Sender→Receiver 握手。
///
/// 做法:
///   - 提取 (codec, width, height, extensions CFDictionary)
///   - 用 PropertyListSerialization(binary plist)编码
///   - Receiver 侧反向 → CMVideoFormatDescriptionCreate
///
/// Extensions 里是像素纵横比、色彩空间、SampleDescriptionExtensionAtoms 等
/// plist 友好类型(CFString / CFNumber / CFData / 嵌套 CFDictionary)。
enum FormatDescCodec {

    private static let codecKey  = "codec"
    private static let widthKey  = "w"
    private static let heightKey = "h"
    private static let extKey    = "ext"

    /// 成功返回 binary plist bytes;extensions 含非 plist 类型时会失败。
    static func encode(_ fmt: CMFormatDescription) -> Data? {
        let codec = CMFormatDescriptionGetMediaSubType(fmt)
        let dims  = CMVideoFormatDescriptionGetDimensions(fmt)
        let ext   = CMFormatDescriptionGetExtensions(fmt) as? [String: Any] ?? [:]

        let dict: [String: Any] = [
            codecKey:  NSNumber(value: codec),
            widthKey:  NSNumber(value: dims.width),
            heightKey: NSNumber(value: dims.height),
            extKey:    ext,
        ]
        return try? PropertyListSerialization.data(
            fromPropertyList: dict, format: .binary, options: 0
        )
    }

    /// 返回重建好的 CMVideoFormatDescription。extensions 反序列化不动就退到 minimal。
    static func decode(_ bytes: Data) -> CMFormatDescription? {
        guard let plist = try? PropertyListSerialization.propertyList(
                  from: bytes, options: 0, format: nil),
              let d = plist as? [String: Any],
              let codecNum  = d[codecKey]  as? NSNumber,
              let widthNum  = d[widthKey]  as? NSNumber,
              let heightNum = d[heightKey] as? NSNumber
        else { return nil }

        let codec  = CMVideoCodecType(codecNum.uint32Value)
        let width  = widthNum.int32Value
        let height = heightNum.int32Value
        let ext    = d[extKey] as? [String: Any]

        var out: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codec,
            width: width, height: height,
            extensions: ext as CFDictionary?,
            formatDescriptionOut: &out
        )
        return status == noErr ? out : nil
    }
}
