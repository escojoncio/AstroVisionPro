// Stands in for fmt in gpu_bench_test.cpp (std::format takes the same strings).
#pragma once
#include <format>
#include <string>

namespace fmt {
template <class... A>
std::string format(std::format_string<A...> f, A&&... a) {
    return std::vformat(f.get(), std::make_format_args(a...));
}
} // namespace fmt
