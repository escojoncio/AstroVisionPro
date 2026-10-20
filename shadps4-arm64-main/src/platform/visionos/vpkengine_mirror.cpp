#include "vpkengine_mirror.h"

#include <mach/mach.h>
#include <mach/vm_map.h>

#include <chrono>
#include <map>
#include <mutex>
#include <vector>

namespace VpkengineRenderer {
namespace {

using Clock = std::chrono::steady_clock;

struct Mirror {
    uint64_t end = 0;
    uint64_t signature = 0;
    void* base = nullptr;
};

struct Retired {
    void* base;
    uint64_t size;
    Clock::time_point since;
};

struct Failure {
    uint64_t end = 0, signature = 0;
    Clock::time_point at;
};

std::mutex& mutex() {
    static std::mutex& m = *new std::mutex;
    return m;
}
std::map<uint64_t, Mirror>& mirrors() {
    static auto& m = *new std::map<uint64_t, Mirror>;
    return m;
}
std::vector<Retired>& retired() {
    static auto& r = *new std::vector<Retired>;
    return r;
}
std::map<uint64_t, Failure>& failures() {
    static auto& f = *new std::map<uint64_t, Failure>;
    return f;
}

// How long a replaced mirror stays mapped: frames in flight on the GPU may still read it.
constexpr auto kRetireAfter = std::chrono::seconds(10);
// A range the host refused is not asked again for this long (unless its pages changed).
constexpr auto kRetryAfter = std::chrono::seconds(2);

uint64_t mixIn(uint64_t h, uint64_t v) {
    h ^= v + 0x9E3779B97F4A7C15ull + (h << 6) + (h >> 2);
    return h * 0xBF58476D1CE4E5B9ull;
}

// Identifies the pages behind [begin, end): the VM entries' extents, backing objects and offsets.
// A mapping replaced by another one (munmap + mmap, MAP_FIXED) changes it; protection changes
// (the page watches) do not. 0 if the range cannot be walked.
uint64_t signatureOf(uint64_t begin, uint64_t end) {
    uint64_t h = 0xcbf29ce484222325ull;
    vm_address_t at = vm_address_t(begin);
    while (at < end) {
        vm_address_t base = at;
        vm_size_t size = 0;
        natural_t depth = 0;
        vm_region_submap_info_data_64_t info{};
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &base, &size, &depth, reinterpret_cast<vm_region_recurse_info_t>(&info),
                                 &count) != KERN_SUCCESS ||
            base > at || size == 0)
            return 0;
        h = mixIn(h, base);
        h = mixIn(h, size);
        h = mixIn(h, info.object_id);
        h = mixIn(h, info.offset);
        at = base + size;
    }
    return h ? h : 1;
}

void release(const Mirror& m, uint64_t begin) {
    retired().push_back({m.base, m.end - begin, Clock::now()});
}

void reap() {
    const auto now = Clock::now();
    auto& r = retired();
    for (size_t k = 0; k < r.size();) {
        if (now - r[k].since > kRetireAfter) {
            vm_deallocate(mach_task_self(), vm_address_t(r[k].base), vm_size_t(r[k].size));
            r[k] = r.back();
            r.pop_back();
        } else {
            ++k;
        }
    }
}

} // namespace

void* GuestMirror(uint64_t begin, uint64_t end) {
    if (end <= begin || (begin | end) & (vm_page_size - 1)) return nullptr;
    const uint64_t signature = signatureOf(begin, end);
    if (!signature) return nullptr;
    std::scoped_lock l{mutex()};
    reap();
    auto it = mirrors().find(begin);
    if (it != mirrors().end()) {
        if (it->second.end == end && it->second.signature == signature) return it->second.base;
        release(it->second, begin);  // other pages (or another extent) now: a new mirror
        mirrors().erase(it);
    }
    if (auto f = failures().find(begin);
        f != failures().end() && f->second.end == end && f->second.signature == signature &&
        Clock::now() - f->second.at < kRetryAfter)
        return nullptr;
    vm_address_t target = 0;
    vm_prot_t current = 0, maximum = 0;
    const kern_return_t kr = vm_remap(mach_task_self(), &target, vm_size_t(end - begin), 0, VM_FLAGS_ANYWHERE,
                                      mach_task_self(), vm_address_t(begin), FALSE /* share, not copy */, &current,
                                      &maximum, VM_INHERIT_NONE);
    bool ok = kr == KERN_SUCCESS;
    // The mirror is the GPU's way in: it must be writable whatever the guest addresses are right now.
    if (ok && vm_protect(mach_task_self(), target, vm_size_t(end - begin), FALSE, VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS) {
        vm_deallocate(mach_task_self(), target, vm_size_t(end - begin));
        ok = false;
    }
    if (!ok) {
        failures()[begin] = {end, signature, Clock::now()};
        return nullptr;
    }
    failures().erase(begin);
    mirrors()[begin] = {end, signature, reinterpret_cast<void*>(target)};
    return reinterpret_cast<void*>(target);
}

} // namespace VpkengineRenderer
