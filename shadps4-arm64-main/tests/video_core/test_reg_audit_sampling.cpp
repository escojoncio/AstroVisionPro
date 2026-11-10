// Which draws the context register audit scans: none outside diagnostics mode, one in 64 (the
// first included) in it, and the count of scans taken.
#include <cstdio>

#include "video_core/amdgpu/reg_audit.h"

namespace {
int failures = 0;
#define CHECK(c)                                                                       \
    do {                                                                               \
        if (!(c)) {                                                                    \
            std::fprintf(stderr, "%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, #c); \
            ++failures;                                                                \
        }                                                                              \
    } while (0)
}  // namespace

int main() {
    using namespace AmdGpu::RegAudit;
    Sampler off;
    for (int i = 0; i < 1000; ++i) CHECK(!off.Next(false));
    CHECK(off.Scans() == 0);

    Sampler on;
    uint64_t taken = 0;
    const uint64_t draws = 64 * 100 + 1;
    for (uint64_t i = 0; i < draws; ++i) {
        const bool scan = on.Next(true);
        CHECK(scan == (i % kScanEvery == 0));  // the first draw, then every 64th
        taken += scan;
    }
    CHECK(taken == 101);
    CHECK(on.Scans() == taken);
    CHECK(on.Scans() <= draws / kScanEvery + 1);

    // Draws made with diagnostics off do not move the sampling.
    Sampler mixed;
    for (int i = 0; i < 500; ++i) mixed.Next(false);
    CHECK(mixed.Next(true) && !mixed.Next(true));

    if (failures == 0) std::puts("reg audit sampling: ok");
    return failures == 0 ? 0 : 1;
}
