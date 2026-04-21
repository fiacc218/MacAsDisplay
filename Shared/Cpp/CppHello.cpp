#include "CppHello.hpp"

namespace vs {

const char* cpp_hello() noexcept {
#if defined(__clang__)
    return "Hello from C++" " (clang " __clang_version__ ")";
#elif defined(__GNUC__)
    return "Hello from C++ (gcc)";
#else
    return "Hello from C++";
#endif
}

}  // namespace vs
