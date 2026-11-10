// Stands in for the emulator's logging in gpu_bench_test.cpp: the lines are kept, for the test to read.
#pragma once
#include <string>
#include <vector>

#include <fmt/format.h>

namespace GpuBenchTestLog {
inline std::vector<std::string>& Lines() {
    static std::vector<std::string> lines;
    return lines;
}
} // namespace GpuBenchTestLog

#define LOG_INFO(log_class, ...) ::GpuBenchTestLog::Lines().push_back(fmt::format(__VA_ARGS__))
