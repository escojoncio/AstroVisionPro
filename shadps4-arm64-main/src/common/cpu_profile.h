// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

#include "common/types.h"

// What the sampling CPU profiler (common/cpu_profiler.h) reads, counts and writes, with nothing of
// the system in it: it is compiled alone on Linux (tools/tests/cpu_profile_test.cpp). A sample is a
// thread's stack, leaf first. The tables that count the samples have a fixed size and never
// allocate once made.

namespace Common::CpuProfile {

inline constexpr u32 kMaxDepth = 48;
/// The stopped thread's stack is copied a window at a time (small, for the kernel to copy the
/// bytes rather than share the thread's pages copy-on-write), at most so many times a sample.
inline constexpr u32 kWindowWords = 1024;
inline constexpr u32 kMaxReads = 6;
/// Frames that are not addresses: any code the JIT wrote (it has no symbols), and what stands for
/// the callers left out of a stack deeper than kMaxDepth.
inline constexpr u64 kJit = 1;
inline constexpr u64 kTruncated = 2;
/// A return address may carry a pointer authentication signature above the address (the system's
/// libraries sign theirs).
inline constexpr u64 kAddressMask = 0x0000'00ff'ffff'ffffull;

/// What is read of a stopped thread: its pc, its link register and the return addresses of its
/// frame records, innermost first.
struct RawStack {
    u64 pc{};
    u64 lr{};
    u64 rets[kMaxDepth - 1];
    u32 count{};
    bool truncated{};
};

/// Follows the frame records (x29 -> {the caller's x29, the return address}) from `fp`, as long
/// as they are inside the thread's own stack [stack_lo, stack_hi) and go up it. The stack is not
/// read in place (a thread that has ended has none): `read(address, words, bytes)` copies that
/// much of it, or says it cannot. Allocates nothing (it runs while the thread is stopped).
/// `truncated`: there were more records than are taken.
template <typename Read>
void WalkFrames(u64 fp, u64 stack_lo, u64 stack_hi, Read&& read, RawStack& out) {
    u64 window[kWindowWords];
    u64 window_lo = 0;
    u64 window_hi = 0;
    u32 reads = 0;
    out.count = 0;
    out.truncated = false;
    while ((fp & 7) == 0 && fp >= stack_lo && fp < stack_hi && stack_hi - fp >= 2 * sizeof(u64)) {
        if (fp < window_lo || fp >= window_hi || window_hi - fp < 2 * sizeof(u64)) {
            if (reads++ == kMaxReads) {
                out.truncated = true;
                break;
            }
            const u64 bytes = std::min<u64>(stack_hi - fp, sizeof(window)) & ~u64{7};
            if (!read(fp, window, bytes)) {
                break;
            }
            window_lo = fp;
            window_hi = fp + bytes;
        }
        const u64* const record = window + (fp - window_lo) / sizeof(u64);
        const u64 ret = record[1] & kAddressMask;
        if (ret < 4096) {
            break; // (the outermost record, or not a record)
        }
        if (out.count == kMaxDepth - 1) {
            out.truncated = true;
            break;
        }
        out.rets[out.count++] = ret;
        if (record[0] <= fp) {
            break; // (the records of a stack go up)
        }
        fp = record[0];
    }
}

/// Whether the pages code was seen running in are some image's, as far as it was found out:
/// nothing can be asked while the thread is stopped, so a page is asked about afterwards and
/// known from the next sample on. Direct mapped; a page that loses its place is asked about again.
class PageKinds {
public:
    enum class Kind : u8 { Unknown, Image, None };

    Kind Get(u64 address) const {
        const Entry& entry = entries[Index(address)];
        return entry.page == address >> kPageBits ? entry.kind : Kind::Unknown;
    }
    void Set(u64 address, bool image) {
        entries[Index(address)] = {address >> kPageBits, image ? Kind::Image : Kind::None};
    }

private:
    static constexpr u32 kPageBits = 14;
    struct Entry {
        u64 page{};
        Kind kind{Kind::Unknown};
    };
    static std::size_t Index(u64 address) {
        return (address >> kPageBits) & 4095;
    }
    std::vector<Entry> entries = std::vector<Entry>(4096);
};

/// The emulator's own image (the app's executable) as it is loaded, and where the JIT's code is.
struct Image {
    std::string name;
    std::string uuid;
    u64 base{};   ///< Its Mach-O header in memory.
    u64 vmaddr{}; ///< Where its file says the header goes: a symbol's address is vmaddr + offset.
    u64 size{};   ///< Of its code segment.
    /// Its functions' offsets, ascending (LC_FUNCTION_STARTS); empty when it has no such list.
    std::vector<u32> starts;
    u64 jit_begin{};
    u64 jit_end{};
    PageKinds pages; ///< Of the code outside this image.

    bool Has(u64 address) const {
        return address - base < size;
    }
    bool InJit(u64 address) const {
        return address >= jit_begin && address < jit_end;
    }
    /// Whether code at the address is known to be an image's. Only there is x29 a frame pointer
    /// (in the JIT's code it may be any register of the guest's) and the stack walked.
    bool InImage(u64 address) const {
        return Has(address) || (!InJit(address) && pages.Get(address) == PageKinds::Kind::Image);
    }
    /// Whether it is still to be found out (and told to `pages`) if the address is in an image.
    bool Unknown(u64 address) const {
        return !Has(address) && !InJit(address) &&
               pages.Get(address) == PageKinds::Kind::Unknown;
    }
    /// Whether the function the address is in is known.
    bool Known(u64 address) const {
        return Has(address) && !starts.empty() && address - base >= starts.front();
    }
    /// What an address counts as: the start of its function in this image, kJit in the JIT's
    /// code and in any page known to be no image's, itself anywhere else. Samples of one function
    /// then add up whatever instruction each one stopped at.
    u64 Fold(u64 address) const {
        if (InJit(address) || (!Has(address) && pages.Get(address) == PageKinds::Kind::None)) {
            return kJit;
        }
        if (!Known(address)) {
            return address;
        }
        return base + *(std::upper_bound(starts.begin(), starts.end(),
                                         static_cast<u32>(address - base)) -
                        1);
    }
};

/// What is taken of a stopped thread, given its registers: the stack is only walked when the
/// thread is running an image's code.
template <typename Read>
void Capture(u64 pc, u64 lr, u64 fp, u64 stack_lo, u64 stack_hi, const Image& image, Read&& read,
             RawStack& out) {
    out.pc = pc;
    out.lr = lr;
    out.count = 0;
    out.truncated = false;
    if (image.InImage(pc)) {
        WalkFrames(fp, stack_lo, stack_hi, read, out);
    }
}

/// The offsets in a Mach-O LC_FUNCTION_STARTS list: ULEB128 steps from one function to the next,
/// ended by a zero.
inline std::vector<u32> DecodeFunctionStarts(const u8* data, std::size_t size) {
    std::vector<u32> starts;
    u64 offset = 0;
    for (std::size_t i = 0; i < size;) {
        u64 step = 0;
        for (u32 shift = 0; i < size && shift < 64; shift += 7) {
            const u8 byte = data[i++];
            step |= static_cast<u64>(byte & 0x7f) << shift;
            if ((byte & 0x80) == 0) {
                break;
            }
        }
        if (step == 0) {
            break;
        }
        offset += step;
        starts.push_back(static_cast<u32>(offset));
    }
    return starts;
}

/// A sample's stack as it is counted, leaf first, at most kMaxDepth frames in `frames`; returns
/// how many: one, kJit, for code that is no image's. Return addresses are taken back to the call
/// (-4) before they are folded.
inline u32 FoldStack(const RawStack& raw, const Image& image, u64* frames) {
    u32 depth = 0;
    frames[depth++] = image.Fold(raw.pc);
    if (frames[0] == kJit) {
        return depth; // (nothing there says who called)
    }
    // A function with no frame record of its own (a leaf, or one still in its prologue) has its
    // caller in the link register only. With a record, the register holds either the same return
    // address as the record or one into the function itself (left by its last call): only a
    // caller that is another function is taken, which needs the functions to be known.
    const u64 lr = raw.lr & kAddressMask;
    if (image.Known(raw.pc) && lr >= 4096 && (raw.count == 0 || lr != raw.rets[0])) {
        const u64 caller = image.Fold(lr - 4);
        if (caller != frames[0]) {
            frames[depth++] = caller;
        }
    }
    bool truncated = raw.truncated;
    for (u32 i = 0; i < raw.count; ++i) {
        if (depth == kMaxDepth) {
            truncated = true;
            break;
        }
        frames[depth++] = image.Fold(raw.rets[i] - 4);
    }
    if (truncated) {
        // (in the place of the outermost frame when there is no room for one more)
        depth -= depth == kMaxDepth;
        frames[depth++] = kTruncated;
    }
    return depth;
}

/// Stacks and how many samples had each: open addressing over a fixed number of slots (a power
/// of two) and a fixed pool of frames.
class StackTable {
public:
    StackTable(u32 slot_count, u32 pool_frames) : slots(slot_count), pool(pool_frames) {}

    /// Counts a sample of the stack; false when the stack is new and there is no room for it.
    bool Add(const u64* frames, u32 depth) noexcept {
        u64 hash = depth;
        for (u32 i = 0; i < depth; ++i) {
            hash = (hash ^ frames[i]) * 0x9E3779B97F4A7C15ull;
            hash ^= hash >> 29;
        }
        const u32 mask = static_cast<u32>(slots.size()) - 1;
        for (u32 at = static_cast<u32>(hash) & mask;; at = (at + 1) & mask) {
            Slot& slot = slots[at];
            if (slot.count == 0) {
                // (a quarter of the slots stays empty, so every search ends)
                if (used >= slots.size() / 4 * 3 || pool.size() - pool_used < depth) {
                    return false;
                }
                std::memcpy(pool.data() + pool_used, frames, depth * sizeof(u64));
                slot = {hash, pool_used, 1, depth};
                pool_used += depth;
                ++used;
                return true;
            }
            if (slot.hash == hash && slot.depth == depth &&
                std::memcmp(pool.data() + slot.first, frames, depth * sizeof(u64)) == 0) {
                ++slot.count;
                return true;
            }
        }
    }

    void Clear() noexcept {
        std::fill(slots.begin(), slots.end(), Slot{});
        used = 0;
        pool_used = 0;
    }

    u32 Size() const {
        return used;
    }

    /// call(frames, depth, samples) for every stack.
    template <typename Call>
    void ForEach(Call&& call) const {
        for (const Slot& slot : slots) {
            if (slot.count != 0) {
                call(pool.data() + slot.first, slot.depth, slot.count);
            }
        }
    }

private:
    struct Slot {
        u64 hash{};
        u32 first{};
        u32 count{};
        u32 depth{};
    };
    std::vector<Slot> slots;
    std::vector<u64> pool;
    u32 used{};
    u32 pool_used{};
};

/// For each frame, in how many samples it was the leaf (exclusive) and in how many it was
/// anywhere in the stack (inclusive). Fixed size like StackTable.
class PcTable {
public:
    struct Entry {
        u64 address{};
        u32 exclusive{};
        u32 inclusive{};
    };

    explicit PcTable(u32 slot_count) : slots(slot_count) {}

    /// Counts a sample's stack; false when one of its frames is new and there is no room for it.
    bool Add(const u64* frames, u32 depth) noexcept {
        bool room = true;
        for (u32 i = 0; i < depth; ++i) {
            // (a frame counts once a sample, however many times it recurs in the stack)
            if (frames[i] == kTruncated || std::find(frames, frames + i, frames[i]) != frames + i) {
                continue;
            }
            Entry* const entry = Find(frames[i]);
            if (entry == nullptr) {
                room = false;
                continue;
            }
            entry->exclusive += i == 0;
            ++entry->inclusive;
        }
        return room;
    }

    void Clear() noexcept {
        std::fill(slots.begin(), slots.end(), Entry{});
        used = 0;
    }

    template <typename Call>
    void ForEach(Call&& call) const {
        for (const Entry& entry : slots) {
            if (entry.inclusive != 0) {
                call(entry);
            }
        }
    }

private:
    /// The frame's entry (a new one has no counts yet, and gets one from the caller), or none.
    Entry* Find(u64 address) noexcept {
        const u32 mask = static_cast<u32>(slots.size()) - 1;
        for (u32 at = static_cast<u32>((address * 0x9E3779B97F4A7C15ull) >> 32) & mask;;
             at = (at + 1) & mask) {
            Entry& entry = slots[at];
            if (entry.inclusive == 0) {
                if (used >= slots.size() / 4 * 3) {
                    return nullptr;
                }
                ++used;
                entry.address = address;
                return &entry;
            }
            if (entry.address == address) {
                return &entry;
            }
        }
    }

    std::vector<Entry> slots;
    u32 used{};
};

/// What is counted of one thread between two writes of the file.
struct ThreadProfile {
    explicit ThreadProfile(std::string name_, u32 stack_slots = 1u << 14,
                           u32 pool_frames = 1u << 18, u32 pc_slots = 1u << 14)
        : name{std::move(name_)}, stacks{stack_slots, pool_frames}, pcs{pc_slots} {}

    void Add(const u64* frames, u32 depth) noexcept {
        ++samples;
        stacks_dropped += !stacks.Add(frames, depth);
        pcs_dropped += !pcs.Add(frames, depth);
    }

    void Clear() noexcept {
        stacks.Clear();
        pcs.Clear();
        samples = missed = suspended_ns = stacks_dropped = pcs_dropped = 0;
    }

    std::string name;
    StackTable stacks;
    PcTable pcs;
    u64 samples{};
    u64 missed{};         ///< Times the thread could not be stopped or read.
    u64 suspended_ns{};   ///< How long it was kept stopped: what the profiler costs it.
    u64 stacks_dropped{}; ///< Samples whose stack found no room in the table.
    u64 pcs_dropped{};    ///< Samples with a frame that found no room in the table.
};

inline std::string Hex(u64 value) {
    char text[20];
    std::snprintf(text, sizeof(text), "%llx", static_cast<unsigned long long>(value));
    return text;
}

/// A name without what the file's lines are split on (spaces, ';').
inline std::string Clean(std::string text) {
    for (char& c : text) {
        if (static_cast<unsigned char>(c) <= ' ' || c == ';') {
            c = '_';
        }
    }
    return text;
}

/// How a frame inside an image is written.
inline std::string ImageFrame(const std::string& image, u64 offset) {
    return Clean(image) + "+0x" + Hex(offset);
}

// The file (tools/symbolize_cpuprof.py reads it): WriteHeader once, then for every interval
// BeginInterval, WriteThread for each thread and EndInterval. An interval holds only what was
// sampled in it, so a span of the session can be told from the rest; one cut short by the app's
// end has no "end" line.

inline void WriteHeader(std::string& out, const Image& image) {
    out += "cpuprof 1\n";
    out += "# excl, incl: <samples> <frame>[=<symbol>]. folded: <root>;...;<leaf> <samples>. A "
           "frame is <image>+0x<offset>: in the image below, the start of the function (its "
           "symbol is at vmaddr + offset). [jit]: code with no image. [truncated]: callers left "
           "out. Samples are taken by the clock, waits included.\n";
    out += "image " + Clean(image.name) + " uuid=" + image.uuid + " slide=0x" +
           Hex(image.base - image.vmaddr) + " vmaddr=0x" + Hex(image.vmaddr) +
           " functions=" + std::to_string(image.starts.size()) + "\n";
}

/// `t0` and `t1`: seconds since the profiler started; `wall`: the time of day at t1.
inline void BeginInterval(std::string& out, double t0, double t1, const std::string& wall) {
    char text[96];
    std::snprintf(text, sizeof(text), "interval t0=%.3f t1=%.3f wall=", t0, t1);
    out += text + wall + "\n";
}

inline void EndInterval(std::string& out) {
    out += "end\n";
}

/// A thread's part of an interval: its totals, its `top` frames by exclusive and by inclusive
/// samples, and its `top` stacks. `frame(address)` writes a frame, `symbol(address)` gives its
/// symbol or nothing.
template <typename Frame, typename Symbol>
void WriteThread(std::string& out, const ThreadProfile& thread, Frame&& frame, Symbol&& symbol,
                 std::size_t top = 200) {
    out += "thread " + Clean(thread.name) + " samples=" + std::to_string(thread.samples) +
           " missed=" + std::to_string(thread.missed) +
           " suspended_us=" + std::to_string(thread.suspended_ns / 1000) +
           " stacks=" + std::to_string(thread.stacks.Size()) +
           " stacks_dropped=" + std::to_string(thread.stacks_dropped) +
           " pcs_dropped=" + std::to_string(thread.pcs_dropped) + "\n";

    std::vector<PcTable::Entry> pcs;
    thread.pcs.ForEach([&](const PcTable::Entry& entry) { pcs.push_back(entry); });
    const auto list = [&](const char* title, u32 PcTable::Entry::* count) {
        const std::size_t listed = std::min<std::size_t>(
            top, std::count_if(pcs.begin(), pcs.end(),
                               [&](const PcTable::Entry& entry) { return entry.*count != 0; }));
        std::partial_sort(pcs.begin(), pcs.begin() + listed, pcs.end(),
                          [&](const PcTable::Entry& a, const PcTable::Entry& b) {
                              return a.*count != b.*count ? a.*count > b.*count
                                                          : a.address < b.address;
                          });
        out += std::string{title} + " " + std::to_string(listed) + "\n";
        for (std::size_t i = 0; i < listed; ++i) {
            const std::string name = symbol(pcs[i].address);
            out += std::to_string(pcs[i].*count) + " " + frame(pcs[i].address) +
                   (name.empty() ? "" : "=" + Clean(name)) + "\n";
        }
    };
    list("excl", &PcTable::Entry::exclusive);
    list("incl", &PcTable::Entry::inclusive);

    struct Stack {
        const u64* frames;
        u32 depth;
        u32 count;
    };
    std::vector<Stack> stacks;
    thread.stacks.ForEach([&](const u64* frames, u32 depth, u32 count) {
        stacks.push_back({frames, depth, count});
    });
    const std::size_t listed = std::min(top, stacks.size());
    std::partial_sort(stacks.begin(), stacks.begin() + listed, stacks.end(),
                      [](const Stack& a, const Stack& b) {
                          return a.count != b.count
                                     ? a.count > b.count
                                     : std::lexicographical_compare(a.frames, a.frames + a.depth,
                                                                    b.frames, b.frames + b.depth);
                      });
    out += "folded " + std::to_string(listed) + "\n";
    for (std::size_t i = 0; i < listed; ++i) {
        for (u32 at = stacks[i].depth; at-- > 0;) {
            out += frame(stacks[i].frames[at]);
            out += at != 0 ? ';' : ' ';
        }
        out += std::to_string(stacks[i].count) + "\n";
    }
}

} // namespace Common::CpuProfile
