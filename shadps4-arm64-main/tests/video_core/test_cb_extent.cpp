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
    CHECK(e.Apply(0x1000, true, 816, 870, w, h) == TargetExtents::Source::Hint && w == 816 && h == 870);
    // The resolve of the same address with a valid hint: the same.
    w = 832, h = 896;
    CHECK(e.Apply(0x1000, true, 816, 870, w, h) == TargetExtents::Source::Hint && w == 816 && h == 870);
    // The resolve with no hint (cleared by a packet without one): the size drawn at that address.
    w = 832, h = 896;
    CHECK(e.Apply(0x1000, false, 0, 0, w, h) == TargetExtents::Source::Cache && w == 816 && h == 870);
    // A hint larger than the registers is not trusted (as in the draw); the cache answers.
    w = 832, h = 896;
    CHECK(e.Apply(0x1000, true, 900, 870, w, h) == TargetExtents::Source::Cache && w == 816 && h == 870);
    // Another address has nothing: the registers stay.
    w = 896, h = 896;
    CHECK(e.Apply(0x2000, false, 0, 0, w, h) == TargetExtents::Source::None && w == 896 && h == 896);
    // A remembered size that no longer fits the registers (the address was reused for a smaller target) is not applied.
    w = 800, h = 800;
    CHECK(e.Apply(0x1000, false, 0, 0, w, h) == TargetExtents::Source::None && w == 800 && h == 800);
    // A new valid hint replaces the remembered size.
    w = 1472, h = 1536;
    CHECK(e.Apply(0x1000, true, 1440, 1536, w, h) == TargetExtents::Source::Hint);
    w = 1472, h = 1536;
    CHECK(e.Apply(0x1000, false, 0, 0, w, h) == TargetExtents::Source::Cache && w == 1440 && h == 1536);
    if (failures) std::fprintf(stderr, "%d failure(s)\n", failures);
    return failures ? 1 : 0;
}
