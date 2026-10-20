// Census: counts, first detail kept, truncation, threads, summary output. Standalone (no gtest):
// exit code 0 = pass.
#include <atomic>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

#include "platform/visionos/vpkengine_census.h"

namespace {
int failures = 0;
#define CHECK(c)                                                                                   \
    do {                                                                                           \
        if (!(c)) {                                                                                \
            std::fprintf(stderr, "%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, #c);             \
            ++failures;                                                                            \
        }                                                                                          \
    } while (0)

std::vector<std::string> lines;
void collect(std::string_view l) {
    lines.emplace_back(l);
}

const Census::Entry* find(const std::vector<Census::Entry>& v, const char* cat, const char* key) {
    for (const auto& e : v)
        if (e.category == cat && e.key == key) return &e;
    return nullptr;
}
} // namespace

int main() {
    Census::SetSink(collect);
    Census::SetPeriodSeconds(0);

    Census::Note("pm4", "ATOMIC_GDS", "first");
    Census::Note("pm4", "ATOMIC_GDS", "second");
    Census::Note("pm4", "GET_LOD_STATS");
    auto snap = Census::Snapshot();
    const auto* a = find(snap, "pm4", "ATOMIC_GDS");
    CHECK(a && a->count == 2 && a->detail == "first");
    const auto* g = find(snap, "pm4", "GET_LOD_STATS");
    CHECK(g && g->count == 1 && g->detail.empty());

    // Same key in another category is another entry.
    Census::Note("draw-skip", "ATOMIC_GDS");
    snap = Census::Snapshot();
    CHECK(find(snap, "draw-skip", "ATOMIC_GDS")->count == 1);
    CHECK(find(snap, "pm4", "ATOMIC_GDS")->count == 2);

    // Long strings are cut, not rejected.
    Census::Note("a-category-name-that-is-too-long", std::string(300, 'k'), std::string(500, 'd'));
    snap = Census::Snapshot();
    bool cut = false;
    for (const auto& e : snap)
        if (e.category.size() == 23 && e.key.size() == 95 && e.detail.size() == 127) cut = true;
    CHECK(cut);

    // Threads: counts add up, no key is duplicated.
    {
        std::vector<std::thread> ts;
        for (int t = 0; t < 8; ++t)
            ts.emplace_back([t] {
                for (int i = 0; i < 20000; ++i) {
                    Census::Note("thread", "shared");
                    Census::Note("thread", i % 2 ? "odd" : "even", t == 0 ? "from 0" : "other");
                }
            });
        for (auto& t : ts) t.join();
        snap = Census::Snapshot();
        CHECK(find(snap, "thread", "shared")->count == 160000);
        CHECK(find(snap, "thread", "odd")->count == 80000);
        CHECK(find(snap, "thread", "even")->count == 80000);
        size_t shared = 0;
        for (const auto& e : snap) shared += e.category == "thread" && e.key == "shared";
        CHECK(shared == 1);
    }

    // Summary: first flush shows everything, the second only what changed.
    lines.clear();
    Census::Flush(false);
    CHECK(!lines.empty() && lines[0].find("PS4_CENSUS summary") == 0);
    bool sawAtomic = false;
    for (const auto& l : lines) sawAtomic |= l.find("[pm4] ATOMIC_GDS x2 (+2) first: first") != std::string::npos;
    CHECK(sawAtomic);
    lines.clear();
    Census::Flush(false);
    CHECK(lines.empty());
    Census::Note("pm4", "ATOMIC_GDS");
    Census::Flush(false);
    bool onlyChanged = lines.size() == 2 && lines[1].find("ATOMIC_GDS x3 (+1)") != std::string::npos;
    CHECK(onlyChanged);
    lines.clear();
    Census::Flush(true);
    CHECK(lines.size() > 5);

    // The C API.
    vpkengine_census_note("c-api", "key", "detail");
    vpkengine_census_note(nullptr, nullptr, nullptr);
    snap = Census::Snapshot();
    CHECK(find(snap, "c-api", "key")->detail == "detail");
    CHECK(find(snap, "?", "?") != nullptr);

    // Table full: further new keys only count as overflow, known keys keep counting.
    for (int i = 0; i < 6000; ++i) Census::Note("fill", "k" + std::to_string(i));
    CHECK(Census::Overflowed() > 0);
    Census::Note("pm4", "GET_LOD_STATS");
    snap = Census::Snapshot();
    CHECK(find(snap, "pm4", "GET_LOD_STATS")->count == 2);

    Census::ResetForTests();
    CHECK(Census::Snapshot().empty());
    if (failures == 0) std::puts("census: ok");
    return failures ? 1 : 0;
}
