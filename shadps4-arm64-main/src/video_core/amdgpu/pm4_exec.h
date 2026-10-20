// Pure parts of the PM4 packets the command processor executes by itself (Sea Islands, gfx7): the
// atomics' arithmetic, comparison functions, register read-modify-write, occlusion result sums,
// predication, stream-out buffer bookkeeping, coherence ranges. No emulator state, no pointers
// followed except the ones handed in, so tests/video_core/test_pm4_exec.cpp builds it alone.
// The packet layouts are the ones of the gfx7 PM4 specification (names as in the AMD CI/VI PM4
// opcode list); liverpool.cpp binds them to the register file, guest memory and the rasterizer.
#pragma once

#include <atomic>
#include <bit>
#include <cstdint>
#include <cstring>
#include <type_traits>

namespace AmdGpu::Pm4 {

using u32 = std::uint32_t;
using u64 = std::uint64_t;

// ---- Names, for the census ----------------------------------------------------------------------

struct OpName {
    u32 code;
    const char* name;
};
inline constexpr OpName kOpNames[] = {
    {0x10, "NOP"}, {0x11, "SET_BASE"}, {0x12, "CLEAR_STATE"}, {0x13, "INDEX_BUFFER_SIZE"},
    {0x15, "DISPATCH_DIRECT"}, {0x16, "DISPATCH_INDIRECT"}, {0x1D, "ATOMIC_GDS"}, {0x1E, "ATOMIC"},
    {0x1F, "OCCLUSION_QUERY"}, {0x20, "SET_PREDICATION"}, {0x21, "REG_RMW"}, {0x22, "COND_EXEC"},
    {0x23, "PRED_EXEC"}, {0x24, "DRAW_INDIRECT"}, {0x25, "DRAW_INDEX_INDIRECT"}, {0x26, "INDEX_BASE"},
    {0x27, "DRAW_INDEX_2"}, {0x28, "CONTEXT_CONTROL"}, {0x2A, "INDEX_TYPE"}, {0x2C, "DRAW_INDIRECT_MULTI"},
    {0x2D, "DRAW_INDEX_AUTO"}, {0x2F, "NUM_INSTANCES"}, {0x30, "DRAW_INDEX_MULTI_AUTO"},
    {0x33, "INDIRECT_BUFFER_CONST"}, {0x34, "STRMOUT_BUFFER_UPDATE"}, {0x35, "DRAW_INDEX_OFFSET_2"},
    {0x36, "DRAW_PREAMBLE"}, {0x37, "WRITE_DATA"}, {0x38, "DRAW_INDEX_INDIRECT_MULTI"}, {0x39, "MEM_SEMAPHORE"},
    {0x3B, "COPY_DW"}, {0x3C, "WAIT_REG_MEM"}, {0x3F, "INDIRECT_BUFFER"}, {0x40, "COPY_DATA"},
    {0x41, "COMMAND_PROCESSOR_DMA"}, {0x42, "PFP_SYNC_ME"}, {0x43, "SURFACE_SYNC"}, {0x45, "COND_WRITE"},
    {0x46, "EVENT_WRITE"}, {0x47, "EVENT_WRITE_EOP"}, {0x48, "EVENT_WRITE_EOS"}, {0x49, "RELEASE_MEM"},
    {0x4A, "PREAMBLE_CNTL"}, {0x50, "DMA_DATA"}, {0x51, "CONTEXT_REG_RMW"}, {0x58, "ACQUIRE_MEM"},
    {0x59, "REWIND"}, {0x5E, "LOAD_UCONFIG_REG"}, {0x5F, "LOAD_SH_REG"}, {0x60, "LOAD_CONFIG_REG"},
    {0x61, "LOAD_CONTEXT_REG"}, {0x63, "LOAD_SH_REG_INDEX"}, {0x68, "SET_CONFIG_REG"}, {0x69, "SET_CONTEXT_REG"},
    {0x73, "SET_CONTEXT_REG_INDIRECT"}, {0x76, "SET_SH_REG"}, {0x77, "SET_SH_REG_OFFSET"}, {0x78, "SET_QUEUE_REG"},
    {0x79, "SET_UCONFIG_REG"}, {0x7D, "SCRATCH_RAM_WRITE"}, {0x7E, "SCRATCH_RAM_READ"}, {0x80, "LOAD_CONST_RAM"},
    {0x81, "WRITE_CONST_RAM"}, {0x83, "DUMP_CONST_RAM"}, {0x84, "INCREMENT_CE_COUNTER"},
    {0x85, "INCREMENT_DE_COUNTER"}, {0x86, "WAIT_ON_CE_COUNTER"}, {0x87, "WAIT_ON_DE_COUNTER"},
    {0x88, "WAIT_ON_DE_COUNTER_DIFF"}, {0x8B, "SWITCH_BUFFER"}, {0x8E, "GET_LOD_STATS"},
    {0x91, "INDEX_ATTRIBUTES_INDIRECT"}, {0x9B, "SET_SH_REG_INDEX"}, {0x9D, "DRAW_INDEX_INDIRECT_COUNT_MULTI"},
    {0x9E, "DUMP_CONST_RAM_OFFSET"}, {0x9F, "LOAD_CONTEXT_REG_INDEX"},
};

// "ATOMIC" for 0x1E, "opcode 0xNN" (into `scratch`, at least 16 bytes) for one not in the list.
inline const char* OpcodeName(u32 code, char* scratch) {
    for (const OpName& n : kOpNames)
        if (n.code == code) return n.name;
    char* p = scratch;
    const char prefix[] = "opcode 0x";
    for (const char* c = prefix; *c; ++c) *p++ = *c;
    for (int shift = 4; shift >= 0; shift -= 4) *p++ = "0123456789abcdef"[(code >> shift) & 15];
    *p = 0;
    return scratch;
}

// ---- Comparison (WAIT_REG_MEM, COND_WRITE) ------------------------------------------------------

// FUNCTION field: 0 always, 1 <, 2 <=, 3 ==, 4 !=, 5 >=, 6 >, applied as `value FUNC reference`,
// `value` already masked. 7 is reserved: false.
inline bool CompareFunction(u32 function, u32 value, u32 reference) {
    switch (function) {
    case 0: return true;
    case 1: return value < reference;
    case 2: return value <= reference;
    case 3: return value == reference;
    case 4: return value != reference;
    case 5: return value >= reference;
    case 6: return value > reference;
    default: return false;
    }
}

// ---- ATOMIC (ATOMIC_MEM): ATOMIC field = the texture cache's operation code ---------------------

enum class AtomicKind : std::uint8_t { Swap, CmpSwap, Add, Sub, SMin, UMin, SMax, UMax, And, Or, Xor, Inc, Dec };

struct AtomicDecode {
    bool valid = false;
    AtomicKind kind = AtomicKind::Swap;
    bool wide = false;    // 64-bit
    bool returns = false; // the _RTN forms (the packet has nowhere to put the value, but COPY_DATA can read it)
};

// 7..19 = *_RTN_32, 39..51 = *_RTN_64, 71..83 = *_32, 103..115 = *_64, each in the order of AtomicKind.
// Floating-point forms (FCMPSWAP, FMIN, FMAX) are not decoded: valid = false.
inline AtomicDecode DecodeAtomic(u32 op) {
    struct Range {
        u32 base;
        bool wide, returns;
    };
    static constexpr Range ranges[] = {{7, false, true}, {39, true, true}, {71, false, false}, {103, true, false}};
    for (const Range& r : ranges)
        if (op >= r.base && op < r.base + 13) return {true, AtomicKind(op - r.base), r.wide, r.returns};
    return {};
}

namespace detail {
template <class U>
U Apply(AtomicKind kind, U old, U src, U cmp, bool& swapped) {
    using S = std::make_signed_t<U>;
    swapped = true;
    switch (kind) {
    case AtomicKind::Swap: return src;
    case AtomicKind::CmpSwap: swapped = old == cmp; return old == cmp ? src : old;
    case AtomicKind::Add: return U(old + src);
    case AtomicKind::Sub: return U(old - src);
    case AtomicKind::SMin: return S(old) < S(src) ? old : src;
    case AtomicKind::UMin: return old < src ? old : src;
    case AtomicKind::SMax: return S(old) > S(src) ? old : src;
    case AtomicKind::UMax: return old > src ? old : src;
    case AtomicKind::And: return old & src;
    case AtomicKind::Or: return old | src;
    case AtomicKind::Xor: return old ^ src;
    case AtomicKind::Inc: return old >= src ? U(0) : U(old + 1);              // wrapping increment
    case AtomicKind::Dec: return (old == 0 || old > src) ? src : U(old - 1); // wrapping decrement
    }
    return old;
}

template <class U>
U AtomicOn(AtomicKind kind, void* address, U src, U cmp, bool& swapped) {
    if ((reinterpret_cast<std::uintptr_t>(address) & (alignof(U) - 1)) == 0) {
        std::atomic_ref<U> ref(*static_cast<U*>(address));
        U old = ref.load(std::memory_order_relaxed);
        for (;;) {
            const U next = Apply<U>(kind, old, src, cmp, swapped);
            if (!swapped || ref.compare_exchange_weak(old, next, std::memory_order_acq_rel)) return old;
        }
    }
    U old;
    std::memcpy(&old, address, sizeof old); // unaligned: a plain read-modify-write
    const U next = Apply<U>(kind, old, src, cmp, swapped);
    if (swapped) std::memcpy(address, &next, sizeof next);
    return old;
}
} // namespace detail

// Performs the operation on `address` (32 or 64 bits by `d.wide`) and returns the previous value.
// `swapped` is false only for a CMPSWAP whose comparison failed (memory untouched).
inline u64 ApplyAtomic(const AtomicDecode& d, void* address, u64 src, u64 cmp, bool& swapped) {
    if (d.wide) return detail::AtomicOn<u64>(d.kind, address, src, cmp, swapped);
    return detail::AtomicOn<u32>(d.kind, address, u32(src), u32(cmp), swapped);
}

// ---- REG_RMW / CONTEXT_REG_RMW ------------------------------------------------------------------

struct RegRmw {
    u32 reg;       // register dword offset (MMIO index)
    bool and_reg;  // AND mask is the value of the register at `and_mask` instead of an immediate
    bool or_reg;
    u32 and_mask, or_mask;
};

// Body: DW1 MOD_ADDR[15:0] | AND_MASK_SRC[30] | OR_MASK_SRC[31]; DW2 AND_MASK; DW3 OR_MASK.
inline RegRmw ParseRegRmw(const u32* body) {
    return {body[0] & 0xFFFF, ((body[0] >> 30) & 1) != 0, ((body[0] >> 31) & 1) != 0, body[1], body[2]};
}
inline u32 ApplyRegRmw(u32 old, u32 and_mask, u32 or_mask) {
    return (old & and_mask) | or_mask;
}
// CONTEXT_REG_RMW body: DW1 REG_OFFSET[15:0] (from the context register base), DW2 REG_MASK, DW3 REG_DATA:
// only the masked bits change.
inline u32 ApplyContextRegRmw(u32 old, u32 mask, u32 data) {
    return (old & ~mask) | (data & mask);
}

// ---- Occlusion: ZPASS_DONE results --------------------------------------------------------------

inline constexpr u64 kZPassValid = 0x8000'0000'0000'0000ull;

// One render backend's sample: begin and end counters, bit 63 set once the hardware wrote them.
struct ZPassPair {
    u64 begin, end;
};

// Sum of end - begin over the pairs. `all_valid` is false if some pair has not been written yet
// (a valid bit missing), in which case the sum covers only the written ones.
inline u64 SumZPass(const ZPassPair* pairs, u32 count, bool& all_valid) {
    u64 sum = 0;
    all_valid = true;
    for (u32 i = 0; i < count; ++i) {
        if (!((pairs[i].begin & pairs[i].end) & kZPassValid)) {
            all_valid = false;
            continue;
        }
        sum += (pairs[i].end & ~kZPassValid) - (pairs[i].begin & ~kZPassValid);
    }
    return sum;
}

// ---- SET_PREDICATION ------------------------------------------------------------------------------

enum class PredicationOp : std::uint8_t { Clear = 0, ZPass = 1, PrimCount = 2, Bool64 = 3, Bool32 = 4 };

struct SetPredication {
    u64 address;          // START_ADDR (40 bits)
    u32 op;               // PRED_OP
    bool draw_if_visible; // PRED_BOOL: the predicate is "visible" (memory says non-zero) rather than its negation
    bool no_wait;         // HINT: the draw may go ahead if the result is not ready
    bool continue_;       // CONTINUE: combine with the predicate already set
};

// Body: DW1 START_ADDR_LO; DW2 START_ADDR_HI[7:0] | PRED_BOOL[8] | HINT[12] | PRED_OP[18:16] | CONTINUE[31].
inline SetPredication ParseSetPredication(const u32* body) {
    return {u64(body[0]) | u64(body[1] & 0xFF) << 32, (body[1] >> 16) & 7, ((body[1] >> 8) & 1) != 0,
            ((body[1] >> 12) & 1) != 0, (body[1] >> 31) != 0};
}

struct Predication {
    bool enabled = false;
    bool execute = true; // packets with the PREDICATE bit run only while this holds
    bool Skips() const { return enabled && !execute; }

    void Clear() { *this = {}; }
    // `memory_says_visible`: the query / boolean in memory is non-zero. Returns the new execute flag.
    void Set(const SetPredication& p, bool memory_says_visible) {
        const bool run = p.draw_if_visible ? memory_says_visible : !memory_says_visible;
        execute = (p.continue_ && enabled) ? (execute || run) : run;
        enabled = true;
    }
};

// ---- STRMOUT_BUFFER_UPDATE ------------------------------------------------------------------------

enum class StrmoutSource : std::uint8_t { Packet = 0, FilledSize = 1, Memory = 2, None = 3 };

struct StrmoutUpdate {
    bool store_filled_size; // write the buffer's filled size to DST_ADDRESS
    StrmoutSource source;
    u32 buffer;             // 0..3
    u64 dst_address;
    u32 packet_offset;      // SRC_ADDRESS_LO / BUFFER_OFFSET: the offset (Packet) or low address (Memory)
    u64 src_address;
};

// Body: DW1 STORE_BUFFER_FILLED_SIZE[0] | OFFSET_SOURCE[2:1] | SELECT_BUFFER[9:8]; DW2 DST_ADDRESS_LO[31:2];
// DW3 DST_ADDRESS_HI[15:0]; DW4 BUFFER_OFFSET / SRC_ADDRESS_LO[31:2]; DW5 SRC_ADDRESS_HI[15:0].
inline StrmoutUpdate ParseStrmoutUpdate(const u32* body) {
    StrmoutUpdate u{};
    u.store_filled_size = body[0] & 1;
    u.source = StrmoutSource((body[0] >> 1) & 3);
    u.buffer = (body[0] >> 8) & 3;
    u.dst_address = u64(body[1] & ~3u) | u64(body[2] & 0xFFFF) << 32;
    u.packet_offset = body[3];
    u.src_address = u64(body[3] & ~3u) | u64(body[4] & 0xFFFF) << 32;
    return u;
}

// ---- Coherence (ACQUIRE_MEM, SURFACE_SYNC) --------------------------------------------------------

struct CoherRange {
    u64 base = 0, size = 0; // bytes
    bool everything = false; // size field all ones: the whole address space
};

// Both packets count in units of 256 bytes. ACQUIRE_MEM has 40-bit counts split in two dwords.
inline CoherRange DecodeCoherRange(u32 size_lo, u32 size_hi, u32 base_lo, u32 base_hi) {
    CoherRange r;
    const u64 size = u64(size_lo) | u64(size_hi & 0xFF) << 32;
    r.everything = size_lo == 0xFFFFFFFFu && (size_hi & 0xFF) == 0xFF;
    r.base = (u64(base_lo) | u64(base_hi & 0xFF) << 32) << 8;
    r.size = r.everything ? ~u64(0) : size << 8;
    return r;
}

// CP_COHER_CNTL action bits.
inline constexpr u32 kCohTcWbAction = 1u << 18;
inline constexpr u32 kCohTcl1Action = 1u << 22;
inline constexpr u32 kCohTcAction = 1u << 23;
inline constexpr u32 kCohCbAction = 1u << 25;
inline constexpr u32 kCohDbAction = 1u << 26;
inline constexpr u32 kCohShKcacheAction = 1u << 27;
inline constexpr u32 kCohShIcacheAction = 1u << 29;

// The GPU's writes into the range become visible to the CPU / other units (render target caches and
// the texture cache written back).
inline bool CoherPublishesGpuWrites(u32 cntl) {
    return cntl & (kCohCbAction | kCohDbAction | kCohTcWbAction);
}
// Readers' caches are invalidated: the CPU's (or another queue's) writes become visible to the GPU.
inline bool CoherInvalidatesReaders(u32 cntl) {
    return cntl & (kCohTcl1Action | kCohTcAction | kCohShKcacheAction | kCohShIcacheAction);
}

// ---- COND_WRITE -------------------------------------------------------------------------------------

struct CondWrite {
    u32 function;
    bool poll_memory;  // else a register
    bool write_memory; // else a register
    u64 poll_address;  // or register offset
    u32 reference, mask;
    u64 write_address; // or register offset
    u32 data;
};

// Body: DW1 FUNCTION[2:0] | POLL_SPACE[4] | WRITE_SPACE[8]; DW2/DW3 POLL_ADDRESS; DW4 REFERENCE; DW5 MASK;
// DW6/DW7 WRITE_ADDRESS; DW8 WRITE_DATA.
inline CondWrite ParseCondWrite(const u32* body) {
    CondWrite c{};
    c.function = body[0] & 7;
    c.poll_memory = (body[0] >> 4) & 1;
    c.write_memory = (body[0] >> 8) & 1;
    c.poll_address = u64(body[1]) | u64(body[2]) << 32;
    c.reference = body[3];
    c.mask = body[4];
    c.write_address = u64(body[5]) | u64(body[6]) << 32;
    c.data = body[7];
    return c;
}

} // namespace AmdGpu::Pm4
