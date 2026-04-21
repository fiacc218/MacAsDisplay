// Sender bridging header.
// 启用 Swift-C++ Interop 后,Swift 侧通过这里"看见"C++ 命名空间和类。
// 注:bridging header 的 clang 会以 Obj-C++ 模式处理,可直接 #include .hpp。

#pragma once

// Shared C++ modules
#import "CppHello.hpp"
#import "RingBuffer.hpp"
#import "FrameFragmenter.hpp"
#import "FrameAssembler.hpp"
#import "JitterBuffer.hpp"

// Sender-specific
#import "UdpSender.hpp"
#import "SendPipeline.hpp"
#import "VirtualDisplayRuntime.h"
