// Census (see vpkengine_census.h): a fixed open-addressing table of counters. A key is claimed once
// (compare-and-swap on the slot state, then its strings are written and the slot published); every
// later event is a probe plus one relaxed fetch_add. Nothing is freed: the table is leaked on purpose
// so events from late threads at exit stay valid.
#include "vpkengine_census.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <thread>

namespace Census {
namespace {

constexpr size_t kSlots = 4096;
constexpr size_t kCategoryBytes = 24, kKeyBytes = 96, kDetailBytes = 128;

struct Slot {
    std::atomic<uint32_t> state{0}; // 0 free, 1 being filled, 2 published
    uint64_t hash = 0;
    char category[kCategoryBytes];
    char key[kKeyBytes];
    char detail[kDetailBytes];
    std::atomic<uint64_t> count{0};
    std::atomic<uint64_t> printed{0};
};

struct Table {
    Slot slots[kSlots];
    std::atomic<uint64_t> overflow{0};
    std::atomic<Sink> sink{nullptr};
    std::atomic<unsigned> period{10};
    std::atomic<bool> started{false};
    std::mutex flushLock;
    uint64_t printedOverflow = 0; // under flushLock
};

Table& table() {
    static Table* t = new Table();
    return *t;
}

void copyCut(char* dst, size_t cap, std::string_view s) {
    const size_t n = std::min(s.size(), cap - 1);
    if (n) std::memcpy(dst, s.data(), n);
    dst[n] = 0;
}

uint64_t hashOf(std::string_view category, std::string_view key) {
    uint64_t h = 0xcbf29ce484222325ull;
    auto mix = [&](unsigned char c) { h = (h ^ c) * 0x100000001b3ull; };
    for (unsigned char c : category) mix(c);
    mix(0xff);
    for (unsigned char c : key) mix(c);
    return h ? h : 1;
}

void defaultSink(std::string_view line) {
    std::fprintf(stderr, "%.*s\n", int(line.size()), line.data());
}

void emit(std::string_view text) {
    Sink s = table().sink.load(std::memory_order_acquire);
    (s ? s : defaultSink)(text);
}

void startBackground() {
    std::atexit([] { Flush(true); });
    std::thread([] {
        unsigned waited = 0;
        for (;;) {
            std::this_thread::sleep_for(std::chrono::seconds(1));
            const unsigned period = table().period.load(std::memory_order_relaxed);
            if (period == 0) {
                waited = 0;
                continue;
            }
            if (++waited >= period) {
                waited = 0;
                Flush(false);
            }
        }
    }).detach();
}

} // namespace

void SetSink(Sink sink) {
    table().sink.store(sink, std::memory_order_release);
}

void SetPeriodSeconds(unsigned seconds) {
    table().period.store(seconds, std::memory_order_relaxed);
}

void Note(std::string_view category, std::string_view key, std::string_view detail) {
    Table& t = table();
    if (category.size() >= kCategoryBytes) category = category.substr(0, kCategoryBytes - 1);
    if (key.size() >= kKeyBytes) key = key.substr(0, kKeyBytes - 1);
    if (!t.started.load(std::memory_order_relaxed) && !t.started.exchange(true)) startBackground();

    const uint64_t h = hashOf(category, key);
    size_t i = h % kSlots;
    for (size_t probes = 0; probes < kSlots; ++probes, i = (i + 1) % kSlots) {
        Slot& s = t.slots[i];
        uint32_t st = s.state.load(std::memory_order_acquire);
        if (st == 0) {
            uint32_t expected = 0;
            if (s.state.compare_exchange_strong(expected, 1, std::memory_order_acq_rel)) {
                s.hash = h;
                copyCut(s.category, kCategoryBytes, category);
                copyCut(s.key, kKeyBytes, key);
                copyCut(s.detail, kDetailBytes, detail);
                s.state.store(2, std::memory_order_release);
                s.count.fetch_add(1, std::memory_order_relaxed);
                return;
            }
            st = expected;
        }
        while (st == 1) { // another thread is writing the strings: a few instructions
            std::this_thread::yield();
            st = s.state.load(std::memory_order_acquire);
        }
        if (s.hash == h && category == s.category && key == s.key) {
            s.count.fetch_add(1, std::memory_order_relaxed);
            return;
        }
    }
    t.overflow.fetch_add(1, std::memory_order_relaxed);
}

std::vector<Entry> Snapshot() {
    Table& t = table();
    std::vector<Entry> out;
    for (Slot& s : t.slots) {
        if (s.state.load(std::memory_order_acquire) != 2) continue;
        out.push_back({s.category, s.key, s.detail, s.count.load(std::memory_order_relaxed)});
    }
    std::sort(out.begin(), out.end(), [](const Entry& a, const Entry& b) {
        if (a.category != b.category) return a.category < b.category;
        if (a.count != b.count) return a.count > b.count;
        return a.key < b.key;
    });
    return out;
}

uint64_t Overflowed() {
    return table().overflow.load(std::memory_order_relaxed);
}

void Flush(bool all) {
    Table& t = table();
    std::scoped_lock lock{t.flushLock};
    struct Row {
        Slot* slot;
        uint64_t count, delta;
    };
    std::vector<Row> rows;
    uint64_t events = 0;
    size_t keys = 0;
    for (Slot& s : t.slots) {
        if (s.state.load(std::memory_order_acquire) != 2) continue;
        const uint64_t c = s.count.load(std::memory_order_relaxed);
        const uint64_t printed = s.printed.load(std::memory_order_relaxed);
        ++keys;
        events += c;
        if (all || c != printed) rows.push_back({&s, c, c - printed});
    }
    const uint64_t overflow = t.overflow.load(std::memory_order_relaxed);
    if (rows.empty() && (!all || keys == 0) && overflow == t.printedOverflow) return;
    std::sort(rows.begin(), rows.end(), [](const Row& a, const Row& b) {
        if (int c = std::strcmp(a.slot->category, b.slot->category)) return c < 0;
        if (a.count != b.count) return a.count > b.count;
        return std::strcmp(a.slot->key, b.slot->key) < 0;
    });
    char line[512];
    std::snprintf(line, sizeof line, "PS4_CENSUS %s: %zu keys, %llu events%s", all ? "total" : "summary", keys,
                  (unsigned long long)events, overflow ? " (table full: some keys only counted together)" : "");
    emit(line);
    const size_t limit = all ? 500 : 150;
    size_t shown = 0;
    for (const Row& r : rows) {
        if (shown++ == limit) {
            std::snprintf(line, sizeof line, "PS4_CENSUS ... %zu more keys", rows.size() - limit);
            emit(line);
            break;
        }
        std::snprintf(line, sizeof line, "PS4_CENSUS [%s] %s x%llu (+%llu)%s%s", r.slot->category, r.slot->key,
                      (unsigned long long)r.count, (unsigned long long)r.delta, r.slot->detail[0] ? " first: " : "",
                      r.slot->detail);
        emit(line);
    }
    for (const Row& r : rows) r.slot->printed.store(r.count, std::memory_order_relaxed);
    t.printedOverflow = overflow;
}

void ResetForTests() {
    Table& t = table();
    std::scoped_lock lock{t.flushLock};
    for (Slot& s : t.slots) {
        s.state.store(0);
        s.count.store(0);
        s.printed.store(0);
    }
    t.overflow.store(0);
    t.printedOverflow = 0;
}

} // namespace Census

extern "C" void vpkengine_census_note(const char* category, const char* key, const char* detail) {
    Census::Note(category ? category : "?", key ? key : "?", detail ? detail : "");
}
