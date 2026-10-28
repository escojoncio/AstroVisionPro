// The size a title set a colour target up with. The CB registers hold the tile-aligned pitch and height; the title's own
// size (SetRenderTarget's trailing NOP hint, Liverpool::last_cb_extent) is smaller (816x870 in 832x896). Draws and resolves
// must name the same size, or the engine finds no target of that size at the address.
#pragma once

#include <cstdint>
#include <unordered_map>
#include <utility>

namespace VpkengineRenderer {

class TargetExtents {
public:
    enum class Source { None, Hint, Cache };

    // `width`/`height` come in as the CB's pitch and height. A valid hint no larger than them replaces them and is
    // remembered for the address. Without one (the registers were set up by a packet with no hint, or the hint of another
    // shape was set since) the size last applied at that address is used, if it still fits.
    Source Apply(uint64_t address, bool hint_valid, uint32_t hint_width, uint32_t hint_height, uint32_t& width,
                 uint32_t& height) {
        if (hint_valid && hint_width <= width && hint_height <= height) {
            width = hint_width;
            height = hint_height;
            known[address] = {width, height};
            return Source::Hint;
        }
        const auto it = known.find(address);
        if (it != known.end() && it->second.first <= width && it->second.second <= height) {
            width = it->second.first;
            height = it->second.second;
            return Source::Cache;
        }
        return Source::None;
    }

private:
    std::unordered_map<uint64_t, std::pair<uint32_t, uint32_t>> known;
};

} // namespace VpkengineRenderer
