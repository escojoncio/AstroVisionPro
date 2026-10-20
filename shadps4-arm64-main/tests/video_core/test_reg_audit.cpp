// Context register audit: reset values, consumed registers, once per (register, value).
#include <array>
#include <cstdio>
#include <vector>

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
    std::array<uint32_t, kContextRegs> reset{}, live{};
    reset[0x10] = 0x40004000u;
    live = reset;
    Auditor a(reset.data());
    a.Consume(kContextBase + 0x20, 4);        // 0xA020..0xA023
    a.Consume(0x2C00, 8);                      // outside the context range: ignored
    a.Consume(kContextBase + 0x3FE, 8);        // straddles the end
    CHECK(a.Consumed(kContextBase + 0x23) && !a.Consumed(kContextBase + 0x24));
    CHECK(a.Consumed(kContextBase + 0x3FF) && !a.Consumed(0x2C00));

    std::vector<std::pair<uint32_t, uint32_t>> got;
    auto note = [&](uint32_t r, uint32_t v) { got.push_back({r, v}); };
    CHECK(a.Check(live.data(), note) == 0);  // at reset: nothing

    live[0x20] = 5;                // consumed: not reported
    live[0x30] = 7;                // not consumed, differs from reset
    live[0x10] = 0;                // reset was non-zero: differs
    CHECK(a.Check(live.data(), note) == 2);
    CHECK(got.size() == 2);
    CHECK(got[0] == std::make_pair(kContextBase + 0x10, 0u));
    CHECK(got[1] == std::make_pair(kContextBase + 0x30, 7u));
    CHECK(a.Check(live.data(), note) == 0);  // same values: once

    live[0x30] = 9;                // a new value
    CHECK(a.Check(live.data(), note) == 1);
    live[0x30] = 7;                // back to an old value: already reported
    CHECK(a.Check(live.data(), note) == 0);
    live[0x30] = 0;                // reset again, then the old value: still once
    CHECK(a.Check(live.data(), note) == 0);
    live[0x30] = 7;
    CHECK(a.Check(live.data(), note) == 0);

    // The table is bounded: past kMaxSeen distinct pairs the audit says so once and stops.
    got.clear();
    for (uint32_t v = 1; v < 20000; ++v) {
        live[0x40] = v;
        a.Check(live.data(), note);
    }
    CHECK(got.size() < 20000);
    size_t full = 0;
    for (auto& g : got) full += g.first == 0;
    CHECK(full == 1);
    return failures ? 1 : 0;
}
