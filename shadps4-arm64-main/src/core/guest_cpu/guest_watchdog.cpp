// SPDX-License-Identifier: MIT

#include "guest_watchdog.h"

#include <atomic>
#include <cstdlib>
#include <vector>
#include <string>
#include <algorithm>
#include <condition_variable>
#include <filesystem>
#include <mutex>
#include <thread>
#include <unordered_map>

#include "common/logging/log.h"
#include "common/path_util.h"
#include "common/thread.h"
#include "common/jit_arena.h"
#include "core/address_space.h"

#if defined(__linux__) && defined(__aarch64__)
#define WATCHDOG_NATIVE_STACKS 1
#include <csignal>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <dlfcn.h>
#include <link.h>
#include <semaphore.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <ucontext.h>
#include <unistd.h>
#elif defined(__APPLE__) && defined(__aarch64__)
#define WATCHDOG_MACH_STACKS 1
#include <cstring>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <cstddef>
#include <malloc/malloc.h>
#include <map>
#include <set>
#include <tuple>
#include <mach/mach.h>
#include <pthread.h>
#if defined(SHADPS4_VISIONOS)
#include <os/proc.h>
#endif
#endif

namespace Vulkan {
/// What the Vulkan driver says the device's memory holds (vk_instance.cpp), 0 if not known.
u64 DeviceMemoryUsageForReports();
} // namespace Vulkan

namespace VideoCore {
/// What the emulator's buffers and images hold (buffer_cache/buffer.cpp).
std::string DescribeGpuAllocations();
} // namespace VideoCore

namespace Core::GuestCpu {

namespace {

using Clock = std::chrono::steady_clock;

constexpr auto StallTime = std::chrono::seconds{20};

std::atomic<Clock::rep> last_progress{};
std::once_flag start_flag;

std::mutex frame_mutex;
std::condition_variable frame_signal;
u64 frame_count{};

#ifdef WATCHDOG_NATIVE_STACKS
// Where every thread of the emulator is, guest or not: each one is interrupted with a signal and
// walks its own frame pointers. Addresses inside the emulator are printed relative to where it
// is loaded, ready for a symbolizer: llvm-symbolizer -e shadps4 0x...
constexpr int MaxFrames = 20;

struct StackSample {
    uintptr_t frames[MaxFrames];
    int count;
};

StackSample sample;
sem_t sample_done;
int sample_pipe[2] = {-1, -1};
int sample_signal = 0;
uintptr_t image_begin = 0;
uintptr_t image_end = 0;

/// Reads two words that may not be mapped. The kernel does the copy, so a bad frame pointer,
/// which is what generated code leaves behind, is an error and not a fault.
bool ReadFrame(uintptr_t address, uintptr_t out[2]) {
    if (write(sample_pipe[1], reinterpret_cast<const void*>(address), 2 * sizeof(uintptr_t)) !=
        static_cast<ssize_t>(2 * sizeof(uintptr_t))) {
        return false;
    }
    return read(sample_pipe[0], out, 2 * sizeof(uintptr_t)) ==
           static_cast<ssize_t>(2 * sizeof(uintptr_t));
}

void SampleHandler(int, siginfo_t*, void* raw_context) {
    const int saved_errno = errno;
    const auto* context = static_cast<const ucontext_t*>(raw_context);
    uintptr_t frame = context->uc_mcontext.regs[29];
    const uintptr_t stack = context->uc_mcontext.sp;
    sample.count = 0;
    sample.frames[sample.count++] = context->uc_mcontext.pc;
    sample.frames[sample.count++] = context->uc_mcontext.regs[30];
    while (sample.count < MaxFrames && (frame & 15) == 0 && frame >= stack &&
           frame - stack < (64u << 20)) {
        uintptr_t record[2];
        if (!ReadFrame(frame, record)) {
            break;
        }
        sample.frames[sample.count++] = record[1];
        if (record[0] <= frame) {
            break;
        }
        frame = record[0];
    }
    sem_post(&sample_done);
    errno = saved_errno;
}

bool SetupSampling() {
    static bool ready = false;
    static bool attempted = false;
    if (attempted) {
        return ready;
    }
    attempted = true;

    dl_iterate_phdr(
        [](dl_phdr_info* info, size_t, void*) {
            // The first entry is the program itself.
            for (int i = 0; i < info->dlpi_phnum; ++i) {
                const auto& header = info->dlpi_phdr[i];
                if (header.p_type != PT_LOAD) {
                    continue;
                }
                const uintptr_t begin = info->dlpi_addr + header.p_vaddr;
                image_begin = image_begin == 0 ? info->dlpi_addr : image_begin;
                image_end = std::max(image_end, begin + header.p_memsz);
            }
            return 1;
        },
        nullptr);

    sample_signal = SIGRTMIN + 9;
    struct sigaction action {};
    action.sa_sigaction = SampleHandler;
    action.sa_flags = SA_SIGINFO | SA_RESTART;
    sigemptyset(&action.sa_mask);
    ready = pipe(sample_pipe) == 0 && sem_init(&sample_done, 0, 0) == 0 &&
            sigaction(sample_signal, &action, nullptr) == 0;
    return ready;
}

std::string DescribeNativeThreads(const char* only = "") {
    if (!SetupSampling()) {
        return {};
    }
    std::string text;
    const int pid = getpid();
    const int self = static_cast<int>(syscall(SYS_gettid));
    DIR* tasks = opendir("/proc/self/task");
    if (tasks == nullptr) {
        return {};
    }
    while (const dirent* entry = readdir(tasks)) {
        const int tid = std::atoi(entry->d_name);
        if (tid <= 0 || tid == self) {
            continue;
        }
        char path[64];
        char name[32] = "?";
        std::snprintf(path, sizeof(path), "/proc/self/task/%d/comm", tid);
        if (std::FILE* file = std::fopen(path, "r")) {
            if (std::fgets(name, sizeof(name), file) != nullptr) {
                name[std::strcspn(name, "\n")] = '\0';
            }
            std::fclose(file);
        }
        if (std::strncmp(name, only, std::strlen(only)) != 0) {
            continue;
        }

        // A thread that answered after its time was up must not be taken for this one.
        while (sem_trywait(&sample_done) == 0) {
        }
        if (syscall(SYS_tgkill, pid, tid, sample_signal) != 0) {
            continue;
        }
        timespec deadline{};
        clock_gettime(CLOCK_REALTIME, &deadline);
        deadline.tv_nsec += 200'000'000;
        if (deadline.tv_nsec >= 1'000'000'000) {
            deadline.tv_nsec -= 1'000'000'000;
            ++deadline.tv_sec;
        }
        if (sem_timedwait(&sample_done, &deadline) != 0) {
            text += fmt::format("  {:<16} tid {}: did not answer\n", name, tid);
            continue;
        }
        text += fmt::format("  {:<16} tid {}:", name, tid);
        for (int i = 0; i < sample.count; ++i) {
            const uintptr_t address = sample.frames[i];
            if (address >= image_begin && address < image_end) {
                text += fmt::format(" {:#x}", address - image_begin);
            } else if (Dl_info info{}; dladdr(reinterpret_cast<void*>(address), &info) != 0 &&
                                         info.dli_fname != nullptr) {
                // A library: its name and the offset into it, and the function if it is exported.
                const char* file = std::strrchr(info.dli_fname, 0x2f);
                text += fmt::format(" [{}+{:#x}{}{}]", file != nullptr ? file + 1 : info.dli_fname,
                                    address - reinterpret_cast<uintptr_t>(info.dli_fbase),
                                    info.dli_sname != nullptr ? " " : "",
                                    info.dli_sname != nullptr ? info.dli_sname : "");
            } else {
                text += fmt::format(" [{:#x}]", address);
            }
        }
        text += '\n';
    }
    closedir(tasks);
    return text;
}
#elif defined(WATCHDOG_MACH_STACKS)
// Apple has no /proc and no signal for one thread of one's own: Mach stops each thread, reads
// its registers and lets it go on. Nothing is allocated while a thread is stopped (it may hold
// the allocator's lock), the frames are only formatted afterwards. Addresses inside the app are
// printed relative to its Mach-O header, ready for: atos -o <app binary> -l 0x100000000 0x...
std::string DescribeNativeThreads(const char* only = "") {
    constexpr int MaxFrames = 20;
    const auto* main_header = _dyld_get_image_header(0);
    thread_act_array_t threads = nullptr;
    mach_msg_type_number_t thread_count = 0;
    if (task_threads(mach_task_self(), &threads, &thread_count) != KERN_SUCCESS) {
        return {};
    }
    const thread_act_t self = mach_thread_self();
    std::string text;
    for (mach_msg_type_number_t t = 0; t < thread_count; ++t) {
        const thread_act_t thread = threads[t];
        if (thread == self) {
            continue;
        }
        thread_extended_info_data_t info{};
        mach_msg_type_number_t info_count = THREAD_EXTENDED_INFO_COUNT;
        char name[64] = "?";
        if (thread_info(thread, THREAD_EXTENDED_INFO, reinterpret_cast<thread_info_t>(&info),
                        &info_count) == KERN_SUCCESS &&
            info.pth_name[0] != '\0') {
            std::strncpy(name, info.pth_name, sizeof(name) - 1);
        }
        if (std::strncmp(name, only, std::strlen(only)) != 0) {
            continue;
        }

        uintptr_t frames[MaxFrames];
        int count = 0;
        if (thread_suspend(thread) != KERN_SUCCESS) {
            continue;
        }
        arm_thread_state64_t state{};
        mach_msg_type_number_t state_count = ARM_THREAD_STATE64_COUNT;
        if (thread_get_state(thread, ARM_THREAD_STATE64, reinterpret_cast<thread_state_t>(&state),
                             &state_count) == KERN_SUCCESS) {
            frames[count++] = static_cast<uintptr_t>(arm_thread_state64_get_pc(state));
            frames[count++] = static_cast<uintptr_t>(arm_thread_state64_get_lr(state));
            uintptr_t frame = static_cast<uintptr_t>(arm_thread_state64_get_fp(state));
            const uintptr_t stack = static_cast<uintptr_t>(arm_thread_state64_get_sp(state));
            while (count < MaxFrames && (frame & 15) == 0 && frame >= stack &&
                   frame - stack < (64u << 20)) {
                uintptr_t record[2];
                vm_size_t read = 0;
                // The kernel does the copy: a frame pointer that leads nowhere is an error.
                if (vm_read_overwrite(mach_task_self(), frame, sizeof(record),
                                      reinterpret_cast<vm_address_t>(record),
                                      &read) != KERN_SUCCESS ||
                    read != sizeof(record)) {
                    break;
                }
                frames[count++] = record[1];
                if (record[0] <= frame) {
                    break;
                }
                frame = record[0];
            }
        }
        thread_resume(thread);

        text += fmt::format("  {:<20} state {}:", name, info.pth_run_state);
        for (int i = 0; i < count; ++i) {
            uintptr_t address = frames[i];
            Dl_info where{};
            if (dladdr(reinterpret_cast<void*>(address), &where) == 0 &&
                (address >> 40) != 0) {
                // A return address signed by pointer authentication: the signature sits in the
                // bits above the address.
                address &= 0x0000'00ff'ffff'ffffull;
                where = {};
                dladdr(reinterpret_cast<void*>(address), &where);
            }
            if (where.dli_fbase != nullptr &&
                where.dli_fbase == main_header) {
                text += fmt::format(" {:#x}",
                                    address - reinterpret_cast<uintptr_t>(main_header) +
                                        0x1'0000'0000ull);
            } else if (where.dli_fname != nullptr && where.dli_fbase != nullptr) {
                const char* file = std::strrchr(where.dli_fname, 0x2f);
                text += fmt::format(" [{}+{:#x}{}{}]", file != nullptr ? file + 1 : where.dli_fname,
                                    address - reinterpret_cast<uintptr_t>(where.dli_fbase),
                                    where.dli_sname != nullptr ? " " : "",
                                    where.dli_sname != nullptr ? where.dli_sname : "");
            } else {
                text += fmt::format(" [{:#x}]", address);
            }
        }
        text += '\n';
    }
    for (mach_msg_type_number_t t = 0; t < thread_count; ++t) {
        mach_port_deallocate(mach_task_self(), threads[t]);
    }
    mach_port_deallocate(mach_task_self(), self);
    vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(threads),
                  thread_count * sizeof(thread_act_t));
    return text;
}
#else
std::string DescribeNativeThreads(const char* = "") {
    return {};
}
#endif

#ifdef WATCHDOG_MACH_STACKS
// Where the processor's time goes, thread by thread, between two calls: what tells a slow
// stretch that waits on the GPU (no thread busy) from one that waits on the guest's code (its
// threads busy) or on the emulator's own work for the GPU (the command processor busy).
struct CpuUse {
    std::string name;
    double percent;
};

std::vector<CpuUse> MeasureCpuUse(double seconds) {
    static std::unordered_map<u64, u64> previous_us;
    std::unordered_map<u64, u64> current_us;
    std::vector<CpuUse> use;
    thread_act_array_t threads = nullptr;
    mach_msg_type_number_t thread_count = 0;
    if (task_threads(mach_task_self(), &threads, &thread_count) != KERN_SUCCESS) {
        return use;
    }
    for (mach_msg_type_number_t t = 0; t < thread_count; ++t) {
        const thread_act_t thread = threads[t];
        thread_identifier_info_data_t id{};
        mach_msg_type_number_t id_count = THREAD_IDENTIFIER_INFO_COUNT;
        thread_basic_info_data_t basic{};
        mach_msg_type_number_t basic_count = THREAD_BASIC_INFO_COUNT;
        if (thread_info(thread, THREAD_IDENTIFIER_INFO, reinterpret_cast<thread_info_t>(&id),
                        &id_count) != KERN_SUCCESS ||
            thread_info(thread, THREAD_BASIC_INFO, reinterpret_cast<thread_info_t>(&basic),
                        &basic_count) != KERN_SUCCESS) {
            continue;
        }
        const u64 us = u64(basic.user_time.seconds + basic.system_time.seconds) * 1'000'000 +
                       u64(basic.user_time.microseconds + basic.system_time.microseconds);
        current_us[id.thread_id] = us;
        const auto before = previous_us.find(id.thread_id);
        if (before == previous_us.end() || us <= before->second || seconds <= 0.0) {
            continue;
        }
        const double percent = double(us - before->second) / (seconds * 10'000.0);
        if (percent < 3.0) {
            continue;
        }
        thread_extended_info_data_t info{};
        mach_msg_type_number_t info_count = THREAD_EXTENDED_INFO_COUNT;
        std::string name = "?";
        if (thread_info(thread, THREAD_EXTENDED_INFO, reinterpret_cast<thread_info_t>(&info),
                        &info_count) == KERN_SUCCESS &&
            info.pth_name[0] != '\0') {
            name = info.pth_name;
        }
        use.push_back({std::move(name), percent});
    }
    for (mach_msg_type_number_t t = 0; t < thread_count; ++t) {
        mach_port_deallocate(mach_task_self(), threads[t]);
    }
    vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(threads),
                  thread_count * sizeof(thread_act_t));
    previous_us = std::move(current_us);
    std::ranges::sort(use, [](const CpuUse& a, const CpuUse& b) { return a.percent > b.percent; });
    return use;
}

/// What a region's tag (the kind of memory the system says it is) is called in the MEMORY line.
std::string MemoryTagName(unsigned tag) {
    switch (tag) {
    case 0:
        return "untagged";
    case 1:
    case 2:
    case 3:
    case 4:
    case 6:
    case 7:
    case 8:
    case 9:
    case 11:
    case 12:
    case 13:
        return "malloc";
    case 21:
        return "IOKit";
    case 30:
        return "stacks";
    case 33:
        return "libraries";
    case 60:
    case 61:
        return "dyld";
    case 74:
        return "libdispatch";
    case 88:
        return "IOSurface";
    case 90:
        return "audio";
    case 100:
        return "IOAccelerator";
    case 107:
        return "CompositorServices";
    default:
        return fmt::format("tag {}", tag);
    }
}

/// The memory object a mapped address belongs to (0 if none). The short form of the region's
/// description: the full one has the system count the region's pages one by one.
u32 MemoryObjectAt(u64 address) {
    if (address == 0) {
        return 0;
    }
    vm_address_t region = static_cast<vm_address_t>(address);
    vm_size_t size = 0;
    natural_t depth = 0;
    vm_region_submap_short_info_data_64_t info{};
    mach_msg_type_number_t count = VM_REGION_SUBMAP_SHORT_INFO_COUNT_64;
    if (vm_region_recurse_64(mach_task_self(), &region, &size, &depth,
                             reinterpret_cast<vm_region_recurse_info_t>(&info),
                             &count) != KERN_SUCCESS ||
        region > address || info.is_submap) {
        return 0;
    }
    return info.object_id;
}

/// Where the process's memory is, by kind: the system's own accounting (internal, compressed,
/// graphics) and a walk over every mapped region, adding up its dirty and compressed pages by
/// what it is (the console's memory, the code arena, malloc, the GPU's...). Each memory object is
/// counted once, however many times it is mapped. The six biggest regions that are none of the
/// first two are listed with their address and tag.
std::string DescribeMemory(const task_vm_info_data_t& vm, mach_msg_type_number_t vm_count) {
    const u64 page = static_cast<u64>(vm_page_size);
    std::string text = fmt::format("footprint {} MB: internal {}, compressed {}",
                                   vm.phys_footprint >> 20, vm.internal >> 20,
                                   vm.compressed >> 20);
    if (u64(vm_count) * sizeof(natural_t) >=
        offsetof(task_vm_info_data_t, ledger_tag_graphics_footprint_compressed) +
            sizeof(vm.ledger_tag_graphics_footprint_compressed)) {
        text += fmt::format(", graphics {} (+{} compressed), purgeable kept {}",
                            vm.ledger_tag_graphics_footprint >> 20,
                            vm.ledger_tag_graphics_footprint_compressed >> 20,
                            vm.ledger_purgeable_nonvolatile >> 20);
    }

    const auto [console_base, console_size] = Core::ConsoleMemoryRange();
    const auto arena = Common::JitArena::GetUsage();
    // Neither moves once it exists.
    static u32 console_object = 0;
    static u32 arena_object = 0;
    if (console_object == 0 && console_size != 0) {
        console_object = MemoryObjectAt(console_base);
    }
    if (arena_object == 0 && arena.size != 0) {
        arena_object = MemoryObjectAt(arena.begin);
    }
    const auto walk_start = std::chrono::steady_clock::now();

    struct Kind {
        u64 dirty{};
        u64 compressed{};
    };
    struct Region {
        u64 address;
        u64 size;
        u64 dirty;
        u64 compressed;
        unsigned tag;
        unsigned share;
    };
    std::map<std::string, Kind> kinds;
    std::vector<Region> biggest;
    std::set<std::tuple<u64, u64, u64>> seen;
    vm_address_t address = 0;
    u32 regions = 0;
    for (; regions < 500000; ++regions) {
        // First the short description (no page counts), to pass over what is not counted
        // without the system counting its pages; then the full one at the same address.
        vm_size_t size = 0;
        natural_t depth = 0;
        vm_region_submap_short_info_data_64_t brief{};
        mach_msg_type_number_t brief_count = VM_REGION_SUBMAP_SHORT_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &address, &size, &depth,
                                 reinterpret_cast<vm_region_recurse_info_t>(&brief),
                                 &brief_count) != KERN_SUCCESS ||
            size == 0) {
            break;
        }
        const u64 begin = address;
        address += size;
        if (brief.is_submap) {
            // The system's shared libraries: clean but for a little.
            continue;
        }
        std::string name;
        if (console_object != 0 && brief.object_id == console_object) {
            if (begin < console_base || begin >= console_base + console_size) {
                continue; // The guest's own mappings of the same memory.
            }
            name = "console memory";
        } else if (arena_object != 0 && brief.object_id == arena_object) {
            if (begin < arena.begin || begin >= arena.begin + arena.size) {
                continue; // The writable mapping of the same pages.
            }
            name = "code arena";
        }
        vm_address_t again = static_cast<vm_address_t>(begin);
        vm_size_t again_size = 0;
        natural_t again_depth = 0;
        vm_region_submap_info_data_64_t info{};
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &again, &again_size, &again_depth,
                                 reinterpret_cast<vm_region_recurse_info_t>(&info),
                                 &count) != KERN_SUCCESS ||
            again != begin || info.is_submap) {
            continue; // Changed in between.
        }
        const u64 dirty = u64(info.pages_dirtied) * page;
        const u64 compressed = u64(info.pages_swapped_out) * page;
        if (dirty + compressed == 0) {
            continue;
        }
        if (name.empty()) {
            const bool shared = info.share_mode == SM_SHARED ||
                                info.share_mode == SM_TRUESHARED ||
                                info.share_mode == SM_SHARED_ALIASED ||
                                info.share_mode == SM_PRIVATE_ALIASED;
            const u64 object = info.object_id_full != 0 ? u64(info.object_id_full)
                                                        : u64(info.object_id);
            if (shared && object != 0 &&
                !seen.emplace(object, u64(info.offset), u64(again_size)).second) {
                continue;
            }
            name = MemoryTagName(info.user_tag);
            biggest.push_back({begin, u64(size), dirty, compressed, info.user_tag,
                               static_cast<unsigned>(info.share_mode)});
            std::ranges::sort(biggest, [](const Region& a, const Region& b) {
                return a.dirty + a.compressed > b.dirty + b.compressed;
            });
            if (biggest.size() > 6) {
                biggest.pop_back();
            }
        }
        Kind& kind = kinds[name];
        kind.dirty += dirty;
        kind.compressed += compressed;
    }

    std::vector<std::pair<std::string, Kind>> sorted(kinds.begin(), kinds.end());
    std::ranges::sort(sorted, [](const auto& a, const auto& b) {
        return a.second.dirty + a.second.compressed > b.second.dirty + b.second.compressed;
    });
    const auto walk_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                             std::chrono::steady_clock::now() - walk_start)
                             .count();
    text += fmt::format("; in {} regions, walked in {} ms (MB dirty+compressed):", regions,
                        walk_ms);
    for (size_t i = 0; i < sorted.size() && i < 12; ++i) {
        const auto& [name, kind] = sorted[i];
        if ((kind.dirty + kind.compressed) >> 20 == 0) {
            break;
        }
        text += fmt::format("{} {} {}+{}", i == 0 ? "" : ",", name, kind.dirty >> 20,
                            kind.compressed >> 20);
    }
    malloc_statistics_t heap{};
    malloc_zone_statistics(nullptr, &heap);
    text += fmt::format("; malloc in use {} MB of {} MB", heap.size_in_use >> 20,
                        heap.size_allocated >> 20);
    if (arena.size != 0) {
        text += fmt::format("; code arena used {} MB, most {} MB, of {} MB", arena.used >> 20,
                            arena.most >> 20, arena.size >> 20);
    }
    text += "; biggest:";
    for (size_t i = 0; i < biggest.size(); ++i) {
        const Region& region = biggest[i];
        text += fmt::format("{} {:#x} {} MB {} ({}+{}, share {})", i == 0 ? "" : ",",
                            region.address, region.size >> 20, MemoryTagName(region.tag),
                            region.dirty >> 20, region.compressed >> 20, region.share);
    }
    return text;
}

/// Every 5 s: the guest's frame rate and the busiest threads. A stretch below 10 frames a second
/// also gets a few samples of the busiest thread's native stack (a few times a session), so
/// that the log says where that thread spends its time.
void ReportPace(Clock::time_point now) {
    static Clock::time_point last_time{};
    static u64 last_frames{};
    static u32 profiles_taken{};
    static Clock::time_point last_profile{};
    const u64 frames = GuestFrameCount();
    if (last_time == Clock::time_point{}) {
        last_time = now;
        last_frames = frames;
        MeasureCpuUse(0.0);
        return;
    }
    const double seconds = std::chrono::duration<double>(now - last_time).count();
    const double fps = double(frames - last_frames) / seconds;
    last_time = now;
    last_frames = frames;
    const auto use = MeasureCpuUse(seconds);
    std::string text;
    double total = 0.0;
    for (const auto& thread : use) {
        total += thread.percent;
    }
    for (size_t i = 0; i < use.size() && i < 8; ++i) {
        text += fmt::format("{}{} {:.0f}%", i == 0 ? "" : ", ", use[i].name, use[i].percent);
    }
    // The memory the system counts against the process, and (on the headset) how much more it
    // allows before it ends the process without a word: what a game that disappears ran out of.
    std::string memory;
    task_vm_info_data_t vm_info{};
    mach_msg_type_number_t vm_count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&vm_info),
                  &vm_count) != KERN_SUCCESS) {
        vm_count = 0;
    } else {
        memory = fmt::format("; memory {} MB", vm_info.phys_footprint >> 20);
#if defined(SHADPS4_VISIONOS)
        memory += fmt::format(", {} MB left; the console's memory in RAM {} MB; the GPU's "
                              "memory {} MB",
                              u64(os_proc_available_memory()) >> 20,
                              Core::ResidentConsoleMemory() >> 20,
                              Vulkan::DeviceMemoryUsageForReports() >> 20);
        memory += "; " + VideoCore::DescribeGpuAllocations();
#endif
    }
    LOG_INFO(Core, "PACE: {:.1f} guest frames/s; CPU {:.0f}% in all: {}{}", fps, total, text,
             memory);
    // Every 2 minutes, and whenever the footprint grew by more than 512 MB since the last one
    // (at most every 30 s): where the memory is. The walk over the regions takes about a
    // quarter of a second with the game's ~70 000 of them.
    static Clock::time_point last_breakdown{};
    static u64 last_breakdown_footprint{};
    if (vm_count != 0 && vm_info.phys_footprint != 0) {
        const auto since = now - last_breakdown;
        const bool grew = vm_info.phys_footprint > last_breakdown_footprint + (512ull << 20);
        if (last_breakdown == Clock::time_point{} || since >= std::chrono::seconds{120} ||
            (grew && since >= std::chrono::seconds{30})) {
            last_breakdown = now;
            last_breakdown_footprint = vm_info.phys_footprint;
            LOG_INFO(Core, "MEMORY: {}", DescribeMemory(vm_info, vm_count));
        }
    }
    if (fps < 10.0 && fps > 0.0 && !use.empty() && profiles_taken < 6 &&
        now - last_profile > std::chrono::seconds{20}) {
        ++profiles_taken;
        last_profile = now;
        // The two busiest threads, a dozen samples each.
        for (size_t i = 0; i < use.size() && i < 2; ++i) {
            for (int sample = 0; sample < 12; ++sample) {
                const auto stack = DescribeNativeThreads(use[i].name.c_str());
                if (stack.empty()) {
                    break;
                }
                LOG_INFO(Core, "PACE_SAMPLE {} {}:\n{}", use[i].name, sample, stack);
                std::this_thread::sleep_for(std::chrono::microseconds{7300 + sample * 530});
            }
        }
    }
}
#else
void ReportPace(Clock::time_point) {}
#endif

#ifdef WATCHDOG_NATIVE_STACKS
/// SHADPS4_THREAD_NICE="<name>=<nice>,<name>=<nice>..." gives the threads whose names begin with
/// <name> that scheduling priority (lower is more urgent). On a device with fewer processor
/// cores than the emulator has busy threads, that decides which of them wait: the thread the
/// sound comes from and the two a frame passes through should not be the ones.
void ApplyThreadPriorities() {
    struct Rule {
        std::string prefix;
        int nice;
    };
    static const std::vector<Rule> rules = [] {
        std::vector<Rule> parsed;
        const char* setting = std::getenv("SHADPS4_THREAD_NICE");
        std::string text = setting != nullptr ? setting : "";
        size_t begin = 0;
        while (begin < text.size()) {
            const size_t end = std::min(text.find(',', begin), text.size());
            const std::string entry = text.substr(begin, end - begin);
            const size_t equals = entry.rfind('=');
            if (equals != std::string::npos && equals > 0) {
                parsed.push_back({entry.substr(0, equals), std::atoi(entry.c_str() + equals + 1)});
            }
            begin = end + 1;
        }
        return parsed;
    }();
    static std::vector<int> seen;
    static std::vector<std::pair<int, std::string>> named;
    if (rules.empty()) {
        return;
    }
    DIR* tasks = opendir("/proc/self/task");
    if (tasks == nullptr) {
        return;
    }
    while (const dirent* entry = readdir(tasks)) {
        const int tid = std::atoi(entry->d_name);
        if (tid <= 0 || std::find(seen.begin(), seen.end(), tid) != seen.end()) {
            continue;
        }
        char path[64];
        char name[32] = "";
        std::snprintf(path, sizeof(path), "/proc/self/task/%d/comm", tid);
        if (std::FILE* file = std::fopen(path, "r")) {
            if (std::fgets(name, sizeof(name), file) != nullptr) {
                name[std::strcspn(name, "\n")] = 0;
            }
            std::fclose(file);
        }
        // A thread starts out with the name of the one that created it and is given its own a
        // moment later: only a name that is still the same on the next round counts.
        const auto earlier = std::find_if(named.begin(), named.end(),
                                          [tid](const auto& entry) { return entry.first == tid; });
        if (earlier == named.end()) {
            named.emplace_back(tid, name);
            continue;
        }
        if (earlier->second != name) {
            earlier->second = name;
            continue;
        }
        named.erase(earlier);
        seen.push_back(tid);
        for (const Rule& rule : rules) {
            if (std::strncmp(name, rule.prefix.c_str(), rule.prefix.size()) != 0) {
                continue;
            }
            const int result = setpriority(PRIO_PROCESS, static_cast<id_t>(tid), rule.nice);
            LOG_INFO(Core, "thread {} ({}): priority {}{}", name, tid, rule.nice,
                     result == 0 ? "" : " refused");
            break;
        }
    }
    closedir(tasks);
}
#else
void ApplyThreadPriorities() {}
#endif

void Watch() {
    Common::SetCurrentThreadName("shadPS4:Watchdog");
    const auto request =
        Common::FS::GetUserPath(Common::FS::PathType::UserDir) / "dump_threads";
    bool stall_reported = false;
    u32 round = 0;
    while (true) {
        std::this_thread::sleep_for(std::chrono::milliseconds{250});
        if (round % 8 == 0) {
            ApplyThreadPriorities();
        }
        if (round % 20 == 0) {
            ReportPace(Clock::now());
        }
        ++round;

        const auto idle = Clock::now().time_since_epoch() - Clock::duration{last_progress.load()};
        const bool stalled = idle > StallTime;
        std::error_code ec;
        const bool requested = std::filesystem::exists(request, ec);
        if (!requested && (!stalled || stall_reported)) {
            stall_reported = stall_reported && stalled;
            continue;
        }
        stall_reported = stalled;

        const auto threads = DescribeGuestThreads();
        LOG_WARNING(Core, "{} s since the guest's last frame. Guest threads:\n{}",
                    std::chrono::duration_cast<std::chrono::seconds>(idle).count(),
                    threads.empty() ? "(not tracked on this CPU backend)" : threads);
        // A request file that holds a number asks for that many samples of every thread's
        // native stack, which is what tells where the emulator itself waits or works. A name
        // after the number limits them to the threads whose names begin with it: sampling one
        // thread is quick enough to do a few hundred times, which makes a profile of it.
        int samples = stalled ? 1 : 0;
        char only[32] = "";
        if (requested) {
            if (std::FILE* file = std::fopen(request.string().c_str(), "r")) {
                if (std::fscanf(file, "%d %31s", &samples, only) < 1) {
                    samples = 1;
                }
                std::fclose(file);
            }
            std::filesystem::remove(request, ec);
        }
        for (int i = 0; i < samples; ++i) {
            const auto native = DescribeNativeThreads(only);
            if (native.empty()) {
                break;
            }
            LOG_WARNING(Core, "Native stacks, sample {}:\n{}", i, native);
            // Not a multiple of anything a frame is made of.
            std::this_thread::sleep_for(
                std::chrono::microseconds{only[0] != 0 ? 5300 + (i % 7) * 410 : 37000});
        }
    }
}

} // namespace

void NoteGuestProgress() noexcept {
    last_progress.store(Clock::now().time_since_epoch().count(), std::memory_order_relaxed);
    {
        std::scoped_lock lock{frame_mutex};
        ++frame_count;
    }
    frame_signal.notify_all();
    std::call_once(start_flag, [] { std::thread{Watch}.detach(); });
}

u64 GuestFrameCount() noexcept {
    std::scoped_lock lock{frame_mutex};
    return frame_count;
}

u64 WaitForGuestFrame(u64 count, std::chrono::milliseconds timeout) {
    std::unique_lock lock{frame_mutex};
    frame_signal.wait_for(lock, timeout, [count] { return frame_count > count; });
    return frame_count;
}

#ifndef SHADPS4_ENABLE_FEX_GUEST_CPU
std::string DescribeGuestThreads() {
    return {};
}
#endif

} // namespace Core::GuestCpu
