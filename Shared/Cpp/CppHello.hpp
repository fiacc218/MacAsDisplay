// Swift-C++ Interop 自检用 demo。
// 仅依赖标准库,返回一个 C 字符串(避开 std::string 的 bridging 不确定性)。
#pragma once

namespace vs {

/// 返回一段描述性问候 —— 进程静态存储期,调用方不得释放。
/// Swift 里这么调:
///     if let p = vs.cpp_hello() {
///         Log.app.info("\(String(cString: p))")
///     }
const char* cpp_hello() noexcept;

}  // namespace vs
