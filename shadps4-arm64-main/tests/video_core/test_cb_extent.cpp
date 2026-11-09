// TargetExtents: the size a colour target is named with by draws and resolves. Standalone (no gtest): exit code 0 = pass.
#include <cstdio>

#include "platform/visionos/vpkengine_extent.h"

namespace {
int failures = 0;
#define CHECK(c)                                                                                   \
    do {                                                                                           \
        if (!(c)) {                                                                                \
            std::fprintf(stderr, "%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, #c);             \
            ++failures;                                                                            \
        }                                                                                          \
    } while (0)
using VpkengineRenderer::TargetExtents;
} // namespace

int main() {
    TargetExtents e;
    uint32_t w = 832, h = 896;
    // The draw: the hint replaces the pitch and height.
    CHECK(e.Apply(0x1000, 10, true, 816, 870, w, h) == TargetExtents::Source::Hint && w == 816 && h == 870);
    // The resolve of the same address with a valid hint: the same.
    w = 832, h = 896;
    CHECK(e.Apply(0x1000, 10, true, 816, 870, w, h) == TargetExtents::Source::Hint && w == 816 && h == 870);
    // The resolve with no hint (cleared by a packet without one), the same registers: the size drawn at that address.
    w = 832, h = 896;
    CHECK(e.Apply(0x1000, 10, false, 0, 0, w, h) == TargetExtents::Source::Cache && w == 816 && h == 870);
    // A hint larger than the registers is not trusted (as in the draw); the cache answers for the same registers.
    w = 832, h = 896;
    CHECK(e.Apply(0x1000, 10, true, 900, 870, w, h) == TargetExtents::Source::Cache && w == 816 && h == 870);
    // Another address has nothing: the registers stay.
    w = 896, h = 896;
    CHECK(e.Apply(0x2000, 10, false, 0, 0, w, h) == TargetExtents::Source::None && w == 896 && h == 896);
    // The address reused by a target with other registers and no hint: the registers stand, even if the old size fits.
    w = 1472, h = 1536;
    CHECK(e.Apply(0x1000, 10, false, 0, 0, w, h) == TargetExtents::Source::None && w == 1472 && h == 1536);
    w = 800, h = 800;
    CHECK(e.Apply(0x1000, 10, false, 0, 0, w, h) == TargetExtents::Source::None && w == 800 && h == 800);
    // Same registers, another format: another target.
    w = 832, h = 896;
    CHECK(e.Apply(0x1000, 5, false, 0, 0, w, h) == TargetExtents::Source::None && w == 832 && h == 896);
    // A new valid hint replaces the remembered size and registers.
    w = 1472, h = 1536;
    CHECK(e.Apply(0x1000, 10, true, 1440, 1536, w, h) == TargetExtents::Source::Hint);
    w = 1472, h = 1536;
    CHECK(e.Apply(0x1000, 10, false, 0, 0, w, h) == TargetExtents::Source::Cache && w == 1440 && h == 1536);
    // Bounded: the entry unused for longest goes when the table is full.
    for (uint64_t a = 0; a < TargetExtents::kMaxEntries + 8; ++a) {
        w = 64, h = 64;
        e.Apply(0x100000 + a * 0x1000, 10, true, 60, 60, w, h);
    }
    w = 64, h = 64;
    CHECK(e.Apply(0x100000, 10, false, 0, 0, w, h) == TargetExtents::Source::None);
    w = 64, h = 64;
    CHECK(e.Apply(0x100000 + (TargetExtents::kMaxEntries + 7) * 0x1000, 10, false, 0, 0, w, h) == TargetExtents::Source::Cache);
    // View slices (DB_DEPTH_VIEW / CB_COLORn_VIEW): one slice k of an array is SLICE_START = SLICE_MAX = k -> 1 slice from k
    // (the image then has k + 1 layers, not 2k + 1); a view from 0 counts SLICE_MAX + 1; SLICE_MAX below SLICE_START -> 1.
    CHECK(VpkengineRenderer::ViewSliceCount(0, 0) == 1);
    CHECK(VpkengineRenderer::ViewSliceCount(4, 4) == 1);
    CHECK(VpkengineRenderer::ViewSliceCount(0, 1) == 2);
    CHECK(VpkengineRenderer::ViewSliceCount(2, 7) == 6);
    CHECK(VpkengineRenderer::ViewSliceCount(5, 0) == 1);
    if (failures) std::fprintf(stderr, "%d failure(s)\n", failures);
    return failures ? 1 : 0;
}
