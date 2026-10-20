// SPDX-License-Identifier: GPL-2.0-or-later
//
// Context register audit: which registers the guest set to something other than their reset value
// that the renderer never reads. Per draw, every context register that differs from its reset value,
// is not in the consumed set and has not been reported with that value before is handed to a callback
// (the Census, category "reg"). Each (register, value) pair is reported once. Plain C++ with no emulator
// dependency (tests/video_core/test_reg_audit.cpp builds it alone).
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <unordered_set>

namespace AmdGpu::RegAudit {

inline constexpr uint32_t kContextBase = 0xA000;
inline constexpr uint32_t kContextRegs = 0x400;  // 0xA000..0xA3FF: every register a draw can use

class Auditor {
public:
    // `reset`: the kContextRegs context registers after a reset.
    explicit Auditor(const uint32_t* reset) {
        for (uint32_t i = 0; i < kContextRegs; ++i) reset_[i] = last_[i] = reset[i];
    }

    // Marks MMIO registers [first, first + count) as read by the renderer. Parts outside the
    // context range are ignored.
    void Consume(uint32_t first, uint32_t count) {
        for (uint32_t r = first; r < first + count; ++r)
            if (r >= kContextBase && r < kContextBase + kContextRegs) consumed_[r - kContextBase] = true;
    }

    // `ctx`: the live context registers (kContextRegs of them). `note(reg, value)` is called for
    // each new (register, value); `reg` is the MMIO index. Returns how many were reported.
    template <class Note>
    uint32_t Check(const uint32_t* ctx, Note&& note) {
        uint32_t reported = 0;
        for (uint32_t i = 0; i < kContextRegs; ++i) {
            const uint32_t v = ctx[i];
            if (v == reset_[i] || consumed_[i] || v == last_[i]) continue;
            last_[i] = v;  // (cheap filter: a value that stays does not touch the set)
            if (seen_.size() >= kMaxSeen) {
                if (!overflow_) {
                    overflow_ = true;
                    note(0u, 0u);  // register 0 = "audit table full"
                }
                continue;
            }
            if (!seen_.insert((uint64_t(i) << 32) | v).second) continue;
            note(kContextBase + i, v);
            ++reported;
        }
        return reported;
    }

    bool Consumed(uint32_t reg) const {
        return reg >= kContextBase && reg < kContextBase + kContextRegs && consumed_[reg - kContextBase];
    }

private:
    static constexpr size_t kMaxSeen = 16384;
    std::array<uint32_t, kContextRegs> reset_{};
    std::array<uint32_t, kContextRegs> last_{};
    std::array<bool, kContextRegs> consumed_{};
    std::unordered_set<uint64_t> seen_;
    bool overflow_ = false;
};

}  // namespace AmdGpu::RegAudit
