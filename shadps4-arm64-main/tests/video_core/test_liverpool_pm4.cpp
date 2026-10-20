// The real liverpool.cpp (built against the stub headers of liverpool_stubs/, which stand in for the
// parts of the emulator it only calls into) driven with hand-made PM4 packets: the packets the
// command processor executes by itself, predication, occlusion plumbing, no abort on unknown
// opcodes. Standalone (no gtest): exit code 0 = pass. See tests/CMakeLists.txt (shadps4_liverpool_pm4_test).
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <coroutine>
#include <cstdio>
#include <cstring>
#include <deque>
#include <exception>
#include <functional>
#include <mutex>
#include <queue>
#include <semaphore>
#include <span>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <sys/mman.h>

#define private public
#include "video_core/amdgpu/liverpool.h"
#undef private
#include "platform/visionos/vpkengine_census.h"
#include "video_core/amdgpu/game_clock.h"
#include "video_core/amdgpu/pm4_cmds.h"
#include "video_core/rasterizer_interface.h"

// ---- what liverpool.cpp links against ---------------------------------------------------------
namespace Common {
void SetCurrentThreadName(const char*) {}
}
namespace AmdGpu::GameClock {
u64 GpuClock64() { return 0x1122334455667788ull; }
u64 PerfCounter() { return 0x42; }
void NoteStamp(const void*, u64, bool) {}
void OnFrameDone() {}
} // namespace AmdGpu::GameClock

using namespace AmdGpu;

namespace {

int failures = 0;
#define CHECK(c)                                                                                   \
    do {                                                                                           \
        if (!(c)) {                                                                                \
            std::fprintf(stderr, "%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, #c);             \
            ++failures;                                                                            \
        }                                                                                          \
    } while (0)

struct Mock final : VideoCore::RasterizerInterface {
    std::vector<std::string> calls;
    u32 draws = 0, dispatches = 0;
    bool zpass_handled = false;
    bool results_final = true;
    struct Sync {
        VAddr addr;
        u64 size;
        bool wait;
    };
    std::vector<Sync> syncs;
    struct Coh {
        VAddr base;
        u64 size;
        u32 cntl;
    };
    std::vector<Coh> coherence;
    std::vector<std::pair<VAddr, u32>> zpass;
    std::array<u32, 64> gds{};

    void Draw(bool, u32) override { ++draws; }
    void DrawIndirect(bool, VAddr, u32, u32, u32, VAddr) override { ++draws; }
    void DispatchDirect() override { ++dispatches; }
    void DispatchIndirect(VAddr, u32, u32) override { ++dispatches; }
    void ScopeMarkerBegin(const std::string_view&, bool) override {}
    void ScopeMarkerEnd(bool) override {}
    void ScopedMarkerInsert(const std::string_view&, bool) override {}
    void ScopedMarkerInsertColor(const std::string_view&, const u32, bool) override {}
    void FillBuffer(VAddr a, u32 n, u32 v, bool gds_) override {
        calls.push_back("fill " + std::to_string(a) + " " + std::to_string(n) + " " + std::to_string(v) + (gds_ ? " gds" : ""));
        if (gds_ && a / 4 < gds.size()) gds[a / 4] = v;
    }
    void CopyBuffer(VAddr d, VAddr s, u32 n, bool dg, bool sg) override {
        calls.push_back("copy " + std::to_string(d) + " " + std::to_string(s) + " " + std::to_string(n) + (dg ? " dgds" : "") + (sg ? " sgds" : ""));
    }
    u32 ReadDataFromGds(u32 o) override { return gds[o / 4 % gds.size()]; }
    bool InvalidateMemory(VAddr, u64) override { return false; }
    bool ReadMemory(VAddr, u64) override { return false; }
    bool IsMapped(VAddr, u64) override { return true; }
    void MapMemory(VAddr, u64) override {}
    void UnmapMemory(VAddr, u64) override {}
    void CpSync() override {}
    u64 Flush() override { return 0; }
    void Finish() override { calls.push_back("finish"); }
    void OnSubmit() override {}
    bool ZPassDone(VAddr a, u32 pairs) override {
        zpass.push_back({a, pairs});
        return zpass_handled;
    }
    bool SyncGpuWrites(VAddr a, u64 n, bool wait) override {
        syncs.push_back({a, n, wait});
        return results_final;
    }
    void OnCoherencePoint(VAddr b, u64 n, u32 c) override { coherence.push_back({b, n, c}); }
    // Labels the way the real renderer takes them: queued, written when the test says the GPU is done.
    bool defer_labels = false;
    struct Label {
        void* address;
        u64 value;
        u32 size;
        bool has_then;
        std::function<void()> then;
    };
    std::vector<Label> labels;
    int label_calls = 0;
    void ScheduleLabelWrite(void* address, u64 value, u32 size, std::function<void()> then) override {
        ++label_calls;
        if (!defer_labels) {
            VideoCore::RasterizerInterface::ScheduleLabelWrite(address, value, size, std::move(then));
            return;
        }
        labels.push_back({address, value, size, bool(then), std::move(then)});
    }
    void gpuDone() {
        for (auto& l : labels) {
            if (l.address) VideoCore::WriteGuestLabel(l.address, l.value, l.size);
            if (l.then) l.then();
        }
        labels.clear();
    }
};

// A type-3 packet: header + body.
std::vector<u32> pkt(u32 opcode, std::vector<u32> body, bool predicate = false) {
    std::vector<u32> p;
    p.push_back((3u << 30) | ((u32(body.size()) - 1) << 16) | (opcode << 8) | (predicate ? 1u : 0u));
    p.insert(p.end(), body.begin(), body.end());
    return p;
}

struct Fixture {
    Liverpool lp;
    Mock mock;
    // Guest addresses in PM4 packets are 40 bits: the memory sits at a fixed low address.
    u32* mem_base = nullptr;
    struct Mem {
        u32* base;
        u32& operator[](size_t i) { return base[i]; }
        u32* data() { return base; }
    } mem{};
    Fixture() {
        mem_base = static_cast<u32*>(mmap(reinterpret_cast<void*>(0x2000000000ull), 1 << 20, PROT_READ | PROT_WRITE,
                                          MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0));
        CHECK(mem_base != MAP_FAILED);
        mem.base = mem_base;
        lp.BindRasterizer(&mock);
        lp.regs.SetDefaults();
        lp.num_counter_pairs = 8;
    }
    ~Fixture() { munmap(mem_base, 1 << 20); }
    u64 addr(size_t dword) { return reinterpret_cast<u64>(&mem[dword]); }
    // Runs packets on the gfx ring until the stream is consumed.
    void gfx(const std::vector<std::vector<u32>>& packets) {
        std::vector<u32> all;
        for (const auto& p : packets) all.insert(all.end(), p.begin(), p.end());
        auto task = lp.ProcessGraphics(all, {});
        int guard = 0;
        while (!task.handle.done() && guard++ < 1000) task.handle.resume();
        CHECK(task.handle.done());
        task.handle.destroy();
    }
    Liverpool::Pm4Result exec(const std::vector<u32>& p, Liverpool::Pm4Engine e = Liverpool::Pm4Engine::Gfx) {
        return lp.ExecPacket(reinterpret_cast<const PM4Header*>(p.data()), e, 0);
    }
};

u32 lo(u64 a) { return u32(a); }
u32 hi(u64 a) { return u32(a >> 32); }

void atomics() {
    Fixture f;
    f.mem[4] = 5;
    // ATOMIC_ADD_RTN_32 (9): mem += 3, old value kept for COPY_DATA.
    f.exec(pkt(0x1E, {9, lo(f.addr(4)), hi(f.addr(4)), 3, 0, 0, 0, 0}));
    CHECK(f.mem[4] == 8 && f.lp.last_atomic_return == 5);
    // 64-bit SUB (RTN_64 = 39 + 3 = 42).
    f.mem[8] = 100;
    f.mem[9] = 0;
    f.exec(pkt(0x1E, {42, lo(f.addr(8)), hi(f.addr(8)), 30, 0, 0, 0, 0}));
    CHECK(f.mem[8] == 70 && f.lp.last_atomic_return == 100);
    // Non-returning forms (+64) do the same.
    f.exec(pkt(0x1E, {73, lo(f.addr(4)), hi(f.addr(4)), 1, 0, 0, 0, 0}));
    CHECK(f.mem[4] == 9);
    // CMPSWAP single pass: fails, memory untouched; succeeds.
    CHECK(f.exec(pkt(0x1E, {8, lo(f.addr(4)), hi(f.addr(4)), 77, 0, 1234, 0, 0})) == Liverpool::Pm4Result::Done);
    CHECK(f.mem[4] == 9);
    f.exec(pkt(0x1E, {8, lo(f.addr(4)), hi(f.addr(4)), 77, 0, 9, 0, 0}));
    CHECK(f.mem[4] == 77);
    // Loop mode: waits (Retry) until the comparison holds.
    const auto spin = pkt(0x1E, {8 | (1u << 8), lo(f.addr(4)), hi(f.addr(4)), 1, 0, 50, 0, 0});
    CHECK(f.exec(spin) == Liverpool::Pm4Result::Retry);
    f.mem[4] = 50;
    CHECK(f.exec(spin) == Liverpool::Pm4Result::Done && f.mem[4] == 1);
    // Floating point forms are counted, not executed.
    f.exec(pkt(0x1E, {2, lo(f.addr(4)), hi(f.addr(4)), 0, 0, 0, 0, 0}));
    CHECK(f.mem[4] == 1);
}

void registers() {
    Fixture f;
    const u32 reg = Regs::ContextRegWordOffset + 0x100;
    f.lp.regs.reg_array[reg] = 0xAABBCCDD;
    f.exec(pkt(0x21, {reg, 0xFFFF00FF, 0x00001200}));
    CHECK(f.lp.regs.reg_array[reg] == 0xAABB12DD);
    // AND mask taken from a register (bit 30).
    f.lp.regs.reg_array[reg + 1] = 0xFFFF0000;
    f.exec(pkt(0x21, {reg | (1u << 30), reg + 1, 0}));
    CHECK(f.lp.regs.reg_array[reg] == 0xAABB0000);
    // CONTEXT_REG_RMW: only the masked bits change.
    f.exec(pkt(0x51, {0x100, 0x0000FF00, 0x12345678}));
    CHECK(f.lp.regs.reg_array[reg] == 0xAABB5600);
    // A register outside the file is counted, not touched.
    f.exec(pkt(0x21, {0xFFFF, 0, 1}));
    // Compute SH registers reach the queue's compute state: COMPUTE_DIM_X = 0x2E01.
    f.exec(pkt(0x21, {0x2E01, 0, 77}));
    CHECK(f.lp.mapped_queues[0].cs_state.dim_x == 77);
}

void loadsAndWrites() {
    Fixture f;
    // LOAD_CONTEXT_REG: 3 dwords from memory into registers from context offset 0x20.
    f.mem[16] = 11;
    f.mem[17] = 22;
    f.mem[18] = 33;
    f.exec(pkt(0x61, {lo(f.addr(16)), hi(f.addr(16)), 0x20, 3}));
    CHECK(f.lp.regs.reg_array[Regs::ContextRegWordOffset + 0x20] == 11);
    CHECK(f.lp.regs.reg_array[Regs::ContextRegWordOffset + 0x22] == 33);
    // LOAD_SH_REG into the compute registers (SH offset 0x200 = COMPUTE_DISPATCH_INITIATOR).
    f.exec(pkt(0x5F, {lo(f.addr(16)), hi(f.addr(16)), 0x201, 2}));
    CHECK(f.lp.mapped_queues[0].cs_state.dim_x == 11 && f.lp.mapped_queues[0].cs_state.dim_y == 22);
    // LOAD_CONFIG_REG / LOAD_UCONFIG_REG land in their spaces.
    f.exec(pkt(0x60, {lo(f.addr(16)), hi(f.addr(16)), 5, 1}));
    CHECK(f.lp.regs.reg_array[Regs::ConfigRegWordOffset + 5] == 11);
    f.exec(pkt(0x5E, {lo(f.addr(16)), hi(f.addr(16)), 6, 1}));
    CHECK(f.lp.regs.reg_array[Regs::UconfigRegWordOffset + 6] == 11);
    // WRITE_DATA to a register (DST_SEL 0), and WR_ONE_ADDR to memory.
    f.exec(pkt(0x37, {0, 0xA123, 0, 0xCAFE}));
    CHECK(f.lp.regs.reg_array[0xA123] == 0xCAFE);
    f.exec(pkt(0x37, {(2u << 8) | (1u << 16), lo(f.addr(30)), hi(f.addr(30)), 1, 2, 3}));
    CHECK(f.mem[30] == 3);
    // LOAD_CONST_RAM: 4 dwords to constant RAM byte offset 0x40.
    f.mem[40] = 0x01020304;
    f.mem[41] = 0x05060708;
    f.exec(pkt(0x80, {lo(f.addr(40)), hi(f.addr(40)), 2, 0x40}));
    u32 got;
    std::memcpy(&got, f.lp.cblock.constants_heap.data() + 0x40, 4);
    CHECK(got == 0x01020304);
    // Out of range is refused.
    f.exec(pkt(0x80, {lo(f.addr(40)), hi(f.addr(40)), 100, 0xFFF0}));
}

void condWriteAndCopyData() {
    Fixture f;
    f.mem[50] = 7;
    // COND_WRITE: if (mem[50] & 0xFF) == 7 write 99 to mem[51].
    f.exec(pkt(0x45, {3 | (1u << 4) | (1u << 8), lo(f.addr(50)), hi(f.addr(50)), 7, 0xFF, lo(f.addr(51)), hi(f.addr(51)), 99}));
    CHECK(f.mem[51] == 99);
    f.exec(pkt(0x45, {4 | (1u << 4) | (1u << 8), lo(f.addr(50)), hi(f.addr(50)), 7, 0xFF, lo(f.addr(52)), hi(f.addr(52)), 98}));
    CHECK(f.mem[52] == 0);
    // COPY_DATA: immediate -> memory (32 and 64 bit), register -> memory, memory -> register,
    // GPU clock -> memory, atomic return -> memory.
    f.exec(pkt(0x40, {5 | (5u << 8), 0x12345678, 0, lo(f.addr(60)), hi(f.addr(60))}));
    CHECK(f.mem[60] == 0x12345678);
    f.exec(pkt(0x40, {5 | (5u << 8) | (1u << 16), 0xAAAA5555, 0xBBBB6666, lo(f.addr(62)), hi(f.addr(62))}));
    CHECK(f.mem[62] == 0xAAAA5555 && f.mem[63] == 0xBBBB6666);
    f.lp.regs.reg_array[0xA0A0] = 0x600D;
    f.exec(pkt(0x40, {0 | (1u << 8), 0xA0A0, 0, lo(f.addr(64)), hi(f.addr(64))}));
    CHECK(f.mem[64] == 0x600D);
    f.mem[66] = 0x1337;
    f.exec(pkt(0x40, {1 | (0u << 8), lo(f.addr(66)), hi(f.addr(66)), 0xA0A1, 0}));
    CHECK(f.lp.regs.reg_array[0xA0A1] == 0x1337);
    f.exec(pkt(0x40, {9 | (5u << 8) | (1u << 16), 0, 0, lo(f.addr(68)), hi(f.addr(68))}));
    CHECK(f.mem[68] == 0x55667788 && f.mem[69] == 0x11223344);
    f.lp.last_atomic_return = 0xFEEDu;
    f.exec(pkt(0x40, {6 | (5u << 8), 0, 0, lo(f.addr(70)), hi(f.addr(70))}));
    CHECK(f.mem[70] == 0xFEED);
    // GDS destination.
    f.exec(pkt(0x40, {5 | (3u << 8), 0xD00D, 0, 8, 0}));
    CHECK(f.mock.gds[2] == 0xD00D);
}

void dmaAndSync() {
    Fixture f;
    // CP_DMA (0x41): memory -> memory of 16 bytes.
    const u64 src = f.addr(100), dst = f.addr(120);
    f.exec(pkt(0x41, {lo(src), hi(src), lo(dst), hi(dst), 16}));
    CHECK(f.mock.calls.size() == 1 && f.mock.calls[0] == "copy " + std::to_string(dst) + " " + std::to_string(src) + " 16");
    // CP_DMA data -> memory fill (SRC_SEL 2 at bits 30:29).
    f.mock.calls.clear();
    f.exec(pkt(0x41, {0xABCD, (2u << 29) | hi(src), lo(dst), hi(dst), 8}));
    CHECK(f.mock.calls.size() == 1 && f.mock.calls[0] == "fill " + std::to_string(dst) + " 8 43981");
    // SURFACE_SYNC: base/size in 256-byte units.
    f.exec(pkt(0x43, {Pm4::kCohCbAction, 0x10, 0x20, 4}));
    CHECK(f.mock.coherence.size() == 1);
    CHECK(f.mock.coherence[0].base == 0x2000 && f.mock.coherence[0].size == 0x1000);
    // ACQUIRE_MEM with the 40-bit halves; everything.
    f.exec(pkt(0x58, {Pm4::kCohTcAction, 0xFFFFFFFF, 0xFF, 0, 0, 10}));
    CHECK(f.mock.coherence.size() == 2 && f.mock.coherence[1].size == ~0ull);
}

void releaseMemAndEvents() {
    Fixture f;
    // RELEASE_MEM on the gfx ring: data_sel None + interrupt only must not abort; data 32 writes.
    f.exec(pkt(0x49, {0x5, (1u << 24), 0, 0, 0, 0}));
    f.exec(pkt(0x49, {0x5, (2u << 24) | (1u << 29), lo(f.addr(5)), hi(f.addr(5)), 0xABCD, 0}));
    CHECK(f.mem[5] == 0xABCD);
    f.exec(pkt(0x49, {0x5, (2u << 29), lo(f.addr(6)), hi(f.addr(6)), 0x11, 0x22}));
    CHECK(f.mem[6] == 0x11 && f.mem[7] == 0x22);
}

void releaseMemIsScheduledOnTheGfxRing() {
    Fixture f;
    f.mock.defer_labels = true;
    f.mem[5] = 0;
    f.mem[6] = 0;
    // Two labels in order, plus interrupt-only (IrqOnly) and no-data/no-interrupt forms: none of them
    // may abort, and the data is not written until the GPU is done with the work before it.
    f.exec(pkt(0x49, {0x5, (2u << 24) | (1u << 29), lo(f.addr(5)), hi(f.addr(5)), 0xABCD, 0}));
    f.exec(pkt(0x49, {0x5, (1u << 24), 0, 0, 0, 0}));       // IrqOnly, no data
    f.exec(pkt(0x49, {0x5, 0, 0, 0, 0, 0}));                 // nothing at all
    f.exec(pkt(0x49, {0x5, (3u << 24) | (1u << 29), lo(f.addr(6)), hi(f.addr(6)), 0x77, 0}));
    CHECK(f.mem[5] == 0 && f.mem[6] == 0);
    CHECK(f.mock.labels.size() == 3);
    CHECK(f.mock.labels[0].address == &f.mem[5] && f.mock.labels[0].size == 4);
    CHECK(f.mock.labels[1].address == nullptr && f.mock.labels[1].has_then);
    f.mock.gpuDone();
    CHECK(f.mem[5] == 0xABCD && f.mem[6] == 0x77);
    // Census gets the unknown selectors instead of an abort.
    Census::SetPeriodSeconds(0);
    Census::ResetForTests();
    f.exec(pkt(0x49, {0x5, (6u << 29), lo(f.addr(8)), hi(f.addr(8)), 1, 0}));
    bool seen = false;
    for (const auto& e : Census::Snapshot()) seen |= e.key == "RELEASE_MEM data_sel unsupported";
    CHECK(seen);
}

void writeDataShortBody() {
    Fixture f;
    f.mem[30] = 0x1234;
    // count = 0 and 1 (no address / no data): used to wrap `count - 2` and write ~4G dwords.
    f.exec(pkt(0x37, {0}));
    f.exec(pkt(0x37, {(2u << 8), lo(f.addr(30))}));
    f.gfx({pkt(0x37, {(2u << 8) | (1u << 16)})});
    f.gfx({pkt(0x37, {(2u << 8)})});
    f.exec(pkt(0x37, {(2u << 8), lo(f.addr(30)), hi(f.addr(30))}));  // zero data dwords
    CHECK(f.mem[30] == 0x1234);
}

void cpReadsSyncWithTheGpu() {
    Fixture f;
    // A label the GPU has not written yet: every packet that reads guest memory asks first.
    const auto synced = [&](u64 a) {
        for (const auto& s : f.mock.syncs)
            if (s.addr == a && s.wait) return true;
        return false;
    };
    f.exec(pkt(0x40, {5 | (5u << 8) | (0u << 16), 0, 0, 0, 0}));  // immediate: no read
    CHECK(f.mock.syncs.empty());
    f.exec(pkt(0x40, {5 | (0u << 8) | (0u << 16), 0, 0, 0, 0}));
    f.mock.syncs.clear();
    f.exec(pkt(0x40, {1 | (0u << 8), lo(f.addr(66)), hi(f.addr(66)), 0xA0A1, 0}));  // memory -> register
    CHECK(synced(f.addr(66)));
    f.mock.syncs.clear();
    f.exec(pkt(0x45, {3 | (1u << 4) | (1u << 8), lo(f.addr(50)), hi(f.addr(50)), 7, 0xFF, lo(f.addr(51)), hi(f.addr(51)), 99}));
    CHECK(synced(f.addr(50)));
    f.mock.syncs.clear();
    f.exec(pkt(0x1E, {9, lo(f.addr(4)), hi(f.addr(4)), 3, 0, 0, 0, 0}));
    CHECK(synced(f.addr(4)));
    f.mock.syncs.clear();
    f.exec(pkt(0x61, {lo(f.addr(16)), hi(f.addr(16)), 0x20, 3}));
    CHECK(synced(f.addr(16)));
}

void unknownOpcodes() {
    Census::SetPeriodSeconds(0);
    Census::ResetForTests();
    Fixture f;
    // The 18 opcodes that used to abort, plus a made-up one: all run to completion.
    const u32 ops[] = {0x1D, 0x1E, 0x1F, 0x21, 0x23, 0x30, 0x41, 0x43, 0x45, 0x49, 0x4A, 0x51,
                       0x5F, 0x60, 0x61, 0x73, 0x77, 0x80, 0xFE};
    for (u32 op : ops) {
        std::vector<u32> body(10, 0);
        f.gfx({pkt(op, body)});
    }
    // And on the other engines.
    for (auto e : {Liverpool::Pm4Engine::Ce, Liverpool::Pm4Engine::Asc}) f.exec(pkt(0xFE, {1, 2, 3}), e);
    bool seen = false;
    for (const auto& e : Census::Snapshot()) seen |= e.category == "pm4" && e.key == "opcode 0xfe";
    CHECK(seen);
    bool atomicGds = false;
    for (const auto& e : Census::Snapshot()) atomicGds |= e.key == "ATOMIC_GDS" && !e.detail.empty();
    CHECK(atomicGds);
}

void strmout() {
    Fixture f;
    // Offset from the packet; store the filled size (0: nothing was streamed out) to memory.
    f.mem[80] = 0xFFFF;
    f.exec(pkt(0x34, {1 | (0u << 1) | (2u << 8), lo(f.addr(80)), hi(f.addr(80)), 0x40, 0}));
    CHECK(f.lp.strmout_offset[2] == 0x40 && f.mem[80] == 0);
    // Offset from memory.
    f.mem[82] = 0x99;
    f.exec(pkt(0x34, {(2u << 1) | (1u << 8), 0, 0, lo(f.addr(82)), hi(f.addr(82))}));
    CHECK(f.lp.strmout_offset[1] == 0x99);
}

void occlusionAndPredication() {
    Fixture f;
    // ZPASS_DONE (EVENT_WRITE type 21 index 1): given to the renderer when it counts, else fake.
    const u64 q = f.addr(200);
    f.gfx({pkt(0x46, {21 | (1u << 8), lo(q), hi(q)})});
    CHECK(f.mock.zpass.size() == 1 && f.mock.zpass[0].first == q && f.mock.zpass[0].second == 8);
    CHECK((f.mem[201] & 0x80000000u) != 0); // fake counter written: begin slot has the valid bit
    f.mock.zpass_handled = true;
    std::memset(f.mem.data() + 200, 0, 256);
    f.gfx({pkt(0x46, {57 | (1u << 8), lo(q), hi(q)})});
    CHECK(f.mock.zpass.size() == 2 && f.mem[201] == 0); // the renderer writes it, not the CP

    // OCCLUSION_QUERY: sum of end - begin over the 8 pairs (pair 0: 100 samples, pair 3: 5).
    auto* pairs = reinterpret_cast<u64*>(&f.mem[200]);
    for (int i = 0; i < 8; ++i) pairs[2 * i] = pairs[2 * i + 1] = Pm4::kZPassValid;
    pairs[1] += 100;
    pairs[7] += 5;
    const u64 out = f.addr(400);
    f.exec(pkt(0x1F, {lo(q), hi(q), lo(out), hi(out)}));
    u64 total;
    std::memcpy(&total, &f.mem[400], 8);
    CHECK(total == 105);
    CHECK(f.mock.syncs.size() == 1 && f.mock.syncs[0].wait && f.mock.syncs[0].size == 8 * 16);

    // SET_PREDICATION on the results: draws with the predicate bit run only if visible (PRED_BOOL=1).
    const u32 draw[] = {1, 0};
    auto visibleDraw = [&](bool predicated) { return pkt(0x2D, {draw[0], draw[1]}, predicated); };
    auto setPred = [&](u32 op, u64 where, u32 flags) { return pkt(0x20, {lo(where), hi(where) | (op << 16) | flags}); };
    f.mock.draws = 0;
    f.gfx({setPred(1, q, 1u << 8), visibleDraw(true), visibleDraw(false)});
    CHECK(f.mock.draws == 2); // samples passed: both run
    for (int i = 0; i < 8; ++i) pairs[2 * i + 1] = pairs[2 * i]; // nothing passed
    f.mock.draws = 0;
    f.gfx({setPred(1, q, 1u << 8), visibleDraw(true), visibleDraw(false)});
    CHECK(f.mock.draws == 1); // the predicated one is skipped, the plain one runs
    // PRED_BOOL = 0: draw when NOT visible.
    f.mock.draws = 0;
    f.gfx({setPred(1, q, 0), visibleDraw(true)});
    CHECK(f.mock.draws == 1);
    // Cleared again, and per submission.
    f.mock.draws = 0;
    f.gfx({setPred(1, q, 1u << 8), setPred(0, 0, 0), visibleDraw(true)});
    CHECK(f.mock.draws == 1);
    f.gfx({setPred(1, q, 1u << 8)});
    f.gfx({visibleDraw(true)});
    CHECK(f.mock.draws == 2); // the next submission starts with predication off
    // NO_WAIT hint with results not final: drawn.
    f.mock.results_final = false;
    f.mock.draws = 0;
    f.gfx({setPred(1, q, (1u << 8) | (1u << 12)), visibleDraw(true)});
    CHECK(f.mock.draws == 1 && !f.mock.syncs.back().wait);
    f.mock.results_final = true;
    // BOOL64 predicate.
    f.mem[300] = 0;
    f.mem[301] = 0;
    f.mock.draws = 0;
    f.gfx({setPred(3, f.addr(300), 1u << 8), visibleDraw(true)});
    CHECK(f.mock.draws == 0);
    f.mem[300] = 5;
    f.gfx({setPred(3, f.addr(300), 1u << 8), visibleDraw(true)});
    CHECK(f.mock.draws == 1);
    // CONTINUE combines with OR.
    f.mem[300] = 0;
    f.mem[302] = 1;
    f.mock.draws = 0;
    f.gfx({setPred(3, f.addr(300), 1u << 8), setPred(3, f.addr(302), (1u << 8) | (1u << 31)), visibleDraw(true)});
    CHECK(f.mock.draws == 1);
}

void multiAutoAndMisc() {
    Fixture f;
    f.gfx({pkt(0x30, {6, 2}), pkt(0x30, {6, 2, 0, 0})});
    CHECK(f.mock.draws == 2 && f.lp.regs.num_indices == 6);
    // SET_BASE with a base that nothing uses.
    f.gfx({pkt(0x11, {3, 0, 0})});
    // Compute ring: the common packets run there too (no abort, unlike before).
    f.mem[500] = 4;
    f.exec(pkt(0x1E, {9, lo(f.addr(500)), hi(f.addr(500)), 1, 0, 0, 0, 0}), Liverpool::Pm4Engine::Asc);
    CHECK(f.mem[500] == 5);
}

// PA_SC_GENERIC_SCISSOR_TL: WINDOW_OFFSET_DISABLE is bit 31, TL_Y [30:16], TL_X [14:0].
void scissorWindowOffsetDisableBit() {
    AmdGpu::ViewportScissor v;
    std::memset(&v, 0, sizeof(v));
    v.window_offset_disable = 1;
    u32 w[2];
    std::memcpy(w, &v, sizeof(w));
    CHECK(w[0] == 0x80000000u && w[1] == 0);
}

} // namespace

int main() {
    scissorWindowOffsetDisableBit();
    atomics();
    registers();
    loadsAndWrites();
    condWriteAndCopyData();
    dmaAndSync();
    releaseMemAndEvents();
    releaseMemIsScheduledOnTheGfxRing();
    writeDataShortBody();
    cpReadsSyncWithTheGpu();
    strmout();
    occlusionAndPredication();
    multiAutoAndMisc();
    unknownOpcodes();
    if (failures == 0) std::puts("liverpool pm4: ok");
    return failures ? 1 : 0;
}
