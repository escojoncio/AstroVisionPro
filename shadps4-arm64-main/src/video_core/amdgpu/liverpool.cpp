// SPDX-FileCopyrightText: Copyright 2024-2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <algorithm>
#include <chrono>
#include <cstring>
#include <mutex>
#include <thread>

#include <boost/preprocessor/stringize.hpp>
#include <magic_enum/magic_enum.hpp>

#include "common/assert.h"
#include "common/debug.h"
#include "common/polyfill_thread.h"
#include "common/thread.h"
#include "core/debug_state.h"
#include "core/emulator_settings.h"
#include "core/libraries/hmd/hmd.h"
#include "core/libraries/kernel/process.h"
#include "common/logging/log.h"
#include "core/libraries/videoout/driver.h"
#include "core/memory.h"
#include "core/platform.h"
#include "video_core/amdgpu/liverpool.h"
#include "video_core/amdgpu/pm4_cmds.h"
#include "video_core/amdgpu/pm4_exec.h"
#include "video_core/amdgpu/pm4_packet.h"
#include "video_core/amdgpu/pm4_type0.h"
#include "video_core/amdgpu/pm4_type1.h"
#include "video_core/amdgpu/stall_log.h"
#include "platform/visionos/vpkengine_census.h"
#include "video_core/renderdoc.h"
#include "video_core/renderer_vulkan/vk_rasterizer.h"
#include "video_core/renderer_vulkan/vk_scheduler.h"

namespace AmdGpu {

static void MaybeRecordVideoOutLabelLock(Libraries::VideoOut::VideoOutPort* vo_port, u64* address,
                                         const void* data, u32 data_size) {
    if (vo_port == nullptr || address == nullptr || !vo_port->IsVoLabel(address)) {
        return;
    }
    u64 value = 0;
    std::memcpy(&value, data, std::min<size_t>(data_size, sizeof(value)));
    if (value != 1) {
        return;
    }
    std::scoped_lock lock{vo_port->port_mutex};
    vo_port->flip_labels.RecordGpuLock(vo_port->LabelIndex(address));
}

/// A label write (and interrupt) of EVENT_WRITE_EOP / EOS / RELEASE_MEM: done when the GPU has
/// finished the work before it (the renderer decides), at once without a renderer.
static void ScheduleLabel(VideoCore::RasterizerInterface* rasterizer, void* address, u64 value,
                          u32 size, std::function<void()> then) {
    if (rasterizer) {
        rasterizer->ScheduleLabelWrite(address, value, size, std::move(then));
        return;
    }
    if (address) {
        VideoCore::WriteGuestLabel(address, value, size);
    }
    if (then) {
        then();
    }
}

/// A WAIT_REG_MEM keeps failing: after a short spin the thread blocks on the GPU frame that makes
/// the value (or sleeps briefly when nothing on the GPU does) instead of burning the core; the
/// other queues still run between looks (the caller yields).
static void WaitRegMemIdle(VideoCore::RasterizerInterface* rasterizer,
                           const PM4CmdWaitRegMem* wait, u64 looks) {
    if (looks < 64 || wait->mem_space.Value() != PM4CmdWaitRegMem::MemSpace::Memory) {
        return;
    }
    if (rasterizer && rasterizer->IdleLabelWait(wait->Address<const void*>(), 4)) {
        return;
    }
    std::this_thread::sleep_for(std::chrono::microseconds{looks < 4096 ? 20 : 200});
}

/// The command processor is about to read guest memory [address, +size): a label write that the
/// GPU has not made yet (or occlusion results) must be final first, or the packet reads a value
/// the real command processor would already see. Waits for exactly what touches the range.
static void SyncCpRead(VideoCore::RasterizerInterface* rasterizer, u64 address, u64 size) {
    if (rasterizer && address != 0) {
        rasterizer->SyncGpuWrites(address, size, true);
    }
}

/// IT_WRITE_DATA to memory, ordered with the GPU work that touches it.
static void WriteDataToMemory(VideoCore::RasterizerInterface* rasterizer, void* address,
                              const void* data, u32 size) {
    if (rasterizer) {
        rasterizer->WriteDataOrdered(address, data, size);
    } else {
        std::memcpy(address, data, size);
    }
}

static const char* dcb_task_name{"DCB_TASK"};
static const char* ccb_task_name{"CCB_TASK"};

#define MAX_NAMES 56
static_assert(Liverpool::NumComputeRings <= MAX_NAMES);

#define NAME_NUM(z, n, name) BOOST_PP_STRINGIZE(name) BOOST_PP_STRINGIZE(n),
#define NAME_ARRAY(name, num) {BOOST_PP_REPEAT(num, NAME_NUM, name)}

static const char* acb_task_name[] = NAME_ARRAY(ACB_TASK, MAX_NAMES);

#define YIELD(name)                                                                                \
    FIBER_EXIT;                                                                                    \
    co_yield {};                                                                                   \
    FIBER_ENTER(name);

#define YIELD_CE() YIELD(ccb_task_name)
#define YIELD_GFX() YIELD(dcb_task_name)
#define YIELD_ASC(id) YIELD(acb_task_name[id])

#define RESUME(task, name)                                                                         \
    FIBER_EXIT;                                                                                    \
    task.handle.resume();                                                                          \
    FIBER_ENTER(name);

#define RESUME_CE(task) RESUME(task, ccb_task_name)
#define RESUME_GFX(task) RESUME(task, dcb_task_name)
#define RESUME_ASC(task, id) RESUME(task, acb_task_name[id])

std::array<u8, 48_KB> Liverpool::ConstantEngine::constants_heap;

static std::span<const u32> NextPacket(std::span<const u32> span, size_t offset) {
    if (offset > span.size()) {
        LOG_ERROR(
            Lib_GnmDriver,
            ": packet length exceeds remaining submission size. Packet dword count={}, remaining "
            "submission dwords={}",
            offset, span.size());
        // Return empty subspan so check for next packet bails out
        return {};
    }

    return span.subspan(offset);
}

Liverpool::Liverpool() {
    // The census (what the GPU emulation ignores or approximates) prints its summary into the log.
    Census::SetSink([](std::string_view line) { LOG_INFO(Render, "{}", line); });
    num_counter_pairs = Libraries::Kernel::sceKernelIsNeoMode() ? 16 : 8;
    process_thread = std::jthread{std::bind_front(&Liverpool::Process, this)};
}

Liverpool::~Liverpool() {
    process_thread.request_stop();
    process_thread.join();
}

void Liverpool::ProcessCommands() {
    // Process incoming commands with high priority
    while (num_commands) {
        Common::UniqueFunction<void> callback{};
        {
            std::scoped_lock lk{submit_mutex};
            callback = std::move(command_queue.front());
            command_queue.pop();
            --num_commands;
        }
        callback();
    }
}

void Liverpool::ReleaseAfterGfxLocked() {
    constexpr auto MostWait = std::chrono::milliseconds{50};
    const auto now = std::chrono::steady_clock::now();
    while (!after_gfx.empty() &&
           (after_gfx.front().target <= gfx_done || now - after_gfx.front().since > MostWait)) {
        if (after_gfx.front().target > gfx_done) {
            static bool told = false;
            if (!std::exchange(told, true)) {
                LOG_WARNING(Render_Vulkan, "A command waited 50 ms for the drawing submitted "
                                           "before it (a submission may wait for it): run now");
            }
        }
        command_queue.emplace(std::move(after_gfx.front().func));
        after_gfx.pop_front();
        ++num_commands;
    }
    has_after_gfx.store(!after_gfx.empty(), std::memory_order_relaxed);
}

void Liverpool::Process(std::stop_token stoken) {
    Common::SetCurrentThreadName("shadPS4:GpuCommandProcessor");
    gpu_id = std::this_thread::get_id();

    while (!stoken.stop_requested()) {
        {
            std::unique_lock lk{submit_mutex};
            Common::CondvarWait(submit_cv, lk, stoken,
                                [this] { return num_commands || num_submits || submit_done; });
        }
        if (stoken.stop_requested()) {
            break;
        }

        VideoCore::StartCapture();

        curr_qid = -1;

        while (num_submits || num_commands) {
            ProcessCommands();

            curr_qid = (curr_qid + 1) % num_mapped_queues;

            auto& queue = mapped_queues[curr_qid];

            Task::Handle task{};
            {
                std::scoped_lock lock{queue.m_access};
                if (queue.submits.empty()) {
                    continue;
                }
                task = queue.submits.front();
            }
            if (void* first = task.address();
                resync_task.load(std::memory_order_relaxed) == first &&
                resync_task.compare_exchange_strong(first, nullptr)) {
                // The first commands of a new frame: the title's clocks are back on real time
                // (automatic GPU clock, game_clock.h), before any of its stamps.
                GameClock::OnFrameDone();
            }
            in_gfx_task.store(true, std::memory_order_relaxed);
            task.resume();
            in_gfx_task.store(false, std::memory_order_relaxed);
#ifdef ENABLE_BACHATA_RUNTIME
            if (++debug_resume_count % 1'000 == 0) {
                LOG_WARNING(Render_Vulkan,
                            "GPU coroutine active resumes={} queue={} opcode={:#x} submits={}",
                            debug_resume_count, curr_qid, debug_last_opcode, num_submits.load());
            }
#endif

            if (task.done()) {
                task.destroy();

                std::scoped_lock lock{queue.m_access};
                queue.submits.pop();

                --num_submits;
                std::scoped_lock lock2{submit_mutex};
                if (curr_qid == static_cast<s32>(GfxQueueId)) {
                    ++gfx_done;
                }
                ReleaseAfterGfxLocked();
                submit_cv.notify_all();
            } else if (has_after_gfx.load(std::memory_order_relaxed)) {
                std::scoped_lock lock2{submit_mutex};
                ReleaseAfterGfxLocked();
            }
        }

        if (submit_done) {
            VideoCore::EndCapture();
            if (rasterizer) {
                rasterizer->OnSubmit();
                rasterizer->Flush();
            }
            submit_done = false;
        }

        Platform::IrqC::Instance()->Signal(Platform::InterruptId::GpuIdle);
    }
}

// ---- PM4 executor ------------------------------------------------------------------------------
//
// Packets the command processor executes by itself. The queue loops below keep their own cases
// (draws, dispatches, waits, indirect buffers, set-register packets, events); everything else
// lands in ExecPacket from their `default:`. Layouts: the gfx7 PM4 specification (see
// pm4_exec.h for the parts that are plain arithmetic and are unit tested).

namespace {

constexpr u32 kShRegBase = Regs::ShRegWordOffset;
constexpr u32 kCsRegBase = Regs::ShRegWordOffset + 0x200; // COMPUTE_* registers (SH space 0x200..)

u64 GuestAddress(u32 lo, u32 hi, u64 align_mask = ~0ull) {
    return (u64(lo) | u64(hi & 0xFFFF) << 32) & align_mask;
}

// A CP write into guest memory: the same path the end-of-pipe writes take.
void CpWriteMemory(void* address, const void* data, u64 size) {
    auto* memory = Core::Memory::Instance();
    if (!memory->TryWriteBacking(address, data, size)) {
        std::memcpy(address, data, size);
    }
}

bool CpReadable(u64 address, u64 size) {
    return address != 0 && address + size > address;
}

} // namespace

void Liverpool::NoteUnhandledPacket(Pm4Engine engine, const PM4Header* header, const char* why) {
    char scratch[24];
    const u32 opcode = u32(header->type3.opcode.Value());
    const char* name = Pm4::OpcodeName(opcode, scratch);
    const char* queue = engine == Pm4Engine::Gfx ? "gfx" : engine == Pm4Engine::Ce ? "ce" : "asc";
    // The raw words of the first packet of each opcode, for whoever implements it next.
    static std::array<bool, 256> described{};
    std::string detail;
    if (!described[opcode & 0xFF]) {
        described[opcode & 0xFF] = true;
        detail = fmt::format("{} {} count={} body:", queue, why, header->type3.count.Value());
        const auto* words = reinterpret_cast<const u32*>(header) + 1;
        for (u32 i = 0; i < std::min<u32>(header->type3.NumWords(), 10); ++i) {
            detail += fmt::format(" {:08x}", words[i]);
        }
    }
    Census::Note("pm4", name, detail);
}

u32* Liverpool::RegPtr(u32 mmio, u32 mapped_queue) {
    // The compute program registers (SH space 0x200..) are per queue.
    if (mmio >= kCsRegBase && mmio < kCsRegBase + sizeof(ComputeProgram) / 4) {
        return reinterpret_cast<u32*>(&mapped_queues[mapped_queue].cs_state) + (mmio - kCsRegBase);
    }
    return mmio < Regs::NumRegs ? &regs.reg_array[mmio] : nullptr;
}

void Liverpool::CoherencePoint(const Pm4::CoherRange& range, u32 coher_cntl) {
    if (rasterizer) {
        rasterizer->OnCoherencePoint(range.base, range.size, coher_cntl);
    }
}

void Liverpool::ExecDmaData(const PM4DmaData* dma_data) {
    if (dma_data->dst_addr_lo == 0x3022C || !rasterizer) {
        return;
    }
    const bool src_mem = dma_data->src_sel == DmaDataSrc::Memory ||
                         dma_data->src_sel == DmaDataSrc::MemoryUsingL2;
    const bool dst_mem = dma_data->dst_sel == DmaDataDst::Memory ||
                         dma_data->dst_sel == DmaDataDst::MemoryUsingL2;
    if (dma_data->src_sel == DmaDataSrc::Data && dma_data->dst_sel == DmaDataDst::Gds) {
        rasterizer->FillBuffer(dma_data->dst_addr_lo, dma_data->NumBytes(), dma_data->data, true);
    } else if (src_mem && dma_data->dst_sel == DmaDataDst::Gds) {
        rasterizer->CopyBuffer(dma_data->dst_addr_lo, dma_data->SrcAddress<VAddr>(),
                               dma_data->NumBytes(), true, false);
    } else if (dma_data->src_sel == DmaDataSrc::Data && dst_mem) {
        rasterizer->FillBuffer(dma_data->DstAddress<VAddr>(), dma_data->NumBytes(), dma_data->data,
                               false);
    } else if (dma_data->src_sel == DmaDataSrc::Gds && dst_mem) {
        rasterizer->CopyBuffer(dma_data->DstAddress<VAddr>(), dma_data->src_addr_lo,
                               dma_data->NumBytes(), false, true);
    } else if (src_mem && dst_mem) {
        rasterizer->CopyBuffer(dma_data->DstAddress<VAddr>(), dma_data->SrcAddress<VAddr>(),
                               dma_data->NumBytes(), false, false);
    } else if (dma_data->src_sel == DmaDataSrc::Gds && dma_data->dst_sel == DmaDataDst::Gds) {
        rasterizer->CopyBuffer(dma_data->dst_addr_lo, dma_data->src_addr_lo, dma_data->NumBytes(),
                               true, true);
    } else {
        Census::Note("pm4", "DMA_DATA selectors unsupported",
                     fmt::format("src_sel={} dst_sel={}", u32(dma_data->src_sel.Value()),
                                 u32(dma_data->dst_sel.Value())));
    }
}

void Liverpool::ExecWriteData(const PM4CmdWriteData* write_data, u32 mapped_queue) {
    // WRITE_DATA beyond the common "dword(s) to memory" form: DST_SEL 0 = register(s), 3 = GDS,
    // WR_ONE_ADDR = every dword goes to the same address (the last one stays).
    if (write_data->header.count.Value() < 2) {
        // Body shorter than control + address: no data, and count - 2 would wrap around.
        Census::Note("pm4", "WRITE_DATA malformed (body shorter than its header)",
                     std::to_string(write_data->header.count.Value()));
        return;
    }
    const u32 data_dwords = (write_data->header.count.Value() - 2);
    const u32 dst_sel = write_data->dst_sel.Value();
    const bool one_addr = write_data->wr_one_addr.Value();
    switch (dst_sel) {
    case 0: { // memory-mapped registers
        const u32 reg = write_data->dst_addr_lo & 0x3FFFF;
        for (u32 i = 0; i < data_dwords; ++i) {
            if (u32* slot = RegPtr(reg + (one_addr ? 0 : i), mapped_queue)) {
                *slot = write_data->data[i];
            } else {
                Census::Note("pm4", "WRITE_DATA register outside the register file",
                             fmt::format("reg={:#x}", reg + (one_addr ? 0 : i)));
            }
        }
        break;
    }
    case 1:
    case 2:
    case 5: { // memory
        const u64 address = write_data->addr64 & ~3ull;
        if (!CpReadable(address, 4)) {
            break;
        }
        if (one_addr) {
            if (data_dwords) {
                CpWriteMemory(reinterpret_cast<void*>(address), &write_data->data[data_dwords - 1], 4);
            }
        } else {
            CpWriteMemory(reinterpret_cast<void*>(address), write_data->data, data_dwords * 4);
        }
        break;
    }
    case 3: { // GDS
        if (rasterizer) {
            for (u32 i = 0; i < data_dwords; ++i) {
                rasterizer->FillBuffer(u32(write_data->dst_addr_lo) + (one_addr ? 0 : i * 4), 4,
                                       write_data->data[i], true);
            }
        }
        break;
    }
    default:
        Census::Note("pm4", "WRITE_DATA dst_sel unsupported", std::to_string(dst_sel));
        break;
    }
}

void Liverpool::ExecCopyData(const PM4CmdCopyData* copy, u32 mapped_queue) {
    const bool wide = copy->count_sel.Value() != 0;
    u64 value = 0;
    bool have = true;
    switch (copy->src_sel.Value()) {
    case CopyDataSrc::MappedRegister: {
        const u32 reg = copy->src_addr_lo & 0x3FFFF;
        const u32* lo = RegPtr(reg, mapped_queue);
        const u32* hi = wide ? RegPtr(reg + 1, mapped_queue) : nullptr;
        if (!lo) {
            Census::Note("pm4", "COPY_DATA register source outside the register file",
                         fmt::format("reg={:#x}", reg));
            have = false;
            break;
        }
        value = *lo | (hi ? u64(*hi) << 32 : 0);
        break;
    }
    case CopyDataSrc::Memory:
    case CopyDataSrc::TCL2: {
        const u64 address = copy->SrcAddress<u64>() & ~3ull;
        if (!CpReadable(address, wide ? 8 : 4)) {
            have = false;
            break;
        }
        SyncCpRead(rasterizer, address, wide ? 8 : 4);
        std::memcpy(&value, reinterpret_cast<const void*>(address), wide ? 8 : 4);
        break;
    }
    case CopyDataSrc::Gds: {
        if (!rasterizer) {
            have = false;
            break;
        }
        rasterizer->Finish(); // GDS is the renderer's: its GPU work is done first
        const u32 offset = copy->src_addr_lo;
        value = rasterizer->ReadDataFromGds(offset);
        if (wide) {
            value |= u64(rasterizer->ReadDataFromGds(offset + 4)) << 32;
        }
        break;
    }
    case CopyDataSrc::Immediate:
        value = wide ? (u64(copy->src_addr_lo) | u64(copy->src_addr_hi) << 32) : copy->src_addr_lo;
        break;
    case CopyDataSrc::Atomic:
        value = last_atomic_return;
        break;
    case CopyDataSrc::GpuClock:
        value = GetGpuClock64();
        break;
    case CopyDataSrc::PerfCounters:
        value = GetGpuPerfCounter();
        break;
    default:
        Census::Note("pm4", "COPY_DATA src_sel unsupported",
                     std::to_string(u32(copy->src_sel.Value())));
        have = false;
        break;
    }
    if (!have) {
        return;
    }
    if (!wide) {
        value = u32(value);
    }
    switch (copy->dst_sel.Value()) {
    case CopyDataDst::MappedRegister: {
        const u32 reg = copy->dst_addr_lo & 0x3FFFF;
        if (u32* lo = RegPtr(reg, mapped_queue)) {
            *lo = u32(value);
            if (wide) {
                if (u32* hi = RegPtr(reg + 1, mapped_queue)) {
                    *hi = u32(value >> 32);
                }
            }
        } else {
            Census::Note("pm4", "COPY_DATA register destination outside the register file",
                         fmt::format("reg={:#x}", reg));
        }
        break;
    }
    case CopyDataDst::MemorySync:
    case CopyDataDst::MemoryAsync:
    case CopyDataDst::TCL2: {
        const u64 address = copy->DstAddress<u64>() & ~3ull;
        if (CpReadable(address, wide ? 8 : 4)) {
            SyncCpRead(rasterizer, address, wide ? 8 : 4);
            CpWriteMemory(reinterpret_cast<void*>(address), &value, wide ? 8 : 4);
        }
        break;
    }
    case CopyDataDst::Gds:
        if (rasterizer) {
            rasterizer->FillBuffer(copy->dst_addr_lo, 4, u32(value), true);
            if (wide) {
                rasterizer->FillBuffer(copy->dst_addr_lo + 4, 4, u32(value >> 32), true);
            }
        }
        break;
    default:
        Census::Note("pm4", "COPY_DATA dst_sel unsupported", std::to_string(u32(copy->dst_sel.Value())));
        break;
    }
}

void Liverpool::ExecLoadRegs(const u32* body, u32 body_dwords, u32 base, u32 mapped_queue) {
    // LOAD_*_REG: DW1 ADDR_LO, DW2 ADDR_HI[15:0] (| WAIT_IDLE[31]), DW3 REG_OFFSET, DW4 NUM_DWORDS:
    // consecutive dwords of memory into consecutive registers.
    if (body_dwords < 4) {
        Census::Note("pm4", "LOAD_*_REG malformed", std::to_string(body_dwords));
        return;
    }
    const u64 address = GuestAddress(body[0] & ~3u, body[1]);
    const u32 first = base + (body[2] & 0xFFFF);
    const u32 count = std::min<u32>(body[3] & 0x3FFF, 0x4000);
    if (!CpReadable(address, count * 4ull)) {
        return;
    }
    SyncCpRead(rasterizer, address, count * 4ull);
    const auto* src = reinterpret_cast<const u32*>(address);
    for (u32 i = 0; i < count; ++i) {
        if (u32* slot = RegPtr(first + i, mapped_queue)) {
            *slot = src[i];
        }
    }
}

void Liverpool::ExecSetPredication(const PM4Header* header) {
    const auto* body = reinterpret_cast<const u32*>(header) + 1;
    if (header->type3.NumWords() < 2) {
        Census::Note("pm4", "SET_PREDICATION malformed");
        return;
    }
    const Pm4::SetPredication p = Pm4::ParseSetPredication(body);
    if (p.op == u32(Pm4::PredicationOp::Clear)) {
        predication.Clear();
        return;
    }
    bool visible = true;
    switch (p.op) {
    case u32(Pm4::PredicationOp::ZPass): {
        const u32 pairs = num_counter_pairs;
        const u64 bytes = pairs * sizeof(Pm4::ZPassPair);
        if (!CpReadable(p.address, bytes)) {
            break;
        }
        // NO_WAIT: the draw goes ahead when the GPU has not produced the result yet.
        const bool final = rasterizer ? rasterizer->SyncGpuWrites(p.address, bytes, !p.no_wait) : true;
        if (!final) {
            Census::Note("predication", "ZPASS result not ready: drawn (NO_WAIT hint)");
            break;
        }
        const auto* results = reinterpret_cast<const Pm4::ZPassPair*>(p.address);
        bool all_valid = true;
        visible = Pm4::SumZPass(results, pairs, all_valid) != 0;
        if (!all_valid) {
            Census::Note("predication", "ZPASS result never written: treated as the written ones");
        }
        break;
    }
    case u32(Pm4::PredicationOp::Bool64): {
        if (!CpReadable(p.address, 8)) {
            break;
        }
        if (rasterizer) {
            rasterizer->SyncGpuWrites(p.address, 8, !p.no_wait);
        }
        u64 value;
        std::memcpy(&value, reinterpret_cast<const void*>(p.address), 8);
        visible = value != 0;
        break;
    }
    case u32(Pm4::PredicationOp::Bool32): {
        if (!CpReadable(p.address, 4)) {
            break;
        }
        if (rasterizer) {
            rasterizer->SyncGpuWrites(p.address, 4, !p.no_wait);
        }
        u32 value;
        std::memcpy(&value, reinterpret_cast<const void*>(p.address), 4);
        visible = value != 0;
        break;
    }
    default:
        // PRIMCOUNT compares stream-out counters, which do not exist here: always visible.
        Census::Note("predication", "SET_PREDICATION op unsupported (draws kept)", std::to_string(p.op));
        break;
    }
    predication.Set(p, visible);
}

void Liverpool::ExecStrmoutBufferUpdate(const PM4Header* header) {
    if (header->type3.NumWords() < 5) {
        Census::Note("pm4", "STRMOUT_BUFFER_UPDATE malformed");
        return;
    }
    // Only the command processor's bookkeeping of the buffer offsets exists: stream-out itself
    // (vertex shader outputs written to buffers) is not executed, so every filled size is 0.
    const Pm4::StrmoutUpdate u = Pm4::ParseStrmoutUpdate(reinterpret_cast<const u32*>(header) + 1);
    switch (u.source) {
    case Pm4::StrmoutSource::Packet:
        strmout_offset[u.buffer] = u.packet_offset;
        break;
    case Pm4::StrmoutSource::FilledSize:
        strmout_offset[u.buffer] = strmout_filled[u.buffer];
        break;
    case Pm4::StrmoutSource::Memory:
        if (CpReadable(u.src_address, 4)) {
            SyncCpRead(rasterizer, u.src_address, 4);
            std::memcpy(&strmout_offset[u.buffer], reinterpret_cast<const void*>(u.src_address), 4);
        }
        break;
    case Pm4::StrmoutSource::None:
        break;
    }
    if (u.store_filled_size && CpReadable(u.dst_address, 4)) {
        CpWriteMemory(reinterpret_cast<void*>(u.dst_address), &strmout_filled[u.buffer], 4);
    }
    Census::Note("pm4", "STRMOUT_BUFFER_UPDATE bookkeeping only (stream-out not executed)");
}

Liverpool::Pm4Result Liverpool::ExecPacket(const PM4Header* header, Pm4Engine engine,
                                           u32 mapped_queue) {
    const PM4ItOpcode opcode = header->type3.opcode;
    const u32 n = header->type3.NumWords(); // body dwords
    const auto* body = reinterpret_cast<const u32*>(header) + 1;
    const auto malformed = [&] { NoteUnhandledPacket(engine, header, "body too short"); };

    switch (opcode) {
    case PM4ItOpcode::Atomic: {
        // ATOMIC_MEM: DW1 ATOMIC[6:0] (texture cache op) | COMMAND[11:8] (1 = loop until the
        // comparison holds), DW2/3 ADDRESS, DW4/5 SRC_DATA, DW6/7 CMP_DATA, DW8 LOOP_INTERVAL.
        if (n < 7) {
            malformed();
            break;
        }
        const Pm4::AtomicDecode op = Pm4::DecodeAtomic(body[0] & 0x7F);
        if (!op.valid) {
            NoteUnhandledPacket(engine, header, "ATOMIC op not decoded (floating point?)");
            break;
        }
        const u64 address = (u64(body[1]) | u64(body[2]) << 32) & (op.wide ? ~7ull : ~3ull);
        if (!CpReadable(address, op.wide ? 8 : 4)) {
            break;
        }
        SyncCpRead(rasterizer, address, op.wide ? 8 : 4);
        const u64 src = u64(body[3]) | u64(body[4]) << 32;
        const u64 cmp = u64(body[5]) | u64(body[6]) << 32;
        bool swapped = true;
        const u64 old = Pm4::ApplyAtomic(op, reinterpret_cast<void*>(address), src, cmp, swapped);
        last_atomic_return = old;
        if (!swapped && ((body[0] >> 8) & 0xF) == 1) {
            return Pm4Result::Retry; // loop mode: until the comparison is satisfied
        }
        break;
    }
    case PM4ItOpcode::AtomicGds:
        NoteUnhandledPacket(engine, header, "GDS atomics not executed (layout unverified)");
        break;
    case PM4ItOpcode::OcclusionQuery: {
        // DW1/2 START_ADDRESS (ZPASS_DONE results), DW3/4 QUERY_ADDRESS: the CP adds up end - begin
        // of every render backend and writes the 64-bit total.
        if (n < 4) {
            malformed();
            break;
        }
        const u64 start = GuestAddress(body[0] & ~7u, body[1]);
        const u64 query = GuestAddress(body[2] & ~7u, body[3]);
        const u32 pairs = num_counter_pairs;
        if (!CpReadable(start, pairs * sizeof(Pm4::ZPassPair)) || !CpReadable(query, 8)) {
            break;
        }
        if (rasterizer) {
            rasterizer->SyncGpuWrites(start, pairs * sizeof(Pm4::ZPassPair), true);
        }
        bool all_valid = true;
        const u64 total = Pm4::SumZPass(reinterpret_cast<const Pm4::ZPassPair*>(start), pairs, all_valid);
        if (!all_valid) {
            Census::Note("pm4", "OCCLUSION_QUERY results not all written");
        }
        CpWriteMemory(reinterpret_cast<void*>(query), &total, 8);
        break;
    }
    case PM4ItOpcode::RegRmw: {
        if (n < 3) {
            malformed();
            break;
        }
        const Pm4::RegRmw r = Pm4::ParseRegRmw(body);
        u32* reg = RegPtr(r.reg, mapped_queue);
        const u32* and_src = r.and_reg ? RegPtr(r.and_mask, mapped_queue) : nullptr;
        const u32* or_src = r.or_reg ? RegPtr(r.or_mask, mapped_queue) : nullptr;
        if (!reg || (r.and_reg && !and_src) || (r.or_reg && !or_src)) {
            Census::Note("pm4", "REG_RMW register outside the register file",
                         fmt::format("reg={:#x}", r.reg));
            break;
        }
        *reg = Pm4::ApplyRegRmw(*reg, and_src ? *and_src : r.and_mask, or_src ? *or_src : r.or_mask);
        break;
    }
    case PM4ItOpcode::ContextRegRmw: {
        if (n < 3) {
            malformed();
            break;
        }
        u32* reg = RegPtr(Regs::ContextRegWordOffset + (body[0] & 0xFFFF), mapped_queue);
        if (reg) {
            *reg = Pm4::ApplyContextRegRmw(*reg, body[1], body[2]);
        }
        break;
    }
    case PM4ItOpcode::PredExec:
        // Executes the packets that follow only while the predicate holds. The size field of this
        // packet is not verified against hardware, and skipping a wrong number of dwords would
        // desynchronise the stream: they are executed.
        NoteUnhandledPacket(engine, header, "executed unconditionally (layout unverified)");
        break;
    case PM4ItOpcode::CommandProcessorDma: {
        // CP_DMA: DMA_DATA without the leading control dword (its selects sit in DW2).
        if (n < 5) {
            malformed();
            break;
        }
        const std::array<u32, 7> as_dma_data{header->raw, body[1] & ~0xFFFFu, body[0], body[1] & 0xFFFFu,
                                             body[2],      body[3] & 0xFFFFu, body[4]};
        ExecDmaData(reinterpret_cast<const PM4DmaData*>(as_dma_data.data()));
        break;
    }
    case PM4ItOpcode::DmaData:
        ExecDmaData(reinterpret_cast<const PM4DmaData*>(header));
        break;
    case PM4ItOpcode::SurfaceSync: {
        // DW1 CP_COHER_CNTL, DW2 CP_COHER_SIZE, DW3 CP_COHER_BASE (256-byte units), DW4 POLL_INTERVAL.
        if (n < 3) {
            malformed();
            break;
        }
        CoherencePoint(Pm4::DecodeCoherRange(body[1], 0, body[2], 0), body[0]);
        break;
    }
    case PM4ItOpcode::AcquireMem: {
        if (n < 5) {
            malformed();
            break;
        }
        CoherencePoint(Pm4::DecodeCoherRange(body[1], body[2], body[3], body[4]), body[0]);
        break;
    }
    case PM4ItOpcode::CondWrite: {
        if (n < 8) {
            malformed();
            break;
        }
        const Pm4::CondWrite c = Pm4::ParseCondWrite(body);
        u32 value = 0;
        if (c.poll_memory) {
            const u64 address = c.poll_address & ~3ull;
            if (!CpReadable(address, 4)) {
                break;
            }
            SyncCpRead(rasterizer, address, 4);
            std::memcpy(&value, reinterpret_cast<const void*>(address), 4);
        } else if (const u32* reg = RegPtr(u32(c.poll_address & 0x3FFFF), mapped_queue)) {
            value = *reg;
        }
        if (!Pm4::CompareFunction(c.function, value & c.mask, c.reference)) {
            break;
        }
        if (c.write_memory) {
            const u64 address = c.write_address & ~3ull;
            if (CpReadable(address, 4)) {
                SyncCpRead(rasterizer, address, 4);
                CpWriteMemory(reinterpret_cast<void*>(address), &c.data, 4);
            }
        } else if (u32* reg = RegPtr(u32(c.write_address & 0x3FFFF), mapped_queue)) {
            *reg = c.data;
        }
        break;
    }
    case PM4ItOpcode::PreambleCntl:
    case PM4ItOpcode::SwitchBuffer:
    case PM4ItOpcode::DrawPreamble:
        // State-shadowing / double-buffering markers of the real command processor: nothing to
        // execute here.
        {
            char scratch[24];
            Census::Note("pm4-noop", Pm4::OpcodeName(u32(opcode), scratch));
        }
        break;
    case PM4ItOpcode::LoadShReg:
        ExecLoadRegs(body, n, kShRegBase, mapped_queue);
        break;
    case PM4ItOpcode::LoadConfigReg:
        ExecLoadRegs(body, n, Regs::ConfigRegWordOffset, mapped_queue);
        break;
    case PM4ItOpcode::LoadContextReg:
        ExecLoadRegs(body, n, Regs::ContextRegWordOffset, mapped_queue);
        break;
    case PM4ItOpcode::LoadUconfigReg:
        ExecLoadRegs(body, n, Regs::UconfigRegWordOffset, mapped_queue);
        break;
    case PM4ItOpcode::SetShRegIndex: {
        // SET_SH_REG with an INDEX field (the high bits of the offset dword).
        if (n < 2) {
            malformed();
            break;
        }
        const u32 first = kShRegBase + (body[0] & 0xFFFF);
        for (u32 i = 0; i + 1 < n; ++i) {
            if (u32* slot = RegPtr(first + i, mapped_queue)) {
                *slot = body[1 + i];
            }
        }
        break;
    }
    case PM4ItOpcode::SetContextRegIndirect:
        NoteUnhandledPacket(engine, header, "indirect register set not executed (layout unverified)");
        break;
    case PM4ItOpcode::SetShRegOffset:
        NoteUnhandledPacket(engine, header, "SH register set from offset not executed (layout unverified)");
        break;
    case PM4ItOpcode::LoadConstRam: {
        // DW1/2 ADDRESS, DW3 NUM_DW[14:0], DW4 START_ADDR[15:0] (byte offset in the constant RAM).
        if (n < 4) {
            malformed();
            break;
        }
        const u64 address = GuestAddress(body[0] & ~3u, body[1]);
        const u32 bytes = (body[2] & 0x7FFF) * 4;
        const u32 offset = body[3] & 0xFFFF;
        if (!CpReadable(address, bytes) || u64(offset) + bytes > cblock.constants_heap.size()) {
            Census::Note("pm4", "LOAD_CONST_RAM outside the constant RAM", fmt::format("offset={:#x} bytes={:#x}", offset, bytes));
            break;
        }
        SyncCpRead(rasterizer, address, bytes);
        std::memcpy(cblock.constants_heap.data() + offset, reinterpret_cast<const void*>(address), bytes);
        break;
    }
    case PM4ItOpcode::CopyData:
        ExecCopyData(reinterpret_cast<const PM4CmdCopyData*>(header), mapped_queue);
        break;
    case PM4ItOpcode::WriteData:
        ExecWriteData(reinterpret_cast<const PM4CmdWriteData*>(header), mapped_queue);
        break;
    case PM4ItOpcode::SetPredication:
        ExecSetPredication(header);
        break;
    case PM4ItOpcode::StrmoutBufferUpdate:
        ExecStrmoutBufferUpdate(header);
        break;
    case PM4ItOpcode::ReleaseMem: {
        // The gfx ring's version of EVENT_WRITE_EOP (compute rings handle it inline).
        const auto* release_mem = reinterpret_cast<const PM4CmdReleaseMem*>(header);
        // The data and the interrupt are the GPU's, in order with the labels queued before it
        // (the same path as EVENT_WRITE_EOP and the compute ring's RELEASE_MEM).
        release_mem->SignalFenceScheduled(
            [this](void* address, u64 value, u32 size, std::function<void()> then) {
                ScheduleLabel(rasterizer, address, value, size, std::move(then));
            },
            [] { Platform::IrqC::Instance()->Signal(Platform::InterruptId::GfxEop); },
            [this](VAddr dst, u16 gds_index, u16 num_dwords) {
                if (rasterizer) {
                    rasterizer->CopyBuffer(dst, gds_index, num_dwords * sizeof(u32), false, true);
                }
            });
        break;
    }
    case PM4ItOpcode::GetLodStats:
        NoteUnhandledPacket(engine, header, "texture LOD statistics not produced");
        break;
    case PM4ItOpcode::SetQueueReg:
        NoteUnhandledPacket(engine, header, "queue register write ignored");
        break;
    default:
        NoteUnhandledPacket(engine, header, "unknown opcode skipped");
        break;
    }
    return Pm4Result::Done;
}

Liverpool::Task Liverpool::ProcessCeUpdate(std::span<const u32> ccb) {
    FIBER_ENTER(ccb_task_name);

    while (!ccb.empty()) {
        ProcessCommands();

        const auto* header = reinterpret_cast<const PM4Header*>(ccb.data());
        const u32 type = header->type;
        if (!Pm4PacketFits(ccb)) {
            LOG_ERROR(Lib_GnmDriver,
                      "CE PM4 packet exceeds remaining submission. type={} size={} remaining={}",
                      type, Pm4PacketDwords(header->raw), ccb.size());
            break;
        }
        if (type == 2) {
            ccb = NextPacket(ccb, 1);
            continue;
        }
        if (type == 0) {
            const auto type0 = ConsumePm4Type0(ccb, regs.reg_array);
            if (!type0.consumed) {
                LOG_ERROR(Lib_GnmDriver,
                          "CE PM4 type 0 exceeds remaining submission. size={} remaining={}",
                          header->type0.NumWords(), ccb.size());
                break;
            }
            LOG_WARNING(Lib_GnmDriver, "CE PM4 type 0 register write base={} size={} written={}",
                        header->type0.base.Value(), header->type0.NumWords(), type0.words_written);
            ccb = NextPacket(ccb, type0.packet_dwords);
            continue;
        }
        if (type == 1) {
            const auto type1 = ConsumePm4Type1(ccb, regs.reg_array);
            if (!type1.consumed) {
                LOG_ERROR(Lib_GnmDriver,
                          "CE PM4 type 1 exceeds remaining submission. remaining={}", ccb.size());
                break;
            }
            LOG_WARNING(Lib_GnmDriver, "CE PM4 type 1 register write a={} b={} written={}",
                        Pm4Type1RegA(header->raw), Pm4Type1RegB(header->raw), type1.words_written);
            ccb = NextPacket(ccb, type1.packet_dwords);
            continue;
        }
        if (type != 3) {
            LOG_ERROR(Lib_GnmDriver, "CE invalid PM4 type {} — skipping remainder", type);
            break;
        }

        const PM4ItOpcode opcode = header->type3.opcode;
#ifdef ENABLE_BACHATA_RUNTIME
        debug_last_opcode = static_cast<u32>(opcode);
#endif
        const auto* it_body = reinterpret_cast<const u32*>(header) + 1;
        switch (opcode) {
        case PM4ItOpcode::Nop: {
            // const auto* nop = reinterpret_cast<const PM4CmdNop*>(header);
            break;
        }
        case PM4ItOpcode::WriteConstRam: {
            const auto* write_const = reinterpret_cast<const PM4WriteConstRam*>(header);
            memcpy(cblock.constants_heap.data() + write_const->Offset(), &write_const->data,
                   write_const->Size());
            break;
        }
        case PM4ItOpcode::DumpConstRam: {
            const auto* dump_const = reinterpret_cast<const PM4DumpConstRam*>(header);
            memcpy(dump_const->Address<void*>(),
                   cblock.constants_heap.data() + dump_const->Offset(), dump_const->Size());
            break;
        }
        case PM4ItOpcode::IncrementCeCounter: {
            ++cblock.ce_count;
            break;
        }
        case PM4ItOpcode::WaitOnDeCounterDiff: {
            const u32 diff = it_body[0];
            u64 wdecd_iters = 0;
            while ((cblock.de_count - cblock.ce_count) >= diff) {
                YIELD_CE();
#ifdef ENABLE_BACHATA_RUNTIME
                if (ShouldLogStallIteration(++wdecd_iters)) {
                    LOG_WARNING(Render_Vulkan,
                                "PM4 WAIT_ON_DE_COUNTER_DIFF stalled (CE) iterations={} diff={} "
                                "ce_count={} de_count={}",
                                wdecd_iters, diff, cblock.ce_count, cblock.de_count);
                }
#endif
            }
            break;
        }
        case PM4ItOpcode::IndirectBufferConst: {
            const auto* indirect_buffer = reinterpret_cast<const PM4CmdIndirectBuffer*>(header);
            if (!Pm4IndirectBufferUsable(indirect_buffer->Address<const u32>(),
                                         indirect_buffer->ib_size)) {
                LOG_ERROR(Lib_GnmDriver, "CE IT_INDIRECT_BUFFER_CONST skipped: addr={} size={}",
                          fmt::ptr(indirect_buffer->Address<const u32>()),
                          indirect_buffer->ib_size.Value());
                break;
            }
            auto task =
                ProcessCeUpdate({indirect_buffer->Address<const u32>(), indirect_buffer->ib_size});
            RESUME_CE(task);

            while (!task.handle.done()) {
                YIELD_CE();
                RESUME_CE(task);
            }
            break;
        }
        default: {
            // Anything else is executed by the common PM4 executor (never an abort).
            while (ExecPacket(header, Pm4Engine::Ce, GfxQueueId) == Pm4Result::Retry) {
                YIELD_CE();
            }
            break;
        }
        }
        ccb = NextPacket(ccb, header->type3.NumWords() + 1);
    }

    FIBER_EXIT;
}

Liverpool::Task Liverpool::ProcessGraphics(std::span<const u32> dcb, std::span<const u32> ccb,
                                           bool nested) {
    FIBER_ENTER(dcb_task_name);

    cblock.Reset();
    if (!nested) {
        // Predication is per submission: whatever the previous one left on is over.
        predication.Clear();
    }

    // TODO: potentially, ASCs also can depend on CE and in this case the
    // CE task should be moved into more global scope
    Task ce_task{};

    if (!ccb.empty()) {
        // In case of CCB provided kick off CE asap to have the constant heap ready to use
        ce_task = ProcessCeUpdate(ccb);
        RESUME_GFX(ce_task);
    }
    const bool host_markers_enabled = rasterizer && EmulatorSettings.IsVkHostMarkersEnabled();
    const bool guest_markers_enabled = rasterizer && EmulatorSettings.IsVkGuestMarkersEnabled();

    const auto base_addr = reinterpret_cast<uintptr_t>(dcb.data());
    while (!dcb.empty()) {
        ProcessCommands();

        const auto* header = reinterpret_cast<const PM4Header*>(dcb.data());
        const u32 type = header->type;
        if (!Pm4PacketFits(dcb)) {
            LOG_ERROR(Lib_GnmDriver,
                      "PM4 packet exceeds remaining submission. type={} size={} remaining={}", type,
                      Pm4PacketDwords(header->raw), dcb.size());
            break;
        }

        switch (type) {
        default:
            LOG_ERROR(Lib_GnmDriver, "Wrong PM4 type {} — skipping remainder", type);
            dcb = {};
            break;
        case 0: {
            const auto type0 = ConsumePm4Type0(dcb, regs.reg_array);
            if (!type0.consumed) {
                LOG_ERROR(Lib_GnmDriver,
                          "PM4 type 0 exceeds remaining submission. base={} size={} remaining={}",
                          header->type0.base.Value(), header->type0.NumWords(), dcb.size());
                dcb = {};
                break;
            }
            LOG_WARNING(Lib_GnmDriver, "PM4 type 0 register write base={} size={} written={}",
                        header->type0.base.Value(), header->type0.NumWords(), type0.words_written);
            dcb = NextPacket(dcb, type0.packet_dwords);
            continue;
        }
        case 1: {
            const auto type1 = ConsumePm4Type1(dcb, regs.reg_array);
            if (!type1.consumed) {
                LOG_ERROR(Lib_GnmDriver, "PM4 type 1 exceeds remaining submission. remaining={}",
                          dcb.size());
                dcb = {};
                break;
            }
            LOG_WARNING(Lib_GnmDriver, "PM4 type 1 register write a={} b={} written={}",
                        Pm4Type1RegA(header->raw), Pm4Type1RegB(header->raw), type1.words_written);
            dcb = NextPacket(dcb, type1.packet_dwords);
            continue;
        }
        case 2:
            // Type-2 packet are used for padding purposes
            dcb = NextPacket(dcb, 1);
            continue;
        case 3:
            const u32 count = header->type3.NumWords();
            const PM4ItOpcode opcode = header->type3.opcode;
#ifdef ENABLE_BACHATA_RUNTIME
            debug_last_opcode = static_cast<u32>(opcode);
#endif
            if (header->type3.predicate.Value() == PM4Predicate::PredEnable && predication.Skips() &&
                opcode != PM4ItOpcode::SetPredication) {
                // SET_PREDICATION said the draws are not visible: packets with the predicate bit
                // are not executed.
                char scratch[24];
                Census::Note("predication", Pm4::OpcodeName(static_cast<u32>(opcode), scratch));
                dcb = NextPacket(dcb, count + 1);
                continue;
            }
            switch (opcode) {
            case PM4ItOpcode::Nop: {
                const auto* nop = reinterpret_cast<const PM4CmdNop*>(header);
                if (nop->header.count.Value() == 0) {
                    break;
                }

                switch (nop->data_block[0]) {
                case PM4CmdNop::PayloadType::PatchedFlip: {
                    // There is no evidence that GPU CP drives flip events by parsing
                    // special NOP packets. For convenience lets assume that it does.
                    Platform::IrqC::Instance()->Signal(Platform::InterruptId::GfxFlip,
                                                       nop->data_block[1]);
                    break;
                }
                case PM4CmdNop::PayloadType::DebugMarkerPush: {
                    if (guest_markers_enabled) {
                        const auto marker_sz = nop->header.count.Value() * 2;
                        const std::string_view label{
                            reinterpret_cast<const char*>(&nop->data_block[1]), marker_sz};
                        rasterizer->ScopeMarkerBegin(label, true);
                    }
                    break;
                }
                case PM4CmdNop::PayloadType::DebugColorMarkerPush: {
                    if (guest_markers_enabled) {
                        const auto marker_sz = nop->header.count.Value() * 2;
                        const std::string_view label{
                            reinterpret_cast<const char*>(&nop->data_block[1]), marker_sz};
                        const u32 color = *reinterpret_cast<const u32*>(
                            reinterpret_cast<const u8*>(&nop->data_block[1]) + marker_sz);
                        rasterizer->ScopedMarkerInsertColor(label, color, true);
                    }
                    break;
                }
                case PM4CmdNop::PayloadType::DebugMarkerPop: {
                    if (guest_markers_enabled) {
                        rasterizer->ScopeMarkerEnd(true);
                    }
                    break;
                }
                default:
                    break;
                }
                break;
            }
            case PM4ItOpcode::ContextControl: {
                break;
            }
            case PM4ItOpcode::ClearState: {
                regs.SetDefaults();
                break;
            }
            case PM4ItOpcode::SetConfigReg: {
                const auto* set_data = reinterpret_cast<const PM4CmdSetData*>(header);
                const auto reg_addr = Regs::ConfigRegWordOffset + set_data->reg_offset;
                const auto* payload = reinterpret_cast<const u32*>(header + 2);
                std::memcpy(&regs.reg_array[reg_addr], payload, (count - 1) * sizeof(u32));
                break;
            }
            case PM4ItOpcode::SetContextReg: {
                const auto* set_data = reinterpret_cast<const PM4CmdSetData*>(header);
                const auto reg_addr = Regs::ContextRegWordOffset + set_data->reg_offset;
                const auto* payload = reinterpret_cast<const u32*>(header + 2);

                std::memcpy(&regs.reg_array[reg_addr], payload, (count - 1) * sizeof(u32));

                // In the case of HW, render target memory has alignment as color block operates on
                // tiles. There is no information of actual resource extents stored in CB context
                // regs, so any deduction of it from slices/pitch will lead to a larger surface
                // created. The same applies to the depth targets. Fortunately, the guest always
                // sends a trailing NOP packet right after the context regs setup, so we can use the
                // heuristic below and extract the hint to determine actual resource dims.

                switch (reg_addr) {
                case ContextRegs::CbColor0Base:
                case ContextRegs::CbColor1Base:
                case ContextRegs::CbColor2Base:
                case ContextRegs::CbColor3Base:
                case ContextRegs::CbColor4Base:
                case ContextRegs::CbColor5Base:
                case ContextRegs::CbColor6Base:
                case ContextRegs::CbColor7Base: {
                    const auto col_buf_id = (reg_addr - ContextRegs::CbColor0Base) /
                                            (ContextRegs::CbColor1Base - ContextRegs::CbColor0Base);
                    ASSERT(col_buf_id < NUM_COLOR_BUFFERS);

                    const auto nop_offset = header->type3.count;
                    if (nop_offset == 0x0e || nop_offset == 0x0d || nop_offset == 0x0b) {
                        ASSERT_MSG(payload[nop_offset] == 0xc0001000,
                                   "NOP hint is missing in CB setup sequence");
                        last_cb_extent[col_buf_id].raw = payload[nop_offset + 1];
                    } else {
                        last_cb_extent[col_buf_id].raw = 0;
                    }
                    break;
                }
                case ContextRegs::CbColor0Cmask:
                case ContextRegs::CbColor1Cmask:
                case ContextRegs::CbColor2Cmask:
                case ContextRegs::CbColor3Cmask:
                case ContextRegs::CbColor4Cmask:
                case ContextRegs::CbColor5Cmask:
                case ContextRegs::CbColor6Cmask:
                case ContextRegs::CbColor7Cmask: {
                    const auto col_buf_id =
                        (reg_addr - ContextRegs::CbColor0Cmask) /
                        (ContextRegs::CbColor1Cmask - ContextRegs::CbColor0Cmask);
                    ASSERT(col_buf_id < NUM_COLOR_BUFFERS);

                    const auto nop_offset = header->type3.count;
                    if (nop_offset == 0x04) {
                        ASSERT_MSG(payload[nop_offset] == 0xc0001000,
                                   "NOP hint is missing in CB setup sequence");
                        last_cb_extent[col_buf_id].raw = payload[nop_offset + 1];
                    }
                    break;
                }
                case ContextRegs::DbZInfo: {
                    if (header->type3.count == 8) {
                        ASSERT_MSG(payload[20] == 0xc0001000,
                                   "NOP hint is missing in DB setup sequence");
                        last_db_extent.raw = payload[21];
                    } else {
                        last_db_extent.raw = 0;
                    }
                    break;
                }
                default:
                    break;
                }
                break;
            }
            case PM4ItOpcode::SetShReg: {
                const auto* set_data = reinterpret_cast<const PM4CmdSetData*>(header);
                const auto set_size = (count - 1) * sizeof(u32);

                if (set_data->reg_offset >= 0x200 &&
                    set_data->reg_offset <= (0x200 + sizeof(ComputeProgram) / 4)) {
                    ASSERT(set_size <= sizeof(ComputeProgram));
                    auto* addr = reinterpret_cast<u32*>(&mapped_queues[GfxQueueId].cs_state) +
                                 (set_data->reg_offset - 0x200);
                    std::memcpy(addr, header + 2, set_size);
                } else {
                    std::memcpy(&regs.reg_array[Regs::ShRegWordOffset + set_data->reg_offset],
                                header + 2, set_size);
                }
                break;
            }
            case PM4ItOpcode::SetUconfigReg: {
                const auto* set_data = reinterpret_cast<const PM4CmdSetData*>(header);
                std::memcpy(&regs.reg_array[Regs::UconfigRegWordOffset + set_data->reg_offset],
                            header + 2, (count - 1) * sizeof(u32));
                break;
            }
            case PM4ItOpcode::IndexType: {
                const auto* index_type = reinterpret_cast<const PM4CmdDrawIndexType*>(header);
                regs.index_buffer_type.raw = index_type->raw;
                break;
            }
            case PM4ItOpcode::DrawIndex2: {
                const auto* draw_index = reinterpret_cast<const PM4CmdDrawIndex2*>(header);
                regs.max_index_size = draw_index->max_size;
                regs.index_base_address.base_addr_lo = draw_index->index_base_lo;
                regs.index_base_address.base_addr_hi = draw_index->index_base_hi;
                regs.num_indices = draw_index->index_count;
                regs.draw_initiator = draw_index->draw_initiator;
                if (DebugState.DumpingCurrentReg()) {
                    DebugState.PushRegsDump(base_addr, reinterpret_cast<uintptr_t>(header), regs);
                }
                if (rasterizer) {
                    const auto cmd_address = reinterpret_cast<const void*>(header);
                    if (host_markers_enabled) {
                        rasterizer->ScopeMarkerBegin(fmt::format("gfx:{}:DrawIndex2", cmd_address));
                        rasterizer->Draw(true);
                        rasterizer->ScopeMarkerEnd();
                    } else {
                        rasterizer->Draw(true);
                    }
                }
                break;
            }
            case PM4ItOpcode::DrawIndexOffset2: {
                const auto* draw_index_off =
                    reinterpret_cast<const PM4CmdDrawIndexOffset2*>(header);
                regs.max_index_size = draw_index_off->max_size;
                regs.num_indices = draw_index_off->index_count;
                regs.draw_initiator = draw_index_off->draw_initiator;
                if (DebugState.DumpingCurrentReg()) {
                    DebugState.PushRegsDump(base_addr, reinterpret_cast<uintptr_t>(header), regs);
                }
                if (rasterizer) {
                    const auto cmd_address = reinterpret_cast<const void*>(header);
                    if (host_markers_enabled) {
                        rasterizer->ScopeMarkerBegin(
                            fmt::format("gfx:{}:DrawIndexOffset2", cmd_address));
                        rasterizer->Draw(true, draw_index_off->index_offset);
                        rasterizer->ScopeMarkerEnd();
                    } else {
                        rasterizer->Draw(true, draw_index_off->index_offset);
                    }
                }
                break;
            }
            case PM4ItOpcode::DrawIndexAuto: {
                const auto* draw_index = reinterpret_cast<const PM4CmdDrawIndexAuto*>(header);
                regs.num_indices = draw_index->index_count;
                regs.draw_initiator = draw_index->draw_initiator;
                if (DebugState.DumpingCurrentReg()) {
                    DebugState.PushRegsDump(base_addr, reinterpret_cast<uintptr_t>(header), regs);
                }
                if (rasterizer) {
                    const auto cmd_address = reinterpret_cast<const void*>(header);
                    if (host_markers_enabled) {
                        rasterizer->ScopeMarkerBegin(
                            fmt::format("gfx:{}:DrawIndexAuto", cmd_address));
                        rasterizer->Draw(false);
                        rasterizer->ScopeMarkerEnd();
                    } else {
                        rasterizer->Draw(false);
                    }
                }
                break;
            }
            case PM4ItOpcode::DrawIndexMultiAuto: {
                // DW1 INDEX_COUNT, DW2 DRAW_INITIATOR (the rest of the body is not used by the
                // draw): an auto-indexed draw.
                if (count < 2) {
                    NoteUnhandledPacket(Pm4Engine::Gfx, header, "body too short");
                    break;
                }
                const auto* draw_index = reinterpret_cast<const PM4CmdDrawIndexAuto*>(header);
                regs.num_indices = draw_index->index_count;
                regs.draw_initiator = draw_index->draw_initiator;
                if (count > 2) {
                    NoteUnhandledPacket(Pm4Engine::Gfx, header, "extra dwords of the multi draw ignored");
                }
                if (DebugState.DumpingCurrentReg()) {
                    DebugState.PushRegsDump(base_addr, reinterpret_cast<uintptr_t>(header), regs);
                }
                if (rasterizer) {
                    rasterizer->Draw(false);
                }
                break;
            }
            case PM4ItOpcode::DrawIndirect: {
                const auto* draw_indirect = reinterpret_cast<const PM4CmdDrawIndirect*>(header);
                const auto offset = draw_indirect->data_offset;
                const auto stride = sizeof(DrawIndirectArgs);
                if (DebugState.DumpingCurrentReg()) {
                    DebugState.PushRegsDump(base_addr, reinterpret_cast<uintptr_t>(header), regs);
                }
                if (rasterizer) {
                    const auto cmd_address = reinterpret_cast<const void*>(header);
                    if (host_markers_enabled) {
                        rasterizer->ScopeMarkerBegin(
                            fmt::format("gfx:{}:DrawIndirect", cmd_address));
                        rasterizer->DrawIndirect(false, indirect_args_addr, offset, stride, 1, 0);
                        rasterizer->ScopeMarkerEnd();
                    } else {
                        rasterizer->DrawIndirect(false, indirect_args_addr, offset, stride, 1, 0);
                    }
                }
                break;
            }
            case PM4ItOpcode::DrawIndirectMulti: {
                const auto* draw_indirect =
                    reinterpret_cast<const PM4CmdDrawIndirectMulti*>(header);
                const auto offset = draw_indirect->data_offset;
                if (DebugState.DumpingCurrentReg()) {
                    DebugState.PushRegsDump(base_addr, reinterpret_cast<uintptr_t>(header), regs);
                }
                if (rasterizer) {
                    const auto cmd_address = reinterpret_cast<const void*>(header);
                    if (host_markers_enabled) {
                        rasterizer->ScopeMarkerBegin(
                            fmt::format("gfx:{}:DrawIndirectMulti", cmd_address));
                        rasterizer->DrawIndirect(false, indirect_args_addr, offset,
                                                 draw_indirect->stride, draw_indirect->count, 0);
                        rasterizer->ScopeMarkerEnd();
                    } else {
                        rasterizer->DrawIndirect(false, indirect_args_addr, offset,
                                                 draw_indirect->stride, draw_indirect->count, 0);
                    }
                }
                break;
            }
            case PM4ItOpcode::DrawIndexIndirect: {
                const auto* draw_index_indirect =
                    reinterpret_cast<const PM4CmdDrawIndexIndirect*>(header);
                const auto offset = draw_index_indirect->data_offset;
                const auto stride = sizeof(DrawIndexedIndirectArgs);
                if (DebugState.DumpingCurrentReg()) {
                    DebugState.PushRegsDump(base_addr, reinterpret_cast<uintptr_t>(header), regs);
                }
                if (rasterizer) {
                    const auto cmd_address = reinterpret_cast<const void*>(header);
                    if (host_markers_enabled) {
                        rasterizer->ScopeMarkerBegin(
                            fmt::format("gfx:{}:DrawIndexIndirect", cmd_address));
                        rasterizer->DrawIndirect(true, indirect_args_addr, offset, stride, 1, 0);
                        rasterizer->ScopeMarkerEnd();
                    } else {
                        rasterizer->DrawIndirect(true, indirect_args_addr, offset, stride, 1, 0);
                    }
                }
                break;
            }
            case PM4ItOpcode::DrawIndexIndirectMulti: {
                const auto* draw_index_indirect =
                    reinterpret_cast<const PM4CmdDrawIndexIndirectMulti*>(header);
                const auto offset = draw_index_indirect->data_offset;
                if (DebugState.DumpingCurrentReg()) {
                    DebugState.PushRegsDump(base_addr, reinterpret_cast<uintptr_t>(header), regs);
                }
                if (rasterizer) {
                    const auto cmd_address = reinterpret_cast<const void*>(header);
                    if (host_markers_enabled) {
                        rasterizer->ScopeMarkerBegin(
                            fmt::format("gfx:{}:DrawIndexIndirectMulti", cmd_address));
                        rasterizer->DrawIndirect(true, indirect_args_addr, offset,
                                                 draw_index_indirect->stride,
                                                 draw_index_indirect->count, 0);
                        rasterizer->ScopeMarkerEnd();
                    } else {
                        rasterizer->DrawIndirect(true, indirect_args_addr, offset,
                                                 draw_index_indirect->stride,
                                                 draw_index_indirect->count, 0);
                    }
                }
                break;
            }
            case PM4ItOpcode::DrawIndexIndirectCountMulti: {
                const auto* draw_index_indirect =
                    reinterpret_cast<const PM4CmdDrawIndexIndirectCountMulti*>(header);
                const auto offset = draw_index_indirect->data_offset;
                if (DebugState.DumpingCurrentReg()) {
                    DebugState.PushRegsDump(base_addr, reinterpret_cast<uintptr_t>(header), regs);
                }
                if (rasterizer) {
                    const auto cmd_address = reinterpret_cast<const void*>(header);
                    if (host_markers_enabled) {
                        rasterizer->ScopeMarkerBegin(
                            fmt::format("gfx:{}:DrawIndexIndirectCountMulti", cmd_address));
                        rasterizer->DrawIndirect(true, indirect_args_addr, offset,
                                                 draw_index_indirect->stride,
                                                 draw_index_indirect->count,
                                                 draw_index_indirect->count_indirect_enable.Value()
                                                     ? draw_index_indirect->count_addr
                                                     : 0);
                        rasterizer->ScopeMarkerEnd();
                    } else {
                        rasterizer->DrawIndirect(true, indirect_args_addr, offset,
                                                 draw_index_indirect->stride,
                                                 draw_index_indirect->count,
                                                 draw_index_indirect->count_indirect_enable.Value()
                                                     ? draw_index_indirect->count_addr
                                                     : 0);
                    }
                }
                break;
            }
            case PM4ItOpcode::DispatchDirect: {
                const auto* dispatch_direct = reinterpret_cast<const PM4CmdDispatchDirect*>(header);
                auto& cs_program = GetCsRegs();
                cs_program.dim_x = dispatch_direct->dim_x;
                cs_program.dim_y = dispatch_direct->dim_y;
                cs_program.dim_z = dispatch_direct->dim_z;
                cs_program.dispatch_initiator = dispatch_direct->dispatch_initiator;
                if (DebugState.DumpingCurrentReg()) {
                    DebugState.PushRegsDumpCompute(base_addr, reinterpret_cast<uintptr_t>(header),
                                                   cs_program);
                }
                if (rasterizer && (cs_program.dispatch_initiator & 1)) {
                    const auto cmd_address = reinterpret_cast<const void*>(header);
                    if (host_markers_enabled) {
                        rasterizer->ScopeMarkerBegin(
                            fmt::format("gfx:{}:DispatchDirect", cmd_address));
                        rasterizer->DispatchDirect();
                        rasterizer->ScopeMarkerEnd();
                    } else {
                        rasterizer->DispatchDirect();
                    }
                }
                break;
            }
            case PM4ItOpcode::DispatchIndirect: {
                const auto* dispatch_indirect =
                    reinterpret_cast<const PM4CmdDispatchIndirect*>(header);
                auto& cs_program = GetCsRegs();
                const auto offset = dispatch_indirect->data_offset;
                const auto size = sizeof(PM4CmdDispatchIndirect::GroupDimensions);
                if (DebugState.DumpingCurrentReg()) {
                    DebugState.PushRegsDumpCompute(base_addr, reinterpret_cast<uintptr_t>(header),
                                                   cs_program);
                }
                if (rasterizer && (cs_program.dispatch_initiator & 1)) {
                    const auto cmd_address = reinterpret_cast<const void*>(header);
                    if (host_markers_enabled) {
                        rasterizer->ScopeMarkerBegin(
                            fmt::format("gfx:{}:DispatchIndirect", cmd_address));
                        rasterizer->DispatchIndirect(indirect_args_addr, offset, size);
                        rasterizer->ScopeMarkerEnd();
                    } else {
                        rasterizer->DispatchIndirect(indirect_args_addr, offset, size);
                    }
                }
                break;
            }
            case PM4ItOpcode::NumInstances: {
                const auto* num_instances = reinterpret_cast<const PM4CmdDrawNumInstances*>(header);
                regs.num_instances.num_instances = num_instances->num_instances;
                break;
            }
            case PM4ItOpcode::IndexBase: {
                const auto* index_base = reinterpret_cast<const PM4CmdDrawIndexBase*>(header);
                regs.index_base_address.base_addr_lo = index_base->addr_lo;
                regs.index_base_address.base_addr_hi = index_base->addr_hi;
                break;
            }
            case PM4ItOpcode::IndexBufferSize: {
                const auto* index_size = reinterpret_cast<const PM4CmdDrawIndexBufferSize*>(header);
                regs.num_indices = index_size->num_indices;
                break;
            }
            case PM4ItOpcode::SetBase: {
                const auto* set_base = reinterpret_cast<const PM4CmdSetBase*>(header);
                if (set_base->base_index == PM4CmdSetBase::BaseIndex::DrawIndexIndirPatchTable) {
                    indirect_args_addr = set_base->Address<u64>();
                } else {
                    // Display list patch table, GDS / CE partition bases: nothing here uses them.
                    NoteUnhandledPacket(Pm4Engine::Gfx, header, "SET_BASE index not used");
                }
                break;
            }
            case PM4ItOpcode::EventWrite: {
                const auto* event = reinterpret_cast<const PM4CmdEventWrite*>(header);
                LOG_DEBUG(Render, "Encountered EventWrite: event_type = {}, event_index = {}",
                          magic_enum::enum_name(event->event_type.Value()),
                          magic_enum::enum_name(event->event_index.Value()));
                if (event->event_type.Value() == EventType::SoVgtStreamoutFlush) {
                    // TODO: handle proper synchronization, for now signal that update is done
                    // immediately
                    regs.cp_strmout_cntl.offset_update_done = 1;
                } else if (event->event_index.Value() == EventIndex::ZpassDone) {
                    if (event->event_type.Value() == EventType::PixelPipeStatDump ||
                        event->event_type.Value() == EventType::ZpassDone) {
                        // The depth blocks' pass counters sampled into guest memory: the renderer
                        // counts the samples that pass (occlusion queries) and writes them when its
                        // GPU gets here.
                        const VAddr results_address = event->Address<VAddr>();
                        if (!(rasterizer &&
                              rasterizer->ZPassDone(results_address, u32(num_counter_pairs)))) {
                            // No renderer counting: a counter that always advances, so a query
                            // always reads as "visible".
                            static constexpr u64 OcclusionCounterValidMask = 0x8000000000000000ULL;
                            static constexpr u64 OcclusionCounterStep = 0x2FFFFFFULL;
                            u64* results = reinterpret_cast<u64*>(results_address);
                            for (s32 i = 0; i < num_counter_pairs; ++i, results += 2) {
                                *results = pixel_counter | OcclusionCounterValidMask;
                            }
                            pixel_counter += OcclusionCounterStep;
                            Census::Note("pm4", "ZPASS_DONE with fake counters");
                        }
                    }
                } else if (event->event_index.Value() == EventIndex::SamplePipelineStat ||
                           event->event_index.Value() == EventIndex::SampleStreamoutStatSx) {
                    // Pipeline / stream-out statistics sampled to memory: not produced.
                    Census::Note("pm4", fmt::format("EVENT_WRITE {} statistics not written",
                                                    magic_enum::enum_name(event->event_type.Value())));
                }
                break;
            }
            case PM4ItOpcode::EventWriteEos: {
                const auto* event_eos = reinterpret_cast<const PM4CmdEventWriteEos*>(header);
                event_eos->SignalFence([&](void* address, u64 data, u32 num_bytes) {
                    ScheduleLabel(rasterizer, address, data, num_bytes, {});
                });
                if (event_eos->command == PM4CmdEventWriteEos::Command::GdsStore) {
                    ASSERT(event_eos->size == 1);
                    if (rasterizer) {
                        rasterizer->SyncGds();
                        const u32 value = rasterizer->ReadDataFromGds(event_eos->gds_index);
                        *event_eos->Address() = value;
                    }
                }
                break;
            }
            case PM4ItOpcode::EventWriteEop: {
                const auto* event_eop = reinterpret_cast<const PM4CmdEventWriteEop*>(header);
                // The data and the interrupt are the GPU's: done when the work recorded before this
                // packet has finished (ScheduleLabel), not when the packet is parsed.
                void* label_address = nullptr;
                u64 label_value = 0;
                u32 label_size = 0;
                bool label_irq = false;
                event_eop->SignalFence(
                    [&](void* address, u64 data, u32 num_bytes) {
                        label_address = address;
                        label_value = data;
                        label_size = num_bytes;
                    },
                    [&] { label_irq = true; });
                if (label_address != nullptr || label_irq) {
                    ScheduleLabel(rasterizer, label_address, label_value, label_size,
                                  label_irq ? std::function<void()>([] {
                                      Platform::IrqC::Instance()->Signal(
                                          Platform::InterruptId::GfxEop);
                                  })
                                            : std::function<void()>{});
                }
                break;
            }
            case PM4ItOpcode::DmaData: {
                ExecDmaData(reinterpret_cast<const PM4DmaData*>(header));
                break;
            }
            case PM4ItOpcode::WriteData: {
                const auto* write_data = reinterpret_cast<const PM4CmdWriteData*>(header);
                if ((write_data->dst_sel.Value() != 2 && write_data->dst_sel.Value() != 5) ||
                    write_data->wr_one_addr.Value() || header->type3.count.Value() < 2) {
                    // Registers, GDS, one address for all the data: the executor.
                    ExecWriteData(write_data, GfxQueueId);
                    break;
                }
                const u32 data_size = (header->type3.count.Value() - 2) * 4;
                u64* address = write_data->Address<u64*>();
                MaybeRecordVideoOutLabelLock(vo_port, address, write_data->data, data_size);
                WriteDataToMemory(rasterizer, address, write_data->data, data_size);
                break;
            }
            case PM4ItOpcode::MemSemaphore: {
                const auto* mem_semaphore = reinterpret_cast<const PM4CmdMemSemaphore*>(header);
                if (mem_semaphore->IsSignaling()) {
                    mem_semaphore->Signal();
                } else {
                    u64 sem_iters = 0;
                    while (!mem_semaphore->Signaled()) {
#ifdef ENABLE_BACHATA_RUNTIME
                        if (ShouldLogStallIteration(++sem_iters)) {
                            LOG_WARNING(Render_Vulkan,
                                        "PM4 MEM_SEMAPHORE stalled queue=gfx iterations={}",
                                        sem_iters);
                        }
#endif
                        YIELD_GFX();
                    }
                    mem_semaphore->Decrement();
                }
                break;
            }
            case PM4ItOpcode::AcquireMem: {
                // A cache flush / invalidate point over a range: the renderer's coherence hook.
                ExecPacket(header, Pm4Engine::Gfx, GfxQueueId);
                break;
            }
            case PM4ItOpcode::Rewind: {
                if (!rasterizer) {
                    break;
                }
                const PM4CmdRewind* rewind = reinterpret_cast<const PM4CmdRewind*>(header);
                u64 rewind_iters = 0;
                while (!rewind->Valid()) {
#ifdef ENABLE_BACHATA_RUNTIME
                    if (ShouldLogStallIteration(++rewind_iters)) {
                        LOG_WARNING(Render_Vulkan,
                                    "PM4 REWIND stalled queue=gfx iterations={}", rewind_iters);
                    }
#endif
                    YIELD_GFX();
                }
                break;
            }
            case PM4ItOpcode::WaitRegMem: {
                const auto* wait_reg_mem = reinterpret_cast<const PM4CmdWaitRegMem*>(header);
                // ASSERT(wait_reg_mem->engine.Value() == PM4CmdWaitRegMem::Engine::Me);
                if (wait_reg_mem->mem_space.Value() == PM4CmdWaitRegMem::MemSpace::Memory &&
                    !Pm4GuestPointerUsable(wait_reg_mem->Address<const void*>())) {
                    LOG_ERROR(Lib_GnmDriver, "IT_WAIT_REG_MEM null address — skipping");
                    break;
                }
                // Optimization: VO label waits are special because the emulator
                // will write to the label when presentation is finished. So if
                // there are no other submits to yield to we can sleep the thread
                // instead and allow other tasks to run.
                const u64* wait_addr = wait_reg_mem->Address<u64*>();
                if (vo_port->IsVoLabel(wait_addr) &&
                    num_submits == mapped_queues[GfxQueueId].submits.size()) {
                    if (!wait_reg_mem->Test(regs.reg_array)) {
                        LOG_WARNING(Render_Vulkan,
                                    "VO label wait addr={:#x} value={:#x} ref={:#x} index={}",
                                    reinterpret_cast<uintptr_t>(wait_addr), *wait_addr,
                                    wait_reg_mem->ref, vo_port->LabelIndex(wait_addr));
                    }
                    vo_port->WaitVoLabel([&] { return wait_reg_mem->Test(regs.reg_array); });
                    break;
                }
                bool gpu_order_met = false;
                if (wait_reg_mem->mem_space.Value() == PM4CmdWaitRegMem::MemSpace::Memory &&
                    !wait_reg_mem->Test(regs.reg_array)) {
                    // What produces the value (recorded work, a label write waiting for it) must be
                    // on the GPU before polling, or this waits for work nobody has started.
                    if (rasterizer) {
                        gpu_order_met = rasterizer->PrepareLabelWait(
                            wait_reg_mem->Address<const void*>(), 4,
                            static_cast<u32>(wait_reg_mem->function.Value()), wait_reg_mem->ref,
                            wait_reg_mem->mask);
                    }
                    Libraries::Hmd::SatisfyReprojectionLabelWait(
                        wait_reg_mem->Address<u32*>(),
                        static_cast<u32>(wait_reg_mem->function.Value()), wait_reg_mem->ref,
                        wait_reg_mem->mask, true);
                }
                u64 wait_iterations = 0;
                u64 label_looks = 0;
                while (!gpu_order_met && !wait_reg_mem->Test(regs.reg_array)) {
                    WaitRegMemIdle(rasterizer, wait_reg_mem, label_looks);
                    // The frame the label belongs to may be handed over after the wait began.
                    if ((++label_looks >= 64 || (label_looks & 0x3f) == 0) &&
                        wait_reg_mem->mem_space.Value() == PM4CmdWaitRegMem::MemSpace::Memory) {
                        Libraries::Hmd::SatisfyReprojectionLabelWait(
                            wait_reg_mem->Address<u32*>(),
                            static_cast<u32>(wait_reg_mem->function.Value()), wait_reg_mem->ref,
                            wait_reg_mem->mask);
                    }
#if defined(ENABLE_BACHATA_RUNTIME) || defined(SHADPS4_VISIONOS)
                    if (ShouldLogStallIteration(++wait_iterations)) {
                        const bool is_memory = wait_reg_mem->mem_space.Value() ==
                                               PM4CmdWaitRegMem::MemSpace::Memory;
                        const u32 value = is_memory ? *wait_reg_mem->Address<const u32*>()
                                                    : regs.reg_array[wait_reg_mem->Reg()];
                        LOG_WARNING(Render_Vulkan,
                                    "PM4 WAIT_REG_MEM stalled queue=gfx iterations={} space={} "
                                    "address={:#x} value={:#x} ref={:#x} mask={:#x} function={}",
                                    wait_iterations, is_memory ? "memory" : "register",
                                    is_memory ? reinterpret_cast<uintptr_t>(
                                                    wait_reg_mem->Address<const u32*>())
                                              : wait_reg_mem->Reg(),
                                    value, wait_reg_mem->ref, wait_reg_mem->mask,
                                    static_cast<u32>(wait_reg_mem->function.Value()));
                    }
#endif
                    YIELD_GFX();
                }
                break;
            }
            case PM4ItOpcode::IndirectBuffer: {
                const auto* indirect_buffer = reinterpret_cast<const PM4CmdIndirectBuffer*>(header);
                if (!Pm4IndirectBufferUsable(indirect_buffer->Address<const u32>(),
                                             indirect_buffer->ib_size)) {
                    LOG_ERROR(Lib_GnmDriver, "IT_INDIRECT_BUFFER skipped: addr={} size={}",
                              fmt::ptr(indirect_buffer->Address<const u32>()),
                              indirect_buffer->ib_size.Value());
                    break;
                }
                auto task = ProcessGraphics(
                    {indirect_buffer->Address<const u32>(), indirect_buffer->ib_size}, {}, true);
                RESUME_GFX(task);

                u64 ib_iters = 0;
                while (!task.handle.done()) {
                    YIELD_GFX();
                    RESUME_GFX(task);
#ifdef ENABLE_BACHATA_RUNTIME
                    if (ShouldLogStallIteration(++ib_iters)) {
                        LOG_WARNING(Render_Vulkan,
                                    "PM4 INDIRECT_BUFFER nested gfx stalled iterations={}", ib_iters);
                    }
#endif
                }
                break;
            }
            case PM4ItOpcode::IncrementDeCounter: {
                ++cblock.de_count;
                break;
            }
            case PM4ItOpcode::WaitOnCeCounter: {
                u64 woce_iters = 0;
                while (cblock.ce_count <= cblock.de_count && !ce_task.handle.done()) {
                    RESUME_GFX(ce_task);
#ifdef ENABLE_BACHATA_RUNTIME
                    if (ShouldLogStallIteration(++woce_iters)) {
                        LOG_WARNING(Render_Vulkan,
                                    "PM4 WAIT_ON_CE_COUNTER stalled queue=gfx iterations={} "
                                    "ce_count={} de_count={} ce_task_done={}",
                                    woce_iters, cblock.ce_count, cblock.de_count, 0);
                    }
#endif
                }
                break;
            }
            case PM4ItOpcode::PfpSyncMe: {
                if (rasterizer) {
                    rasterizer->CpSync();
                }
                break;
            }
            case PM4ItOpcode::CondExec: {
                const auto* cond_exec = reinterpret_cast<const PM4CmdCondExec*>(header);
                if (cond_exec->command.Value() != 0) {
                    LOG_WARNING(Render, "IT_COND_EXEC used a reserved command");
                }
                if (!Pm4GuestPointerUsable(cond_exec->Address())) {
                    LOG_ERROR(Lib_GnmDriver, "IT_COND_EXEC null predicate — skipping remainder");
                    dcb = {};
                    break;
                }
                const auto skip = *cond_exec->Address() == false;
                if (skip) {
                    dcb = NextPacket(dcb,
                                     header->type3.NumWords() + 1 + cond_exec->exec_count.Value());
                    continue;
                }
                break;
            }
            default: {
                // Everything else the command processor executes by itself (never an abort).
                while (ExecPacket(header, Pm4Engine::Gfx, GfxQueueId) == Pm4Result::Retry) {
                    YIELD_GFX();
                }
                break;
            }
            }
            dcb = NextPacket(dcb, header->type3.NumWords() + 1);
            break;
        }
    }

    if (ce_task.handle) {
        u64 cedrain_iters = 0;
        while (!ce_task.handle.done()) {
            RESUME_GFX(ce_task);
#ifdef ENABLE_BACHATA_RUNTIME
            if (ShouldLogStallIteration(++cedrain_iters)) {
                LOG_WARNING(Render_Vulkan,
                            "PM4 CE_DRAIN stalled (post-dcb ce_task) iterations={} "
                            "ce_count={} de_count={}",
                            cedrain_iters, cblock.ce_count, cblock.de_count);
            }
#endif
        }
        ce_task.handle.destroy();
    }

    FIBER_EXIT;
}

template <bool is_indirect>
Liverpool::Task Liverpool::ProcessCompute(std::span<const u32> acb, u32 vqid) {
    FIBER_ENTER(acb_task_name[vqid]);
    auto& queue = asc_queues[{vqid}];
    const bool host_markers_enabled = rasterizer && EmulatorSettings.IsVkHostMarkersEnabled();

    struct IndirectPatch {
        const PM4Header* header;
        VAddr indirect_addr;
    };
    boost::container::small_vector<IndirectPatch, 4> indirect_patches;

    auto base_addr = reinterpret_cast<VAddr>(acb.data());
    size_t acb_size = acb.size_bytes();
    while (!acb.empty()) {
        ProcessCommands();

        auto* header = reinterpret_cast<const PM4Header*>(acb.data());
        // Type-1 REG_B lives in the type-3 count field. Size from type first.
        u32 next_dw_off = header->type == 1 ? kPm4Type1PacketDwords : header->type3.NumWords() + 1;

        // If we have a buffered packet, use it.
        if (queue.tmp_dwords > 0) [[unlikely]] {
            header = reinterpret_cast<const PM4Header*>(queue.tmp_packet.data());
            const u32 packet_dwords = header->type == 1 ? kPm4Type1PacketDwords
                                                       : header->type3.NumWords() + 1;
            next_dw_off = packet_dwords - queue.tmp_dwords;
            std::memcpy(queue.tmp_packet.data() + queue.tmp_dwords, acb.data(),
                        next_dw_off * sizeof(u32));
            queue.tmp_dwords = 0;
        }

        // If the packet is split across ring boundary, buffer until next submission
        if (next_dw_off > acb.size()) [[unlikely]] {
            std::memcpy(queue.tmp_packet.data(), acb.data(), acb.size_bytes());
            queue.tmp_dwords = acb.size();
            if constexpr (!is_indirect) {
                *queue.read_addr += acb.size();
                *queue.read_addr %= queue.ring_size_dw;
            }
            break;
        }

        if (header->type == 2) {
            // Type-2 packet are used for padding purposes
            next_dw_off = 1;
            acb = NextPacket(acb, next_dw_off);
            if constexpr (!is_indirect) {
                *queue.read_addr += next_dw_off;
                *queue.read_addr %= queue.ring_size_dw;
            }
            continue;
        }

        if (header->type == 0) {
            const auto type0 = ConsumePm4Type0(acb, regs.reg_array);
            if (!type0.consumed) {
                LOG_ERROR(Lib_GnmDriver,
                          "ASC PM4 type 0 exceeds remaining submission. size={} remaining={}",
                          header->type0.NumWords(), acb.size());
                break;
            }
            LOG_WARNING(Lib_GnmDriver, "ASC PM4 type 0 register write base={} size={} written={}",
                        header->type0.base.Value(), header->type0.NumWords(), type0.words_written);
            next_dw_off = type0.packet_dwords;
            acb = NextPacket(acb, next_dw_off);
            if constexpr (!is_indirect) {
                *queue.read_addr += next_dw_off;
                *queue.read_addr %= queue.ring_size_dw;
            }
            continue;
        }

        if (header->type == 1) {
            const auto type1 = ConsumePm4Type1(acb, regs.reg_array);
            if (!type1.consumed) {
                LOG_ERROR(Lib_GnmDriver,
                          "ASC PM4 type 1 exceeds remaining submission. remaining={}", acb.size());
                break;
            }
            LOG_WARNING(Lib_GnmDriver, "ASC PM4 type 1 register write a={} b={} written={}",
                        Pm4Type1RegA(header->raw), Pm4Type1RegB(header->raw), type1.words_written);
            next_dw_off = type1.packet_dwords;
            acb = NextPacket(acb, next_dw_off);
            if constexpr (!is_indirect) {
                *queue.read_addr += next_dw_off;
                *queue.read_addr %= queue.ring_size_dw;
            }
            continue;
        }

        if (header->type != 3) {
            LOG_ERROR(Lib_GnmDriver, "ASC invalid PM4 type {} — skipping remainder",
                      header->type.Value());
            break;
        }

        const PM4ItOpcode opcode = header->type3.opcode;
#ifdef ENABLE_BACHATA_RUNTIME
        debug_last_opcode = static_cast<u32>(opcode);
#endif

        const auto* it_body = reinterpret_cast<const u32*>(header) + 1;
        switch (opcode) {
        case PM4ItOpcode::Nop: {
            const auto* nop = reinterpret_cast<const PM4CmdNop*>(header);
            break;
        }
        case PM4ItOpcode::IndirectBuffer: {
            const auto* indirect_buffer = reinterpret_cast<const PM4CmdIndirectBuffer*>(header);
            if (!Pm4IndirectBufferUsable(indirect_buffer->Address<const u32>(),
                                         indirect_buffer->ib_size)) {
                LOG_ERROR(Lib_GnmDriver, "ASC IT_INDIRECT_BUFFER skipped: addr={} size={}",
                          fmt::ptr(indirect_buffer->Address<const u32>()),
                          indirect_buffer->ib_size.Value());
                break;
            }
            auto task = ProcessCompute<true>(
                {indirect_buffer->Address<const u32>(), indirect_buffer->ib_size}, vqid);
            RESUME_ASC(task, vqid);

            while (!task.handle.done()) {
                YIELD_ASC(vqid);
                RESUME_ASC(task, vqid);
            }
            break;
        }
        case PM4ItOpcode::DmaData: {
            const auto* dma_data = reinterpret_cast<const PM4DmaData*>(header);
            if (dma_data->dst_addr_lo == 0x3022C || !rasterizer) {
                break;
            }
            if (dma_data->src_sel == DmaDataSrc::Data && dma_data->dst_sel == DmaDataDst::Gds) {
                rasterizer->FillBuffer(dma_data->dst_addr_lo, dma_data->NumBytes(), dma_data->data,
                                       true);
            } else if ((dma_data->src_sel == DmaDataSrc::Memory ||
                        dma_data->src_sel == DmaDataSrc::MemoryUsingL2) &&
                       dma_data->dst_sel == DmaDataDst::Gds) {
                rasterizer->CopyBuffer(dma_data->dst_addr_lo, dma_data->SrcAddress<VAddr>(),
                                       dma_data->NumBytes(), true, false);
            } else if (dma_data->src_sel == DmaDataSrc::Data &&
                       (dma_data->dst_sel == DmaDataDst::Memory ||
                        dma_data->dst_sel == DmaDataDst::MemoryUsingL2)) {
                rasterizer->FillBuffer(dma_data->DstAddress<VAddr>(), dma_data->NumBytes(),
                                       dma_data->data, false);
            } else if (dma_data->src_sel == DmaDataSrc::Gds &&
                       (dma_data->dst_sel == DmaDataDst::Memory ||
                        dma_data->dst_sel == DmaDataDst::MemoryUsingL2)) {
                rasterizer->CopyBuffer(dma_data->DstAddress<VAddr>(), dma_data->src_addr_lo,
                                       dma_data->NumBytes(), false, true);
            } else if ((dma_data->src_sel == DmaDataSrc::Memory ||
                        dma_data->src_sel == DmaDataSrc::MemoryUsingL2) &&
                       (dma_data->dst_sel == DmaDataDst::Memory ||
                        dma_data->dst_sel == DmaDataDst::MemoryUsingL2)) {
                const u32 num_bytes = dma_data->NumBytes();
                const VAddr src_addr = dma_data->SrcAddress<VAddr>();
                const VAddr dst_addr = dma_data->DstAddress<VAddr>();
                const PM4Header* header =
                    reinterpret_cast<const PM4Header*>(dst_addr - sizeof(PM4Header));
                if (dst_addr >= base_addr && dst_addr < base_addr + acb_size &&
                    num_bytes == sizeof(PM4CmdDispatchIndirect::GroupDimensions) &&
                    header->type == 3 && header->type3.opcode == PM4ItOpcode::DispatchDirect) {
                    indirect_patches.emplace_back(header, src_addr);
                } else {
                    rasterizer->CopyBuffer(dst_addr, src_addr, num_bytes, false, false);
                }
            } else {
                Census::Note("pm4", "DMA_DATA selectors unsupported (asc)",
                             fmt::format("src_sel={} dst_sel={}", u32(dma_data->src_sel.Value()),
                                         u32(dma_data->dst_sel.Value())));
            }
            break;
        }
        case PM4ItOpcode::AcquireMem: {
            ExecPacket(header, Pm4Engine::Asc, vqid + 1);
            break;
        }
        case PM4ItOpcode::Rewind: {
            if (!rasterizer) {
                break;
            }
            const PM4CmdRewind* rewind = reinterpret_cast<const PM4CmdRewind*>(header);
            while (!rewind->Valid()) {
                YIELD_ASC(vqid);
            }
            break;
        }
        case PM4ItOpcode::SetShReg: {
            const auto* set_data = reinterpret_cast<const PM4CmdSetData*>(header);
            const auto set_size = (header->type3.NumWords() - 1) * sizeof(u32);

            if (set_data->reg_offset >= 0x200 &&
                set_data->reg_offset <= (0x200 + sizeof(ComputeProgram) / 4)) {
                ASSERT(set_size <= sizeof(ComputeProgram));
                auto* addr = reinterpret_cast<u32*>(&mapped_queues[vqid + 1].cs_state) +
                             (set_data->reg_offset - 0x200);
                std::memcpy(addr, header + 2, set_size);
            } else {
                std::memcpy(&regs.reg_array[Regs::ShRegWordOffset + set_data->reg_offset],
                            header + 2, set_size);
            }
            break;
        }
        case PM4ItOpcode::SetQueueReg: {
            // Hardware queue descriptor registers (MEC): the queue is emulated, nothing to program.
            const auto* set_data = reinterpret_cast<const PM4CmdSetQueueReg*>(header);
            Census::Note("pm4", "SET_QUEUE_REG ignored",
                         fmt::format("vqid={} reg_offset={:#x}", set_data->vqid.Value(),
                                     set_data->reg_offset.Value()));
            break;
        }
        case PM4ItOpcode::DispatchDirect: {
            const auto* dispatch_direct = reinterpret_cast<const PM4CmdDispatchDirect*>(header);
            if (auto it = std::ranges::find(indirect_patches, header, &IndirectPatch::header);
                it != indirect_patches.end()) {
                const auto size = sizeof(PM4CmdDispatchIndirect::GroupDimensions);
                rasterizer->DispatchIndirect(it->indirect_addr, 0, size);
                break;
            }
            auto& cs_program = GetCsRegs();
            cs_program.dim_x = dispatch_direct->dim_x;
            cs_program.dim_y = dispatch_direct->dim_y;
            cs_program.dim_z = dispatch_direct->dim_z;
            cs_program.dispatch_initiator = dispatch_direct->dispatch_initiator;
            if (DebugState.DumpingCurrentReg()) {
                DebugState.PushRegsDumpCompute(base_addr, reinterpret_cast<uintptr_t>(header),
                                               cs_program);
            }
            if (rasterizer && (cs_program.dispatch_initiator & 1)) {
                const auto cmd_address = reinterpret_cast<const void*>(header);
                if (host_markers_enabled) {
                    rasterizer->ScopeMarkerBegin(
                        fmt::format("asc[{}]:{}:DispatchDirect", vqid, cmd_address));
                    rasterizer->DispatchDirect();
                    rasterizer->ScopeMarkerEnd();
                } else {
                    rasterizer->DispatchDirect();
                }
            }
            break;
        }
        case PM4ItOpcode::DispatchIndirect: {
            const auto* dispatch_indirect =
                reinterpret_cast<const PM4CmdDispatchIndirectMec*>(header);
            auto& cs_program = GetCsRegs();
            const auto ib_address = dispatch_indirect->Address<VAddr>();
            const auto size = sizeof(PM4CmdDispatchIndirect::GroupDimensions);
            if (DebugState.DumpingCurrentReg()) {
                DebugState.PushRegsDumpCompute(base_addr, reinterpret_cast<uintptr_t>(header),
                                               cs_program);
            }
            if (rasterizer && (cs_program.dispatch_initiator & 1)) {
                const auto cmd_address = reinterpret_cast<const void*>(header);
                if (host_markers_enabled) {
                    rasterizer->ScopeMarkerBegin(
                        fmt::format("asc[{}]:{}:DispatchIndirect", vqid, cmd_address));
                    rasterizer->DispatchIndirect(ib_address, 0, size);
                    rasterizer->ScopeMarkerEnd();
                } else {
                    rasterizer->DispatchIndirect(ib_address, 0, size);
                }
            }
            break;
        }
        case PM4ItOpcode::WriteData: {
            const auto* write_data = reinterpret_cast<const PM4CmdWriteData*>(header);
            if ((write_data->dst_sel.Value() != 2 && write_data->dst_sel.Value() != 5) ||
                write_data->wr_one_addr.Value() || header->type3.count.Value() < 2) {
                ExecWriteData(write_data, vqid + 1);
                break;
            }
            const u32 data_size = (header->type3.count.Value() - 2) * 4;
            MaybeRecordVideoOutLabelLock(vo_port, write_data->Address<u64*>(), write_data->data,
                                         data_size);
            WriteDataToMemory(rasterizer, write_data->Address<void*>(), write_data->data, data_size);
            break;
        }
        case PM4ItOpcode::MemSemaphore: {
            const auto* mem_semaphore = reinterpret_cast<const PM4CmdMemSemaphore*>(header);
            if (mem_semaphore->IsSignaling()) {
                mem_semaphore->Signal();
            } else {
                while (!mem_semaphore->Signaled()) {
                    YIELD_ASC(vqid);
                }
                mem_semaphore->Decrement();
            }
            break;
        }
        case PM4ItOpcode::WaitRegMem: {
            const auto* wait_reg_mem = reinterpret_cast<const PM4CmdWaitRegMem*>(header);
            ASSERT(wait_reg_mem->engine.Value() == PM4CmdWaitRegMem::Engine::Me);
            if (wait_reg_mem->mem_space.Value() == PM4CmdWaitRegMem::MemSpace::Memory &&
                !Pm4GuestPointerUsable(wait_reg_mem->Address<const void*>())) {
                LOG_ERROR(Lib_GnmDriver, "ASC IT_WAIT_REG_MEM null address — skipping");
                break;
            }
            bool gpu_order_met = false;
            if (wait_reg_mem->mem_space.Value() == PM4CmdWaitRegMem::MemSpace::Memory &&
                !wait_reg_mem->Test(regs.reg_array)) {
                if (rasterizer) {
                    gpu_order_met = rasterizer->PrepareLabelWait(
                        wait_reg_mem->Address<const void*>(), 4,
                        static_cast<u32>(wait_reg_mem->function.Value()), wait_reg_mem->ref,
                        wait_reg_mem->mask);
                }
                Libraries::Hmd::SatisfyReprojectionLabelWait(
                    wait_reg_mem->Address<u32*>(), static_cast<u32>(wait_reg_mem->function.Value()),
                    wait_reg_mem->ref, wait_reg_mem->mask, true);
            }
            u64 wait_iterations = 0;
            u64 label_looks = 0;
            while (!gpu_order_met && !wait_reg_mem->Test(regs.reg_array)) {
                WaitRegMemIdle(rasterizer, wait_reg_mem, label_looks);
                if ((++label_looks >= 64 || (label_looks & 0x3f) == 0) &&
                    wait_reg_mem->mem_space.Value() == PM4CmdWaitRegMem::MemSpace::Memory) {
                    Libraries::Hmd::SatisfyReprojectionLabelWait(
                        wait_reg_mem->Address<u32*>(),
                        static_cast<u32>(wait_reg_mem->function.Value()), wait_reg_mem->ref,
                        wait_reg_mem->mask);
                }
#if defined(ENABLE_BACHATA_RUNTIME) || defined(SHADPS4_VISIONOS)
                if (ShouldLogStallIteration(++wait_iterations)) {
                    const bool is_memory = wait_reg_mem->mem_space.Value() ==
                                           PM4CmdWaitRegMem::MemSpace::Memory;
                    const u32 value = is_memory ? *wait_reg_mem->Address<const u32*>()
                                                : regs.reg_array[wait_reg_mem->Reg()];
                    LOG_WARNING(Render_Vulkan,
                                "PM4 WAIT_REG_MEM stalled queue=asc{} iterations={} space={} "
                                "address={:#x} value={:#x} ref={:#x} mask={:#x} function={}",
                                vqid, wait_iterations, is_memory ? "memory" : "register",
                                is_memory ? reinterpret_cast<uintptr_t>(
                                                wait_reg_mem->Address<const u32*>())
                                          : wait_reg_mem->Reg(),
                                value, wait_reg_mem->ref, wait_reg_mem->mask,
                                static_cast<u32>(wait_reg_mem->function.Value()));
                }
#endif
                YIELD_ASC(vqid);
            }
            break;
        }
        case PM4ItOpcode::ReleaseMem: {
            const auto* release_mem = reinterpret_cast<const PM4CmdReleaseMem*>(header);
            release_mem->SignalFenceScheduled(
                [this](void* address, u64 value, u32 size, std::function<void()> then) {
                    ScheduleLabel(rasterizer, address, value, size, std::move(then));
                },
                [pipe_id = queue.pipe_id] {
                    Platform::IrqC::Instance()->Signal(static_cast<Platform::InterruptId>(pipe_id));
                },
                [this](VAddr dst, u16 gds_index, u16 num_dwords) {
                    rasterizer->CopyBuffer(dst, gds_index, num_dwords * sizeof(u32), false, true);
                });
            break;
        }
        case PM4ItOpcode::EventWrite: {
            // const auto* event = reinterpret_cast<const PM4CmdEventWrite*>(header);
            break;
        }
        default: {
            // The compute ring executes the same common packets (atomics, COPY_DATA, COND_WRITE,
            // register RMW / loads, RELEASE_MEM variants...); never an abort.
            while (ExecPacket(header, Pm4Engine::Asc, vqid + 1) == Pm4Result::Retry) {
                YIELD_ASC(vqid);
            }
            break;
        }
        }

        acb = NextPacket(acb, next_dw_off);

        if constexpr (!is_indirect) {
            *queue.read_addr += next_dw_off;
            *queue.read_addr %= queue.ring_size_dw;
        }
    }

    FIBER_EXIT;
}

Liverpool::CmdBuffer Liverpool::CopyCmdBuffers(std::span<const u32> dcb, std::span<const u32> ccb) {
    auto& queue = mapped_queues[GfxQueueId];

    // A single submission must always fit the reserved copy space.
    ASSERT_MSG(dcb.size() <= queue.dcb_buffer.capacity(),
               "dcb submission larger than reserved copy space");
    ASSERT_MSG(ccb.size() <= queue.ccb_buffer.capacity(),
               "ccb submission larger than reserved copy space");

    // The copy buffers persist across submissions so the GPU worker can parse a
    // command buffer even after the guest reuses its source ring. Their offsets
    // therefore grow monotonically and are only reset once the buffered data is no
    // longer needed. The guest is expected to signal that point with
    // sceGnmSubmitDone (-> SubmitDone), but some titles (e.g. Dark Souls
    // Remastered) never call it, so the offset would otherwise overflow the
    // reserved space and trip the assert below. When the next append would exceed
    // the reservation, drain the GPU first (all previously buffered spans have
    // then been consumed and can be discarded) and rewind the offsets to zero.
    const bool dcb_overflows = queue.dcb_buffer_offset + dcb.size() > queue.dcb_buffer.capacity();
    const bool ccb_overflows = queue.ccb_buffer_offset + ccb.size() > queue.ccb_buffer.capacity();
    if (dcb_overflows || ccb_overflows) {
        WaitGpuIdle();
        queue.dcb_buffer_offset = 0;
        queue.ccb_buffer_offset = 0;
    }

    queue.dcb_buffer.resize(
        std::max(queue.dcb_buffer.size(), queue.dcb_buffer_offset + dcb.size()));
    queue.ccb_buffer.resize(
        std::max(queue.ccb_buffer.size(), queue.ccb_buffer_offset + ccb.size()));

    const u32 prev_dcb_buffer_offset = queue.dcb_buffer_offset;
    const u32 prev_ccb_buffer_offset = queue.ccb_buffer_offset;
    if (!dcb.empty()) {
        std::memcpy(queue.dcb_buffer.data() + queue.dcb_buffer_offset, dcb.data(),
                    dcb.size_bytes());
        queue.dcb_buffer_offset += dcb.size();
        dcb = std::span<const u32>{queue.dcb_buffer.begin() + prev_dcb_buffer_offset,
                                   queue.dcb_buffer.begin() + queue.dcb_buffer_offset};
    }

    if (!ccb.empty()) {
        std::memcpy(queue.ccb_buffer.data() + queue.ccb_buffer_offset, ccb.data(),
                    ccb.size_bytes());
        queue.ccb_buffer_offset += ccb.size();
        ccb = std::span<const u32>{queue.ccb_buffer.begin() + prev_ccb_buffer_offset,
                                   queue.ccb_buffer.begin() + queue.ccb_buffer_offset};
    }

    return std::make_pair(dcb, ccb);
}

void Liverpool::SubmitGfx(std::span<const u32> dcb, std::span<const u32> ccb) {
    Vulkan::FrameStats::GuestSubmit();
    auto& queue = mapped_queues[GfxQueueId];

    if (EmulatorSettings.IsCopyGpuBuffers()) {
        std::tie(dcb, ccb) = CopyCmdBuffers(dcb, ccb);
    }

    {
        // Counted before it can be processed (SendCommandAfterGfx).
        std::scoped_lock lk{submit_mutex};
        ++gfx_submitted;
    }
    auto task = ProcessGraphics(dcb, ccb);
    if (resync_next_gfx.exchange(false, std::memory_order_relaxed)) {
        resync_task.store(task.handle.address(), std::memory_order_relaxed);
    }
    {
        std::scoped_lock lock{queue.m_access};
        queue.submits.emplace(task.handle);
    }

    std::scoped_lock lk{submit_mutex};
    ++num_submits;
    submit_cv.notify_one();
}

void Liverpool::SubmitAsc(u32 gnm_vqid, std::span<const u32> acb) {
    ASSERT_MSG(gnm_vqid > 0 && gnm_vqid < NumTotalQueues, "Invalid virtual ASC queue index");
    auto& queue = mapped_queues[gnm_vqid];

    const auto vqid = gnm_vqid - 1;
    const auto& task = ProcessCompute(acb, vqid);
    {
        std::scoped_lock lock{queue.m_access};
        queue.submits.emplace(task.handle);
    }

    std::scoped_lock lk{submit_mutex};
    num_mapped_queues = std::max(num_mapped_queues, gnm_vqid + 1);
    ++num_submits;
    submit_cv.notify_one();
}

} // namespace AmdGpu

// (Declared in video_core/rasterizer_interface.h: outside AmdGpu, where the name lives.)
namespace VideoCore {
void WriteGuestLabel(void* address, u64 value, u32 size) {
    auto* memory = Core::Memory::Instance();
    if (!memory->TryWriteBacking(address, &value, size)) {
        std::memcpy(address, &value, size);
    }
}
} // namespace VideoCore
