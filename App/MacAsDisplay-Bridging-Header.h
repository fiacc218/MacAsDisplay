// Unified bridging header.
// 合并版 —— Main Mac / Secondary Display 两个角色都共存在同一个二进制,
// 所以两端专用的 C++ 模块都要在这里暴露给 Swift。
// 不会被实际调用的部分(e.g. Intel Mac 上永远只跑 Secondary Display,
// Sender 的 UdpSender 类型虽然可见但 Swift 侧没人 instantiate)零成本。

#pragma once

// Shared C++ modules
#import "CppHello.hpp"
#import "RingBuffer.hpp"
#import "FrameFragmenter.hpp"
#import "FrameAssembler.hpp"
#import "JitterBuffer.hpp"

// Main Mac (Sender) specific
#import "UdpSender.hpp"
#import "SendPipeline.hpp"
#import "VirtualDisplayRuntime.h"

// Secondary Display (Receiver) specific
#import "UdpReceiver.hpp"
#import "ReceivePipeline.hpp"
