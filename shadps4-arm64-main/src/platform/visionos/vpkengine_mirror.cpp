#include "vpkengine_mirror.h"

#include <mach/mach.h>
#include <mach/vm_map.h>

#include <atomic>
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
    Clock::time_point staleSince{};  // first lookup that could not confirm / replace it (zero: confirmed)
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

std::atomic<uint64_t> gLookups{0}, gRegionCalls{0};

std::mutex& mutex() {
    static std::mutex& m = *new std::mutex;
    return m;
}
// Keyed by (begin, end): spans that start at the same place but end at another (a window cut at 64 MiB and one widened to
// hold a range that crosses it) coexist, each with its own mirror; one mirror per begin would retire the other's.
using SpanKey = std::pair<uint64_t, uint64_t>;
std::map<SpanKey, Mirror>& mirrors() {
    static auto& m = *new std::map<SpanKey, Mirror>;
    return m;
}
std::vector<Retired>& retired() {
    static auto& r = *new std::vector<Retired>;
    return r;
}
std::map<SpanKey, Failure>& failures() {
    static auto& f = *new std::map<SpanKey, Failure>;
    return f;
}

// How long a replaced mirror stays mapped: frames in flight on the GPU may still read it.
constexpr auto kRetireAfter = std::chrono::seconds(10);
// A range the host refused is not asked again for this long (unless its pages changed).
constexpr auto kRetryAfter = std::chrono::seconds(2);
// A mirror that cannot be confirmed (the VM map cannot be walked, or the pages changed and a new mapping keeps
// being refused) is served this long; then it is dropped from service: the old pages may no longer be the
// guest's, and the caller falls back as it does for a range with no mirror (no aliasing of the guest pages).
constexpr auto kServeStaleFor = std::chrono::seconds(5);

uint64_t mixIn(uint64_t h, uint64_t v) {
    h ^= v + 0x9E3779B97F4A7C15ull + (h << 6) + (h >> 2);
    return h * 0xBF58476D1CE4E5B9ull;
}

// Identifies the pages behind [begin, end): the backing object of each run of the range and the
// object offset the range's first byte would have (offset - position), so that the same pages mapped
// at the same layout give the same signature however the VM map cut them into entries. Page
// protection changes (the page watches: a partial mprotect splits an entry, which changes its base
// and size) must not change it, or every watch would make a new vm_remap and a new no-copy buffer.
// A mapping replaced by another one (munmap + mmap, MAP_FIXED) changes the object or the offset.
// 0 if the range cannot be walked.
uint64_t signatureOf(uint64_t begin, uint64_t end) {
    uint64_t h = 0xcbf29ce484222325ull;
    vm_address_t at = vm_address_t(begin);
    bool have = false;
    uint64_t lastObject = 0, lastShift = 0;
    while (at < end) {
        vm_address_t base = at;
        vm_size_t size = 0;
        natural_t depth = 0;
        vm_region_submap_info_data_64_t info{};
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        gRegionCalls.fetch_add(1, std::memory_order_relaxed);
        if (vm_region_recurse_64(mach_task_self(), &base, &size, &depth, reinterpret_cast<vm_region_recurse_info_t>(&info),
                                 &count) != KERN_SUCCESS ||
            base > at || size == 0)
            return 0;
        // (the object offset of the range's first byte, wrapping: it only has to be equal for equal layouts)
        const uint64_t shift = uint64_t(info.offset) - (uint64_t(base) - begin);
        const uint64_t object = info.object_id;
        if (!have || object != lastObject || shift != lastShift) {
            h = mixIn(h, object);
            h = mixIn(h, shift);
            have = true;
            lastObject = object, lastShift = shift;
        }
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
    gLookups.fetch_add(1, std::memory_order_relaxed);
    const uint64_t signature = signatureOf(begin, end);
    std::scoped_lock l{mutex()};
    reap();
    auto it = mirrors().find({begin, end});
    // A transient failure (the VM map could not be walked, vm_remap refused once) keeps the mirror
    // this span had: the caller must not fall back to the guest addresses, which may be page-protected
    // by now. The old pages are the right ones unless the mapping was replaced, which the next
    // successful lookup finds out.
    const auto previous = [&]() -> void* {
        if (it == mirrors().end()) return nullptr;
        Mirror& m = it->second;
        const auto now = Clock::now();
        if (m.staleSince == Clock::time_point{}) m.staleSince = now;
        return now - m.staleSince < kServeStaleFor ? m.base : nullptr;
    };
    if (!signature) return previous();
    if (it != mirrors().end()) {
        if (it->second.signature == signature) {
            it->second.staleSince = {};
            return it->second.base;
        }
    }
    if (auto f = failures().find({begin, end});
        f != failures().end() && f->second.signature == signature && Clock::now() - f->second.at < kRetryAfter)
        return previous();
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
        failures()[{begin, end}] = {end, signature, Clock::now()};
        return previous();
    }
    failures().erase(SpanKey{begin, end});
    if (it != mirrors().end()) {
        release(it->second, begin);  // other pages now: the old mirror retires
        mirrors().erase(it);
    }
    // Spans keyed apart that overlap this one and whose pages changed (or can no longer be walked) would otherwise
    // stay mapped for good: nothing asks for them again.
    for (auto o = mirrors().begin(); o != mirrors().end();) {
        const bool overlaps = o->first.first < end && begin < o->first.second;
        if (overlaps && o->first != SpanKey{begin, end}) {
            const uint64_t now = signatureOf(o->first.first, o->first.second);
            if (now == 0 || now != o->second.signature) {
                release(o->second, o->first.first);
                o = mirrors().erase(o);
                continue;
            }
        }
        ++o;
    }
    mirrors()[{begin, end}] = {end, signature, reinterpret_cast<void*>(target)};
    return reinterpret_cast<void*>(target);
}

GuestMirrorStats TakeGuestMirrorStats() {
    return {gLookups.exchange(0, std::memory_order_relaxed), gRegionCalls.exchange(0, std::memory_order_relaxed)};
}

} // namespace VpkengineRenderer
