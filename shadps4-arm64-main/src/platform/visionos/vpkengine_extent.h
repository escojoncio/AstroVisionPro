// The size a title set a colour target up with. The CB registers hold the tile-aligned pitch and height; the title's own
// size (SetRenderTarget's trailing NOP hint, Liverpool::last_cb_extent) is smaller (816x870 in 832x896). Draws and resolves
// must name the same size, or the engine finds no target of that size at the address.
#pragma once

#include <cstddef>
#include <cstdint>
#include <unordered_map>

namespace VpkengineRenderer {

class TargetExtents {
public:
    enum class Source { None, Hint, Cache };

    // Targets remembered (probe).
    size_t Size() const { return known.size(); }

    // `width`/`height` come in as the CB's pitch and height. A valid hint no larger than them replaces them and is
    // remembered for the address together with the registers it came with. Without one (the packet that set the registers
    // had no hint) the size remembered at that address is used only if the registers and the format are exactly the ones
    // it was set up with: the address may have been reused by another target, and then the registers stand (as in Vulkan).
    Source Apply(uint64_t address, uint8_t format, bool hint_valid, uint32_t hint_width, uint32_t hint_height,
                 uint32_t& width, uint32_t& height) {
        if (hint_valid && hint_width <= width && hint_height <= height) {
            if (known.size() >= kMaxEntries && !known.contains(address)) Evict();
            known[address] = {width, height, format, hint_width, hint_height, ++tick};
            width = hint_width;
            height = hint_height;
            return Source::Hint;
        }
        const auto it = known.find(address);
        if (it != known.end() && it->second.reg_width == width && it->second.reg_height == height &&
            it->second.format == format) {
            it->second.used = ++tick;
            width = it->second.width;
            height = it->second.height;
            return Source::Cache;
        }
        return Source::None;
    }

    static constexpr size_t kMaxEntries = 256;

private:
    struct Entry {
        uint32_t reg_width, reg_height;
        uint8_t format;
        uint32_t width, height;
        uint64_t used;
    };
    // The entry unused for longest goes.
    void Evict() {
        auto oldest = known.begin();
        for (auto it = known.begin(); it != known.end(); ++it)
            if (it->second.used < oldest->second.used) oldest = it;
        known.erase(oldest);
    }
    std::unordered_map<uint64_t, Entry> known;
    uint64_t tick = 0;
};

// The slices a CB/DB view renders to, counted from its first: SLICE_START..SLICE_MAX (vpps4 ColorTarget/DepthTarget
// sliceStart/sliceCount; the engine's image has sliceStart + sliceCount layers). NumSlices() of the registers is
// SLICE_MAX + 1, the slices counted from 0.
inline uint16_t ViewSliceCount(uint32_t slice_start, uint32_t slice_max) {
    return uint16_t(slice_max >= slice_start ? slice_max - slice_start + 1 : 1);
}

} // namespace VpkengineRenderer
