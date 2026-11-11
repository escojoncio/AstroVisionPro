// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

// The part of the sampling CPU profiler (common/cpu_profiler.h) that needs the system: the thread
// that samples, Mach to stop a thread and read its registers and stack, the app's Mach-O image
// and the file. What it counts and writes is common/cpu_profile.h, tested on Linux.

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <pthread.h>

#include "common/cpu_profile.h"
#include "common/cpu_profiler.h"
#include "common/diagnostics.h"
#include "common/jit_arena.h"
#include "common/logging/log.h"
#include "common/path_util.h"
#include "common/thread.h"

namespace Common::Profiler {

namespace {

using namespace Common::CpuProfile;
using Clock = std::chrono::steady_clock;

struct Target {
    explicit Target(const char* name) : profile{name} {}

    thread_act_t port{};
    u64 stack_lo{};
    u64 stack_hi{};
    ThreadProfile profile; // (the sampler's alone once the target is told of)
};

constexpr u32 kMaxTargets = 8;
constexpr std::chrono::milliseconds kPeriod{2}; // 500 samples a second
std::mutex g_mutex;             // RegisterThread and Stop; the sampler never takes it.
Target* g_targets[kMaxTargets]; // Each written before g_count tells of it; never freed.
std::atomic<u32> g_count{0};
std::atomic<bool> g_stop{false};
std::thread* g_sampler = nullptr;

/// The app's executable (the emulator is linked into it): where it is, its UUID, its functions.
Image FindImage() {
    Image image;
    const auto* header = reinterpret_cast<const mach_header_64*>(_dyld_get_image_header(0));
    image.base = reinterpret_cast<u64>(header);
    const char* path = _dyld_get_image_name(0);
    const char* file = path != nullptr ? std::strrchr(path, '/') : nullptr;
    image.name = file != nullptr ? file + 1 : "app";

    const segment_command_64* linkedit = nullptr;
    const linkedit_data_command* functions = nullptr;
    const auto* command = reinterpret_cast<const load_command*>(header + 1);
    for (u32 i = 0; i < header->ncmds; ++i) {
        if (command->cmd == LC_SEGMENT_64) {
            const auto* segment = reinterpret_cast<const segment_command_64*>(command);
            if (std::strncmp(segment->segname, "__TEXT", sizeof(segment->segname)) == 0) {
                image.vmaddr = segment->vmaddr;
                image.size = segment->vmsize;
            } else if (std::strncmp(segment->segname, "__LINKEDIT", sizeof(segment->segname)) ==
                       0) {
                linkedit = segment;
            }
        } else if (command->cmd == LC_UUID) {
            for (const u8 byte : reinterpret_cast<const uuid_command*>(command)->uuid) {
                char text[3];
                std::snprintf(text, sizeof(text), "%02X", static_cast<unsigned>(byte));
                image.uuid += text;
            }
        } else if (command->cmd == LC_FUNCTION_STARTS) {
            functions = reinterpret_cast<const linkedit_data_command*>(command);
        }
        command = reinterpret_cast<const load_command*>(reinterpret_cast<const u8*>(command) +
                                                        command->cmdsize);
    }
    if (linkedit != nullptr && functions != nullptr) {
        // (the list is in __LINKEDIT, at its offset in the file from where that segment starts)
        const u64 address = image.base + (linkedit->vmaddr - image.vmaddr) +
                            (functions->dataoff - linkedit->fileoff);
        image.starts =
            DecodeFunctionStarts(reinterpret_cast<const u8*>(address), functions->datasize);
    }
    return image;
}

/// The frames as the file has them. dladdr is slow (it walks an image's whole symbol table), so
/// each address is asked about once; the app's own frames need it only for their symbols.
struct Names {
    const Image& image;
    std::unordered_map<u64, std::pair<std::string, std::string>> known; // frame, symbol

    const std::pair<std::string, std::string>& Look(u64 address) {
        if (known.size() >= (1u << 16)) {
            known.clear();
        }
        const auto [entry, fresh] = known.try_emplace(address);
        if (fresh) {
            Dl_info where{};
            if (dladdr(reinterpret_cast<void*>(address), &where) != 0 &&
                where.dli_fname != nullptr && where.dli_fbase != nullptr) {
                const char* file = std::strrchr(where.dli_fname, '/');
                entry->second.first =
                    ImageFrame(file != nullptr ? file + 1 : where.dli_fname,
                               address - reinterpret_cast<u64>(where.dli_fbase));
                // (of a function's start, only its own symbol: with the local symbols stripped
                // the nearest one is another function's)
                if (where.dli_sname != nullptr &&
                    (reinterpret_cast<u64>(where.dli_saddr) == address || !image.Known(address))) {
                    entry->second.second = where.dli_sname;
                }
            } else {
                entry->second.first = "[jit]"; // (in no image)
            }
        }
        return entry->second;
    }

    std::string Frame(u64 address) {
        if (address == kJit) {
            return "[jit]";
        }
        if (address == kTruncated) {
            return "[truncated]";
        }
        if (image.Has(address)) {
            return ImageFrame(image.name, address - image.base);
        }
        return Look(address).first;
    }

    std::string Symbol(u64 address) {
        return address > kTruncated ? Look(address).second : std::string{};
    }
};

std::string Stamp() {
    char stamp[32];
    const std::time_t now = std::time(nullptr);
    std::tm local{};
    localtime_r(&now, &local);
    std::strftime(stamp, sizeof(stamp), "%Y-%m-%d_%H-%M-%S", &local);
    return stamp;
}

void Sample(Target& target, Image& image) {
    RawStack raw;
    const auto begin = Clock::now();
    if (thread_suspend(target.port) != KERN_SUCCESS) {
        ++target.profile.missed;
        return;
    }
    // The thread is stopped, and may hold the allocator's lock, the log's or any other: until
    // thread_resume nothing is allocated, locked or logged; there are only Mach calls and reads.
    arm_thread_state64_t state{};
    mach_msg_type_number_t state_count = ARM_THREAD_STATE64_COUNT;
    const bool got =
        thread_get_state(target.port, ARM_THREAD_STATE64,
                         reinterpret_cast<thread_state_t>(&state), &state_count) == KERN_SUCCESS;
    if (got) {
        Capture(
            static_cast<u64>(arm_thread_state64_get_pc(state)),
            static_cast<u64>(arm_thread_state64_get_lr(state)),
            static_cast<u64>(arm_thread_state64_get_fp(state)), target.stack_lo, target.stack_hi,
            image,
            [](u64 address, u64* words, u64 bytes) {
                // The kernel does the copy: a stack that is no longer there is an error, not a
                // fault (the thread may have ended since it registered).
                vm_size_t copied = 0;
                return vm_read_overwrite(mach_task_self(), static_cast<vm_address_t>(address),
                                         static_cast<vm_size_t>(bytes),
                                         reinterpret_cast<vm_address_t>(words),
                                         &copied) == KERN_SUCCESS &&
                       copied == bytes;
            },
            raw);
    }
    thread_resume(target.port);

    target.profile.suspended_ns += static_cast<u64>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - begin).count());
    if (!got) {
        ++target.profile.missed;
        return;
    }
    if (image.Unknown(raw.pc)) {
        // (code seen for the first time in this page: whether it is an image's is known from now)
        Dl_info where{};
        image.pages.Set(raw.pc, dladdr(reinterpret_cast<void*>(raw.pc), &where) != 0);
    }
    u64 frames[kMaxDepth];
    const u32 depth = FoldStack(raw, image, frames);
    target.profile.Add(frames, depth);
}

void Run() {
    Common::SetCurrentThreadName("shadPS4:CpuProfiler");
    // (a thread it has stopped stays stopped while this one waits for a core)
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    Image image = FindImage();
    Names names{image, {}};

    // (next to the logs, like the probe's CSV)
    std::filesystem::path path;
    if (const char* dir = std::getenv("SHADPS4_PROBE_DIR"); dir != nullptr && *dir != '\0') {
        path = dir;
    } else {
        path = Common::FS::GetUserPath(Common::FS::PathType::LogDir);
    }
    path /= "cpuprof-" + Stamp() + ".txt";
    LOG_INFO(Core, "DIAG: CPU profiler on, {} ({} functions known)", path.string(),
             image.starts.size());

    const auto seconds = [](Clock::duration time) {
        return std::chrono::duration<double>(time).count();
    };
    const auto start = Clock::now();
    auto written = start;
    auto next = start;
    bool header = false;
    for (u32 tick = 0;; ++tick) {
        const bool stop = g_stop.load(std::memory_order_relaxed);
        const u32 count = g_count.load(std::memory_order_acquire);
        if (const auto now = Clock::now(); stop || now - written >= std::chrono::seconds{30}) {
            std::string text;
            if (!header) {
                WriteHeader(text, image);
                header = true;
            }
            BeginInterval(text, seconds(written - start), seconds(now - start), Stamp());
            for (u32 i = 0; i < count; ++i) {
                ThreadProfile& profile = g_targets[i]->profile;
                if (profile.samples != 0 || profile.missed != 0) {
                    WriteThread(
                        text, profile, [&](u64 address) { return names.Frame(address); },
                        [&](u64 address) { return names.Symbol(address); });
                }
                profile.Clear();
            }
            EndInterval(text);
            std::ofstream file{path, std::ios::app};
            file << text;
            if (stop) {
                return;
            }
            written = next = Clock::now();
        }
        if ((tick & 1023) == 0) {
            // (the arena is handed out some time after the first thread registers)
            const auto arena = Common::JitArena::GetUsage();
            image.jit_begin = arena.begin;
            image.jit_end = arena.begin + arena.size;
        }
        next += kPeriod;
        if (const auto now = Clock::now(); next <= now) {
            next = now + kPeriod; // (late: the samples missed are skipped, not made up for)
        }
        std::this_thread::sleep_until(next); // (always ahead: every sample has a sleep before it)
        for (u32 i = 0; i < count; ++i) {
            Sample(*g_targets[i], image);
        }
    }
}

} // namespace

void RegisterThread(const char* name) {
    if (!Common::Diagnostics()) {
        return;
    }
    // (off unless asked for: it changes what the session's other measurements say)
    if (const char* on = std::getenv("SHADPS4_CPU_PROFILE"); on == nullptr || on[0] != '1') {
        return;
    }
    std::scoped_lock lock{g_mutex};
    const u32 count = g_count.load(std::memory_order_relaxed);
    if (count == kMaxTargets) {
        return;
    }
    auto* const target = new Target{name};
    const pthread_t self = pthread_self();
    // (a right of its own to the thread: once it has ended, stopping it fails and nothing is read)
    target->port = mach_thread_self();
    target->stack_hi = reinterpret_cast<u64>(pthread_get_stackaddr_np(self));
    target->stack_lo = target->stack_hi - pthread_get_stacksize_np(self);
    g_targets[count] = target;
    g_count.store(count + 1, std::memory_order_release);
    if (g_sampler == nullptr) {
        g_sampler = new std::thread(Run);
    }
}

void Stop() {
    std::scoped_lock lock{g_mutex};
    if (g_sampler == nullptr || g_stop.exchange(true) ||
        g_sampler->get_id() == std::this_thread::get_id()) {
        return; // (none, ended already, or the sampler itself is the thread ending the session)
    }
    g_sampler->join();
}

} // namespace Common::Profiler
