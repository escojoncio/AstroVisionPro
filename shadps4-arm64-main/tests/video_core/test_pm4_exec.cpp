// Pure PM4 arithmetic (pm4_exec.h): atomics, comparison, register RMW, occlusion sums, predication,
// stream-out and coherence decoding. Standalone: exit code 0 = pass.
#include <cstdio>
#include <cstring>

#include "video_core/amdgpu/pm4_exec.h"

using namespace AmdGpu::Pm4;

namespace {
int failures = 0;
#define CHECK(c)                                                                                   \
    do {                                                                                           \
        if (!(c)) {                                                                                \
            std::fprintf(stderr, "%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, #c);             \
            ++failures;                                                                            \
        }                                                                                          \
    } while (0)

u64 run(u32 tc_op, u64 initial, u64 src, u64 cmp, u64& after, bool* swapped_out = nullptr) {
    const AtomicDecode d = DecodeAtomic(tc_op);
    alignas(8) u64 mem = initial;
    bool swapped = true;
    const u64 old = ApplyAtomic(d, &mem, src, cmp, swapped);
    after = d.wide ? mem : u32(mem);
    if (swapped_out) *swapped_out = swapped;
    return old;
}
} // namespace

int main() {
    // Decoding: the four ranges and their order.
    for (u32 k = 0; k < 13; ++k) {
        CHECK(DecodeAtomic(7 + k).valid && u32(DecodeAtomic(7 + k).kind) == k && !DecodeAtomic(7 + k).wide && DecodeAtomic(7 + k).returns);
        CHECK(DecodeAtomic(39 + k).wide && DecodeAtomic(39 + k).returns);
        CHECK(!DecodeAtomic(71 + k).returns && !DecodeAtomic(71 + k).wide);
        CHECK(DecodeAtomic(103 + k).wide && !DecodeAtomic(103 + k).returns);
    }
    CHECK(!DecodeAtomic(0).valid && !DecodeAtomic(1).valid && !DecodeAtomic(20).valid && !DecodeAtomic(116).valid);

    u64 after;
    CHECK(run(7, 5, 9, 0, after) == 5 && after == 9);                   // swap
    CHECK(run(9, 0xFFFFFFFF, 2, 0, after) == 0xFFFFFFFF && after == 1); // add wraps at 32 bits
    CHECK(run(10, 3, 5, 0, after) == 3 && after == 0xFFFFFFFE);         // sub
    CHECK(run(11, u32(-5), 3, 0, after) == u32(-5) && after == u32(-5)); // smin
    CHECK(run(12, u32(-5), 3, 0, after) == u32(-5) && after == 3);       // umin
    CHECK(run(13, u32(-5), 3, 0, after) == u32(-5) && after == 3);       // smax
    CHECK(run(14, u32(-5), 3, 0, after) == u32(-5) && after == u32(-5)); // umax
    CHECK(run(15, 0xF0F0, 0xFF00, 0, after) == 0xF0F0 && after == 0xF000);
    CHECK(run(16, 0xF0F0, 0x0F0F, 0, after) == 0xF0F0 && after == 0xFFFF);
    CHECK(run(17, 0xFF, 0x0F, 0, after) == 0xFF && after == 0xF0);
    // INC: wraps to 0 at the limit; DEC: wraps to the limit at 0 or above it.
    CHECK(run(18, 4, 5, 0, after) == 4 && after == 5);
    CHECK(run(18, 5, 5, 0, after) == 5 && after == 0);
    CHECK(run(19, 4, 9, 0, after) == 4 && after == 3);
    CHECK(run(19, 0, 9, 0, after) == 0 && after == 9);
    CHECK(run(19, 10, 9, 0, after) == 10 && after == 9);
    // CMPSWAP.
    bool swapped;
    CHECK(run(8, 6, 77, 6, after, &swapped) == 6 && after == 77 && swapped);
    CHECK(run(8, 6, 77, 7, after, &swapped) == 6 && after == 6 && !swapped);
    // 64-bit: add carries into the high word; the 32-bit form does not touch it.
    CHECK(run(41, 0xFFFFFFFF, 1, 0, after) == 0xFFFFFFFF && after == 0x100000000ull);
    alignas(8) u64 both = 0xAAAAAAAA'FFFFFFFFull;
    bool sw;
    ApplyAtomic(DecodeAtomic(9), &both, 1, 0, sw);
    CHECK(both == 0xAAAAAAAA'00000000ull);
    // Unaligned 32-bit address inside a buffer still works (plain read-modify-write path).
    alignas(8) unsigned char raw[16] = {};
    u32 v = 10;
    std::memcpy(raw + 1, &v, 4);
    ApplyAtomic(DecodeAtomic(9), raw + 1, 5, 0, sw);
    std::memcpy(&v, raw + 1, 4);
    CHECK(v == 15);

    // Comparison functions.
    CHECK(CompareFunction(0, 1, 2) && CompareFunction(1, 1, 2) && !CompareFunction(1, 2, 2) &&
          CompareFunction(2, 2, 2) && CompareFunction(3, 2, 2) && CompareFunction(4, 1, 2) &&
          CompareFunction(5, 2, 2) && CompareFunction(6, 3, 2) && !CompareFunction(6, 2, 2) && !CompareFunction(7, 0, 0));

    // Register RMW.
    const u32 rmw[] = {0xA100u | (1u << 30), 0xFF00u, 0x12u};
    const RegRmw r = ParseRegRmw(rmw);
    CHECK(r.reg == 0xA100 && r.and_reg && !r.or_reg && r.and_mask == 0xFF00 && r.or_mask == 0x12);
    CHECK(ApplyRegRmw(0x1234, 0xFF00, 0x12) == 0x1212);
    CHECK(ApplyContextRegRmw(0xAABBCCDD, 0x0000FF00, 0x12345678) == 0xAABB56DD);

    // Occlusion sums.
    ZPassPair pairs[3] = {{kZPassValid | 10, kZPassValid | 110}, {kZPassValid, kZPassValid}, {kZPassValid | 5, 0}};
    bool valid;
    CHECK(SumZPass(pairs, 3, valid) == 100 && !valid);
    pairs[2] = {kZPassValid | 5, kZPassValid | 6};
    CHECK(SumZPass(pairs, 3, valid) == 101 && valid);

    // SET_PREDICATION fields and state.
    const u32 sp[] = {0x1000, 0x12 | (1u << 8) | (1u << 12) | (1u << 16) | (1u << 31)};
    const SetPredication p = ParseSetPredication(sp);
    CHECK(p.address == (0x12ull << 32 | 0x1000));
    CHECK(p.op == 1 && p.draw_if_visible && p.no_wait && p.continue_);
    Predication pred;
    CHECK(!pred.Skips());
    pred.Set({0, 1, true, false, false}, false);
    CHECK(pred.Skips());
    pred.Set({0, 1, true, false, true}, true); // continue: OR
    CHECK(!pred.Skips());
    pred.Set({0, 1, false, false, false}, false); // draw when not visible
    CHECK(!pred.Skips());
    pred.Clear();
    CHECK(!pred.enabled && !pred.Skips());

    // Stream-out update.
    const u32 so[] = {1 | (2u << 1) | (3u << 8), 0x2000 | 0, 0x7, 0x3000, 0x8};
    const StrmoutUpdate u = ParseStrmoutUpdate(so);
    CHECK(u.store_filled_size && u.source == StrmoutSource::Memory && u.buffer == 3);
    CHECK(u.dst_address == (0x7ull << 32 | 0x2000) && u.src_address == (0x8ull << 32 | 0x3000));

    // Coherence ranges: 256-byte units, 40-bit halves.
    CoherRange c = DecodeCoherRange(0x10, 0, 0x20, 0);
    CHECK(c.base == 0x2000 && c.size == 0x1000 && !c.everything);
    c = DecodeCoherRange(0xFFFFFFFF, 0xFF, 0, 0);
    CHECK(c.everything && c.size == ~0ull);
    c = DecodeCoherRange(1, 1, 0, 2);
    CHECK(c.base == (2ull << 32) << 8 && c.size == ((1ull << 32) | 1) << 8);
    CHECK(CoherPublishesGpuWrites(kCohCbAction) && CoherPublishesGpuWrites(kCohDbAction) && !CoherPublishesGpuWrites(kCohTcAction));
    CHECK(CoherInvalidatesReaders(kCohTcAction) && !CoherInvalidatesReaders(0));

    // COND_WRITE layout.
    const u32 cw[] = {3 | (1u << 4) | (1u << 8), 0x100, 0x1, 7, 0xFF, 0x200, 0x2, 99};
    const CondWrite w = ParseCondWrite(cw);
    CHECK(w.function == 3 && w.poll_memory && w.write_memory && w.poll_address == 0x100000100ull && w.reference == 7 &&
          w.mask == 0xFF && w.write_address == 0x200000200ull && w.data == 99);

    // Names.
    char scratch[24];
    CHECK(std::strcmp(OpcodeName(0x1E, scratch), "ATOMIC") == 0);
    CHECK(std::strcmp(OpcodeName(0xAB, scratch), "opcode 0xab") == 0);

    if (failures == 0) std::puts("pm4_exec: ok");
    return failures ? 1 : 0;
}
