// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <cstring>
#include <functional>
#include <string_view>

#include "common/types.h"

namespace VideoCore {

/// Writes a label (1 to 8 bytes) to guest memory the way the GPU does (through the memory backing
/// when the address is one, else in place). Defined in amdgpu/liverpool.cpp.
void WriteGuestLabel(void* address, u64 value, u32 size);

/// What the command processor (Liverpool), the memory manager and the page manager ask of a
/// renderer. The Vulkan renderer implements it; a VPKEngine (Metal) renderer will too, chosen at start.
class RasterizerInterface {
public:
    virtual ~RasterizerInterface() = default;

    virtual void Draw(bool is_indexed, u32 index_offset = 0) = 0;
    virtual void DrawIndirect(bool is_indexed, VAddr arg_address, u32 offset, u32 size, u32 max_count,
                              VAddr count_address) = 0;

    virtual void DispatchDirect() = 0;
    virtual void DispatchIndirect(VAddr address, u32 offset, u32 size) = 0;

    virtual void ScopeMarkerBegin(const std::string_view& str, bool from_guest = false) = 0;
    virtual void ScopeMarkerEnd(bool from_guest = false) = 0;
    virtual void ScopedMarkerInsert(const std::string_view& str, bool from_guest = false) = 0;
    virtual void ScopedMarkerInsertColor(const std::string_view& str, const u32 color,
                                         bool from_guest = false) = 0;

    virtual void FillBuffer(VAddr address, u32 num_bytes, u32 value, bool is_gds) = 0;
    virtual void CopyBuffer(VAddr dst, VAddr src, u32 num_bytes, bool dst_gds, bool src_gds) = 0;
    virtual u32 ReadDataFromGds(u32 gsd_offset) = 0;
    virtual bool InvalidateMemory(VAddr addr, u64 size) = 0;
    virtual bool ReadMemory(VAddr addr, u64 size) = 0;
    /// A CPU access faulted on the host page [page, page + size) (visionOS: 16 KB, protected whole).
    /// Everything the renderer protects anywhere in the page is let go of. True if the access is retried.
    virtual bool InvalidateHostPage(VAddr page, u64 size, bool write) {
        return write ? InvalidateMemory(page, size) : ReadMemory(page, size);
    }
    virtual bool IsMapped(VAddr addr, u64 size) = 0;
    virtual void MapMemory(VAddr addr, u64 size) = 0;
    virtual void UnmapMemory(VAddr addr, u64 size) = 0;

    // ---- Command processor hooks with a default (a renderer that implements them overrides) ----

    /// EVENT_WRITE ZPASS_DONE: the depth block's pass counters are sampled into guest memory at
    /// `address`, `pairs` slots of 16 bytes (begin and end u64 each, bit 63 = written). True: the
    /// renderer counts the samples itself and writes the results when its GPU gets there (before
    /// anything the command processor reads them with must call SyncGpuWrites). False: the command
    /// processor writes a stand-in counter.
    virtual bool ZPassDone(VAddr address, u32 pairs) {
        return false;
    }

    /// The command processor is about to read guest memory [addr, addr + size) that queued GPU work
    /// may still write (occlusion results for SET_PREDICATION / OCCLUSION_QUERY). With `wait` the
    /// GPU is waited for until the range is final; without it the call only reports. Returns whether
    /// the range is final now.
    virtual bool SyncGpuWrites(VAddr addr, u64 size, bool wait) {
        return true;
    }

    /// ACQUIRE_MEM / SURFACE_SYNC: a cache flush / invalidate point over guest [base, base + size)
    /// (size ~0 = everything), with CP_COHER_CNTL's action bits (Pm4::kCoh*). Where render targets
    /// written by the GPU become coherent with guest memory for readers: the renderer's memory
    /// tracker (MemoryTracker::markGpuWrite) hangs here.
    virtual void OnCoherencePoint(VAddr base, u64 size, u32 coher_cntl) {}

    virtual void CpSync() = 0;
    virtual u64 Flush() = 0;
    virtual void Finish() = 0;
    virtual void OnSubmit() = 0;

    /// A label the GPU writes when it has finished the work recorded so far (PM4 EVENT_WRITE_EOP /
    /// EOS / RELEASE_MEM): `value` (`size` bytes) goes to `address` (may be null: interrupt only) and
    /// then `then` runs (the interrupt; may be empty). A renderer that runs behind the command
    /// processor does both when the work before the label has finished; the default does them now.
    virtual void ScheduleLabelWrite(void* address, u64 value, u32 size, std::function<void()> then) {
        if (address) {
            WriteGuestLabel(address, value, size);
        }
        if (then) {
            then();
        }
    }
    /// A WAIT_REG_MEM (function/ref/mask as in PM4) is about to poll `address`: whatever produces its
    /// value (recorded work, a pending label write) is put on the GPU now. Never waits. Returns true
    /// when the wait is already satisfied in GPU order (a label write queued behind work recorded on the
    /// same in-order queue gives the value): the command processor must not poll, it just goes on.
    virtual bool PrepareLabelWait(const void* address, u32 size, u32 function, u32 ref, u32 mask) {
        (void)address;
        (void)size;
        (void)function;
        (void)ref;
        (void)mask;
        return false;
    }
    /// A WAIT_REG_MEM poll found nothing yet: blocks briefly on the GPU frame that produces the value
    /// (true), or returns false when no GPU work is involved (the caller sleeps a little itself).
    virtual bool IdleLabelWait(const void* address, u32 size) {
        (void)address;
        (void)size;
        return false;
    }
    /// IT_WRITE_DATA to memory: ordered with the GPU work that reads or writes that memory (and
    /// with label writes pending for it).
    virtual void WriteDataOrdered(void* address, const void* data, u32 size) {
        std::memcpy(address, data, size);
    }
    /// The GPU's work on GDS is finished (the CPU is about to read it).
    virtual void SyncGds() {
        Finish();
    }
};

} // namespace VideoCore
