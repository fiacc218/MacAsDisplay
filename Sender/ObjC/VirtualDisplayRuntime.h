// CGVirtualDisplay 私有 API 的最小 Obj-C 入口。
//
// 为什么要 Obj-C helper:
//   - CGVirtualDisplayMode / CGVirtualDisplay 的非默认 init(-initWithWidth:height:refreshRate: /
//     -initWithDescriptor:)接受 C 基本类型(uint32_t / double) —— Swift 纯运行时
//     调用需要手写 IMP cast 和 ARC ownership 猜测,容易翻车。
//   - 这里用两个 @protocol 声明"存在这些 selector",clang 生成正常 objc_msgSend,
//     类本身通过 Class 参数运行时传入 —— 不产生任何 link-time 符号。
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 以 -initWithWidth:height:refreshRate: 创建 CGVirtualDisplayMode 实例。
/// 返回 nil 表示 cls 不响应该 selector。
NSObject * _Nullable VSAllocVirtualDisplayMode(Class cls,
                                                uint32_t width,
                                                uint32_t height,
                                                double refreshRate);

/// 以 -initWithDescriptor: 创建 CGVirtualDisplay 实例。
NSObject * _Nullable VSAllocVirtualDisplay(Class cls, NSObject *descriptor);

/// 对 CGVirtualDisplay 实例调用 -applySettings:。
BOOL VSVirtualDisplayApplySettings(NSObject *display, NSObject *settings);

/// 读取 CGVirtualDisplay 的 displayID(= CGDirectDisplayID)。0 表示未就绪。
uint32_t VSVirtualDisplayGetID(NSObject *display);

/// 调试:列出 CGVirtualDisplay 私有类的所有 method / property / ivar。
/// 通过 NSLog 输出,可从 unified logging 里 grep。
void VSDumpVirtualDisplayAPI(void);

NS_ASSUME_NONNULL_END
