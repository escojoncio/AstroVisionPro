// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <span>
#include <unordered_map>

#include "common/types.h"

namespace VideoCore {

/// The fast clear state of the metadata surfaces (CMASK, FMASK, HTILE) of the render targets drawn
/// so far, as the Vulkan backend keeps it (TextureCache::surface_metas): a title clears a target by
/// writing its metadata, and the clear is carried out by the first draw that uses the target.
/// A slice with its bit set is "cleared": its target holds the clear value, not what memory says.
/// Not thread safe: the caller holds its own lock.
class SurfaceMetas {
public:
    enum class Type { CMask, FMask, HTile };

    /// A target with this metadata is bound. A surface seen for the first time starts cleared.
    void Register(Type type, VAddr address) {
        metas.emplace(address, Meta{type, u32(-1)});
    }

    bool Empty() const {
        return metas.empty();
    }

    bool IsMeta(VAddr address) const {
        return metas.contains(address);
    }

    bool IsHtile(VAddr address) const {
        const auto it = metas.find(address);
        return it != metas.end() && it->second.type == Type::HTile;
    }

    bool IsCleared(VAddr address, u32 slice) const {
        const auto it = metas.find(address);
        return it != metas.end() && slice < 32 && (it->second.clear_mask & (1u << slice));
    }

    /// The surfaces at addresses in [start, end) are forgotten (their memory was unmapped).
    void EraseRange(VAddr start, VAddr end) {
        std::erase_if(metas, [&](const auto& meta) { return meta.first >= start && meta.first < end; });
    }

    /// Every slice of the surface is cleared. False if the address is not metadata.
    bool ClearAll(VAddr address) {
        const auto it = metas.find(address);
        if (it == metas.end()) {
            return false;
        }
        it->second.clear_mask = u32(-1);
        return true;
    }

    /// A slice was drawn into (`is_clear` false) or cleared. False if the address is not metadata.
    bool Touch(VAddr address, u32 slice, bool is_clear) {
        const auto it = metas.find(address);
        if (it == metas.end() || slice >= 32) {
            return false;
        }
        if (is_clear) {
            it->second.clear_mask |= 1u << slice;
        } else {
            it->second.clear_mask &= ~(1u << slice);
        }
        return true;
    }

    /// Words written over the HTILE surface at `address` (a DMA fill or copy) that clear it: the low
    /// four bits of an entry are its zmask; zero means every pixel of that 8x8 tile holds the depth
    /// clear value. Titles clear depth by filling the surface with such entries, or by copying in a
    /// template they prepared once. A template may also mark some tiles as permanently occluded (zero
    /// depth range), which is how VR titles skip the part of the eye buffer the lenses cannot show;
    /// those tiles only save work, so a plain clear is equivalent. True if the surface is now cleared.
    bool TryHtileClear(VAddr address, std::span<const u32> htile_words) {
        if (htile_words.empty() || !IsHtile(address)) {
            return false;
        }
        u64 cleared = 0;
        u64 written = 0;
        for (const u32 word : htile_words) {
            if (word == 0) {
                // Padding past the end of the surface.
                continue;
            }
            ++written;
            cleared += (word & 0xf) == 0;
        }
        if (cleared * 2 < written || cleared == 0) {
            return false;
        }
        return ClearAll(address);
    }

private:
    struct Meta {
        Type type;
        u32 clear_mask;
    };
    std::unordered_map<VAddr, Meta> metas;
};

} // namespace VideoCore
