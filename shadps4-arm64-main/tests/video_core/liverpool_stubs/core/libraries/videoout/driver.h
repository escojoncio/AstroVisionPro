#pragma once
#include <mutex>
#include <functional>
#include "common/types.h"
namespace Libraries::VideoOut {
struct FlipLabels { void RecordGpuLock(int) {} };
struct VideoOutPort { std::mutex port_mutex; FlipLabels flip_labels; bool IsVoLabel(const void*) const { return false; } int LabelIndex(const void*) const { return 0; } void WaitVoLabel(std::function<bool()>) {} };
}
#include <boost/container/small_vector.hpp>
