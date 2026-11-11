// Checks what the sampling CPU profiler does without the system (common/cpu_profile.h, which
// holds nothing of the emulator and is compiled here alone): the walk over a stopped thread's
// frame records, which reads nothing it was not told is readable; the folding of addresses into
// functions; the fixed tables of stacks and frames; and the file's text.
//
//   g++ -std=c++20 -Wall -Wextra -I shadps4-arm64-main/src tools/tests/cpu_profile_test.cpp
//       -o build/tests/cpu_profile_test
//   build/tests/cpu_profile_test [<sample.txt>]
//
// With a path, it also writes a profile there for tools/tests/symbolize_cpuprof_test.py.
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <string>
#include <vector>

#include "common/cpu_profile.h"

using namespace Common::CpuProfile;

static int failures = 0;

static void Check(bool ok, const std::string& what) {
    std::printf("%s  %s\n", ok ? "ok  " : "FAIL", what.c_str());
    failures += ok ? 0 : 1;
}

static u64 Address(const u64* word) {
    return static_cast<u64>(reinterpret_cast<std::uintptr_t>(word));
}

// The image of the tests: three functions (alpha, beta, gamma) and the JIT's code elsewhere.
constexpr u64 Base = 0x2'0000'0000;
constexpr u64 Alpha = Base + 0x1000;
constexpr u64 Beta = Base + 0x1040;
constexpr u64 Gamma = Base + 0x116c;
constexpr u64 Library = 0x7'0000'0000; // (some other image)

static Image MakeImage() {
    Image image;
    image.name = "AstroQuest";
    image.uuid = "0A1B2C3D4E5F60718293A4B5C6D7E8F9";
    image.base = Base;
    image.vmaddr = 0x1'0000'0000;
    image.size = 0x4000;
    image.starts = {0x1000, 0x1040, 0x116c};
    image.jit_begin = 0x9'0000'0000;
    image.jit_end = 0x9'0008'0000;
    return image;
}

// The stopped thread's stack as the kernel copies it: only what is inside it can be had.
struct FakeKernel {
    u64 lo;
    u64 hi;
    int reads = 0;
    bool gone = false;    // (the thread has ended: its stack is no longer there)
    bool strayed = false; // (something that is not the stack was asked for)

    bool operator()(u64 address, u64* words, u64 bytes) {
        ++reads;
        if (gone) {
            return false;
        }
        if (address < lo || address > hi || hi - address < bytes) {
            strayed = true;
            return false;
        }
        std::memcpy(words, reinterpret_cast<const void*>(static_cast<std::uintptr_t>(address)), bytes);
        return true;
    }
};

static void TestWalk() {
    std::vector<u64> memory(8192, 0);
    u64* const stack = memory.data();
    const u64 size = memory.size();
    alignas(16) u64 other[4] = {}; // (not the thread's stack: a signal's, the heap)
    const u64 lo = Address(stack);
    const u64 hi = Address(stack + size);
    RawStack raw;
    const auto walk = [&](u64 fp, FakeKernel& kernel) { WalkFrames(fp, lo, hi, kernel, raw); };

    // (the high half of stack[5] is a signature to the aligned walk, and a return address to one
    // that would read the record four bytes further on)
    stack[4] = Address(stack + 10), stack[5] = 0x5000 | (0x9000ull << 32);
    stack[10] = Address(stack + 20), stack[11] = 0x6000 | (0xabull << 56);
    {
        FakeKernel kernel{lo, hi};
        walk(Address(stack + 4), kernel);
        Check(raw.count == 2 && raw.rets[0] == 0x5000 && raw.rets[1] == 0x6000 && !raw.truncated,
              "the records are followed to the outermost; return addresses lose their signature");
        Check(kernel.reads == 1 && !kernel.strayed, "records near each other come in one copy");
    }
    {
        FakeKernel kernel{lo, hi};
        walk(Address(stack + 4) + 4, kernel);
        Check(raw.count == 0 && kernel.reads == 0, "a frame pointer that is not aligned is not read");
        walk(0x1000, kernel);
        walk(Address(other), kernel);
        walk(0, kernel);
        Check(raw.count == 0 && kernel.reads == 0, "a frame pointer outside the stack is not read");
        walk(Address(stack + size - 1), kernel);
        Check(raw.count == 0 && kernel.reads == 0, "a record that would end beyond the stack is not read");
    }
    {
        FakeKernel kernel{lo, hi};
        stack[30] = Address(stack + 30), stack[31] = 0x5000;
        walk(Address(stack + 30), kernel);
        Check(raw.count == 1, "a record that points to itself ends the walk");
        stack[30] = Address(stack + 4);
        walk(Address(stack + 30), kernel);
        Check(raw.count == 1, "a record that points down the stack ends the walk");
    }
    {
        FakeKernel kernel{lo, hi};
        other[0] = Address(stack + 4), other[1] = 0x7100;
        stack[40] = Address(other), stack[41] = 0x7000;
        walk(Address(stack + 40), kernel);
        Check(raw.count == 1 && raw.rets[0] == 0x7000 && kernel.reads == 1 && !kernel.strayed,
              "the walk ends where the records leave the stack: nothing else is read");
    }
    {
        FakeKernel kernel{lo, hi};
        stack[100] = Address(stack + 2000), stack[101] = 0x5100;
        stack[2000] = Address(stack + 5000), stack[2001] = 0x5200;
        walk(Address(stack + 100), kernel);
        Check(raw.count == 2 && raw.rets[1] == 0x5200 && kernel.reads == 3 && !kernel.strayed,
              "a record beyond what was copied is copied from where it is");
    }
    {
        FakeKernel kernel{lo, hi};
        stack[size - 6] = Address(stack + size - 4), stack[size - 5] = 0x5300;
        stack[size - 4] = 0, stack[size - 3] = 0x5400;
        walk(Address(stack + size - 6), kernel);
        Check(raw.count == 2 && raw.rets[1] == 0x5400 && kernel.reads == 1 && !kernel.strayed,
              "at the top of the stack only what is left of it is copied");
    }
    {
        FakeKernel kernel{lo, hi};
        for (u64 i = 0; i < 7; ++i) {
            stack[200 + 1100 * i] = Address(stack + 200 + 1100 * (i + 1));
            stack[201 + 1100 * i] = 0x8000 + 8 * i;
        }
        walk(Address(stack + 200), kernel);
        Check(raw.count == kMaxReads && raw.truncated && kernel.reads == static_cast<int>(kMaxReads),
              "only so many copies are made for a sample");
    }
    {
        FakeKernel kernel{lo, hi};
        for (u64 i = 0; i < 60; ++i) {
            stack[6000 + 2 * i] = Address(stack + 6000 + 2 * (i + 1));
            stack[6001 + 2 * i] = 0x8000 + 8 * i;
        }
        walk(Address(stack + 6000), kernel);
        Check(raw.count == kMaxDepth - 1 && raw.truncated && kernel.reads == 1 &&
                  raw.rets[kMaxDepth - 2] == 0x8000 + 8 * 46,
              "a stack deeper than the limit is cut and said to be");
    }
    {
        FakeKernel kernel{lo, hi};
        kernel.gone = true;
        walk(Address(stack + 4), kernel);
        Check(raw.count == 0 && !raw.truncated && kernel.reads == 1,
              "a thread that has ended gives no records, and nothing of its stack is touched");
    }

    // Only an image's code keeps a frame pointer: elsewhere (the JIT's) the stack is not walked.
    Image image = MakeImage();
    FakeKernel kernel{lo, hi};
    const u64 fp = Address(stack + 4);
    Capture(image.jit_begin + 0x40, Gamma + 0x14, fp, lo, hi, image, kernel, raw);
    Check(raw.pc == image.jit_begin + 0x40 && raw.count == 0 && kernel.reads == 0,
          "in the JIT's code the stack is not walked");
    Capture(Library + 0x24, 0, fp, lo, hi, image, kernel, raw);
    Check(raw.count == 0 && kernel.reads == 0 && image.Unknown(Library + 0x24) &&
              !image.Unknown(image.jit_begin) && !image.Unknown(Beta),
          "nor in code not yet known to be an image's, which is then to be asked about");
    image.pages.Set(Library + 0x24, false);
    Capture(Library + 0x24, 0, fp, lo, hi, image, kernel, raw);
    Check(raw.count == 0 && kernel.reads == 0 && !image.Unknown(Library + 0x24) &&
              image.Fold(Library + 0x3ff0) == kJit,
          "code found to be in no image is not walked, and counts as the JIT's");
    image.pages.Set(Library + 0x24, true);
    Capture(Library + 0x24, 0, fp, lo, hi, image, kernel, raw);
    Check(raw.count == 2 && kernel.reads == 1 && image.Fold(Library + 0x24) == Library + 0x24 &&
              image.Unknown(Library + 0x4000),
          "code found to be an image's is walked; the next page is another matter");
    kernel.reads = 0;
    Capture(Beta + 0x10, 0, fp, lo, hi, image, kernel, raw);
    Check(raw.count == 2 && kernel.reads == 1, "the app's own code is walked");
    image.pages.Set(Library + 0x24 + (4096ull << 14), false);
    Check(image.Unknown(Library + 0x24) && image.Fold(Library + 0x24 + (4096ull << 14)) == kJit,
          "a page that loses its place in the table is asked about again");
}

static void TestFunctions() {
    const u8 list[] = {0x80, 0x20, 0x40, 0xac, 0x02, 0x00, 0x05};
    Check(DecodeFunctionStarts(list, sizeof(list)) == std::vector<u32>({0x1000, 0x1040, 0x116c}),
          "the function starts are the running sum of the list's steps, up to its zero");
    Check(DecodeFunctionStarts(list, 0).empty(), "an empty list has no functions");
    const u8 open_ended[] = {0x80, 0x20, 0x80};
    Check(DecodeFunctionStarts(open_ended, sizeof(open_ended)) == std::vector<u32>({0x1000}),
          "a step cut by the list's end is not read past it");
    const std::vector<u8> endless(40, 0xff);
    DecodeFunctionStarts(endless.data(), endless.size());
    Check(true, "a step with no end ends");

    Image image = MakeImage();
    Check(image.Fold(Alpha) == Alpha && image.Fold(Alpha + 0x3c) == Alpha &&
              image.Fold(Beta) == Beta && image.Fold(Base + 0x3fff) == Gamma,
          "an address in the image counts as its function's start");
    Check(image.Fold(Base + 0x800) == Base + 0x800 && !image.Known(Base + 0x800),
          "an address before the first function stays itself");
    Check(image.Fold(Base + 0x4000) == Base + 0x4000 && image.Fold(Base - 4) == Base - 4 &&
              image.Fold(Library + 0x24) == Library + 0x24,
          "an address outside the image stays itself");
    Check(image.Fold(image.jit_begin) == kJit && image.Fold(image.jit_end - 4) == kJit &&
              image.Fold(image.jit_end) == image.jit_end,
          "the JIT's code is one frame");
    image.starts.clear();
    Check(image.Fold(Alpha + 0x3c) == Alpha + 0x3c && !image.Known(Alpha),
          "without the list of functions the addresses stay themselves");
}

static std::vector<u64> Folded(const RawStack& raw, const Image& image) {
    u64 frames[kMaxDepth];
    const u32 depth = FoldStack(raw, image, frames);
    return std::vector<u64>(frames, frames + depth);
}

static void TestFold() {
    const Image image = MakeImage();
    RawStack raw;

    // beta, a leaf with no frame record, called by gamma, called by alpha.
    raw.pc = Beta + 0x10, raw.lr = (Gamma + 0x14) | (0x5aull << 56);
    raw.rets[0] = Alpha + 0x10, raw.count = 1;
    Check(Folded(raw, image) == std::vector<u64>({Beta, Gamma, Alpha}),
          "a function without a frame record has its caller from the link register");
    raw.count = 0;
    Check(Folded(raw, image) == std::vector<u64>({Beta, Gamma}), "... with no record at all too");

    // beta with a record, before its first call: the register and the record say the same.
    raw.rets[0] = Gamma + 0x14, raw.rets[1] = Alpha + 0x10, raw.count = 2;
    Check(Folded(raw, image) == std::vector<u64>({Beta, Gamma, Alpha}),
          "a caller is not counted twice when the register repeats the record");
    // ... and after a call: the register points into beta.
    raw.lr = Beta + 0x20;
    Check(Folded(raw, image) == std::vector<u64>({Beta, Gamma, Alpha}),
          "a link register left by the function's own call adds no frame");

    raw.pc = Library + 0x24, raw.lr = Gamma + 0x14;
    raw.rets[0] = Library + 0x104, raw.rets[1] = Alpha + 0x10;
    Check(Folded(raw, image) == std::vector<u64>({Library + 0x24, Library + 0x100, Alpha}),
          "outside the image the link register is left out and a return address goes back to "
          "its call");

    raw.rets[0] = Beta, raw.count = 1;
    Check(Folded(raw, image) == std::vector<u64>({Library + 0x24, Alpha}),
          "a call that is a function's last instruction is still of that function");

    raw.pc = image.jit_begin + 0x123, raw.rets[1] = Gamma + 0x14, raw.count = 2;
    Check(Folded(raw, image) == std::vector<u64>({kJit}),
          "a sample in the JIT's code is that one frame, whatever else was read");

    raw.pc = Beta + 0x10, raw.lr = 0;
    for (u32 i = 0; i < kMaxDepth - 1; ++i) {
        raw.rets[i] = Library + 0x100 * (i + 1);
    }
    raw.count = kMaxDepth - 1, raw.truncated = true;
    std::vector<u64> frames = Folded(raw, image);
    Check(frames.size() == kMaxDepth && frames[0] == Beta && frames[kMaxDepth - 1] == kTruncated,
          "a cut stack ends in the frame that says so");
    raw.truncated = false, raw.lr = Gamma + 0x14;
    frames = Folded(raw, image);
    Check(frames.size() == kMaxDepth && frames[1] == Gamma && frames[kMaxDepth - 1] == kTruncated,
          "a stack the link register's frame makes too deep is cut too");
    raw.lr = 0;
    frames = Folded(raw, image);
    Check(frames.size() == kMaxDepth && frames[kMaxDepth - 1] == Library + 0x100 * 47 - 4,
          "a stack of exactly the limit is whole");
    raw.count = 2, raw.truncated = true;
    Check(Folded(raw, image) ==
              std::vector<u64>({Beta, Library + 0x100 - 4, Library + 0x200 - 4, kTruncated}),
          "a walk given up early says so after its last frame");
}

static std::map<std::vector<u64>, u32> Stacks(const StackTable& table) {
    std::map<std::vector<u64>, u32> stacks;
    table.ForEach([&](const u64* frames, u32 depth, u32 count) {
        stacks[std::vector<u64>(frames, frames + depth)] += count;
    });
    return stacks;
}

static void TestTables() {
    const u64 a[] = {Beta, Gamma, Alpha};
    const u64 b[] = {Gamma, Alpha};
    {
        StackTable table{16, 64};
        Check(table.Add(a, 3) && table.Add(b, 2) && table.Add(a, 3) && table.Add(a, 2),
              "stacks are counted");
        const auto stacks = Stacks(table);
        Check(table.Size() == 3 && stacks.size() == 3 && stacks.at({Beta, Gamma, Alpha}) == 2 &&
                  stacks.at({Gamma, Alpha}) == 1 && stacks.at({Beta, Gamma}) == 1,
              "the same stack adds up; a stack that starts like another is its own");
        table.Clear();
        Check(table.Size() == 0 && Stacks(table).empty() && table.Add(a, 3) &&
                  Stacks(table).at({Beta, Gamma, Alpha}) == 1,
              "a cleared table starts again");
    }
    {
        StackTable table{8, 64};
        bool room = true;
        for (u64 i = 0; i < 6; ++i) {
            room = room && table.Add(&i, 1);
        }
        const u64 more = 100;
        Check(room && !table.Add(&more, 1) && !table.Add(a, 3) && table.Size() == 6,
              "a full table turns new stacks down");
        const u64 old = 3;
        Check(table.Add(&old, 1) && Stacks(table).at({3}) == 2 && Stacks(table).size() == 6,
              "... and goes on counting the ones it has");
    }
    {
        StackTable table{16, 5};
        Check(table.Add(a, 3) && table.Add(a, 3), "the same stack needs no more room");
        const u64 c[] = {1, 2, 3};
        Check(!table.Add(c, 3) && table.Add(b, 2) && !table.Add(c, 1) && table.Size() == 2,
              "a stack the pool of frames has no room for is turned down");
    }
    {
        PcTable table{16};
        const u64 again[] = {Beta, Beta, Alpha, kTruncated};
        Check(table.Add(a, 3) && table.Add(a, 3) && table.Add(b, 2) && table.Add(again, 4),
              "frames are counted");
        std::map<u64, PcTable::Entry> entries;
        table.ForEach([&](const PcTable::Entry& entry) { entries[entry.address] = entry; });
        Check(entries.size() == 3 && entries[Beta].exclusive == 3 && entries[Beta].inclusive == 3 &&
                  entries[Gamma].exclusive == 1 && entries[Gamma].inclusive == 3 &&
                  entries[Alpha].exclusive == 0 && entries[Alpha].inclusive == 4,
              "exclusive: the leaf's; inclusive: once a sample for each frame of the stack, "
              "recursion or not");
        table.Clear();
        const u64 zero = 0;
        table.Add(&zero, 1);
        entries.clear();
        table.ForEach([&](const PcTable::Entry& entry) { entries[entry.address] = entry; });
        Check(entries.size() == 1 && entries[0].exclusive == 1, "a cleared table starts again");
    }
    {
        PcTable table{8};
        bool room = true;
        for (u64 i = 10; i < 16; ++i) {
            room = room && table.Add(&i, 1);
        }
        const u64 mixed[] = {12, 99};
        std::map<u64, PcTable::Entry> entries;
        Check(room && !table.Add(mixed, 2), "a full table turns new frames down");
        table.ForEach([&](const PcTable::Entry& entry) { entries[entry.address] = entry; });
        Check(entries.size() == 6 && entries[12].exclusive == 2,
              "... and goes on counting the ones it has");
    }
    {
        ThreadProfile thread{"cp", 8, 64, 8};
        for (u64 i = 10; i < 18; ++i) {
            const u64 stack[] = {i, 50};
            thread.Add(stack, 2);
        }
        Check(thread.samples == 8 && thread.stacks_dropped == 2 && thread.pcs_dropped == 3,
              "the samples that found no room are told");
        thread.missed = 4, thread.suspended_ns = 5;
        thread.Clear();
        Check(thread.samples == 0 && thread.missed == 0 && thread.suspended_ns == 0 &&
                  thread.stacks_dropped == 0 && thread.pcs_dropped == 0 && thread.stacks.Size() == 0,
              "a cleared thread starts again");
    }
}

// How the headset names frames (platform/visionos/cpu_profiler_mach.cpp), with one other image.
static std::string Frame(const Image& image, u64 address) {
    if (address == kJit) {
        return "[jit]";
    }
    if (address == kTruncated) {
        return "[truncated]";
    }
    if (image.Has(address)) {
        return ImageFrame(image.name, address - image.base);
    }
    return ImageFrame("lib system.dylib", address - Library);
}

static std::string Symbol(u64 address) {
    return address == Library + 0x100 ? "-[Lock wait:until;]" : address == Beta ? "_ZN4beta3runEv" : "";
}

static void Add(ThreadProfile& thread, std::vector<u64> frames, u32 times) {
    for (u32 i = 0; i < times; ++i) {
        thread.Add(frames.data(), static_cast<u32>(frames.size()));
    }
}

static void TestText(const char* sample_path) {
    const Image image = MakeImage();
    const auto frame = [&](u64 address) { return Frame(image, address); };

    ThreadProfile cp{"cp thread", 64, 256, 64};
    Add(cp, {Beta, Gamma, Alpha}, 5);
    Add(cp, {Library + 0x100, Gamma, Alpha}, 3);
    Add(cp, {Gamma, Alpha}, 3);
    Add(cp, {kJit}, 1);
    cp.missed = 2;
    cp.suspended_ns = 123'456;

    std::string text;
    WriteHeader(text, image);
    BeginInterval(text, 0.0, 30.002, "2026-01-02_03-04-05");
    WriteThread(text, cp, frame, Symbol, 2);
    EndInterval(text);
    const std::string expected =
        "cpuprof 1\n"
        "IGNORED\n"
        "image AstroQuest uuid=0A1B2C3D4E5F60718293A4B5C6D7E8F9 slide=0x100000000 "
        "vmaddr=0x100000000 functions=3\n"
        "interval t0=0.000 t1=30.002 wall=2026-01-02_03-04-05\n"
        "thread cp_thread samples=12 missed=2 suspended_us=123 stacks=4 stacks_dropped=0 "
        "pcs_dropped=0\n"
        "excl 2\n"
        "5 AstroQuest+0x1040=_ZN4beta3runEv\n"
        "3 AstroQuest+0x116c\n"
        "incl 2\n"
        "11 AstroQuest+0x1000\n"
        "11 AstroQuest+0x116c\n"
        "folded 2\n"
        "AstroQuest+0x1000;AstroQuest+0x116c;AstroQuest+0x1040 5\n"
        "AstroQuest+0x1000;AstroQuest+0x116c 3\n"
        "end\n";
    // (the second line explains the file to who reads it: any text, as long as it is a comment)
    const std::size_t comment = text.find('\n') + 1;
    const std::size_t comment_end = text.find('\n', comment);
    Check(text[comment] == '#', "the header's second line is a comment");
    text.replace(comment, comment_end - comment, "IGNORED");
    if (text != expected) {
        std::printf("---- written\n%s---- expected\n%s----\n", text.c_str(), expected.c_str());
    }
    Check(text == expected,
          "the file: the hottest frames and stacks first, stacks from the root, names without "
          "spaces");

    text.clear();
    WriteThread(text, cp, frame, Symbol);
    Check(text.find("excl 4\n") != std::string::npos && text.find("incl 5\n") != std::string::npos &&
              text.find("folded 4\n") != std::string::npos &&
              text.find("\n3 lib_system.dylib+0x100=-[Lock_wait:until_]\n") != std::string::npos &&
              text.find("\n[jit] 1\n") != std::string::npos,
          "every frame with samples of its own is listed, every frame, every stack");

    if (sample_path == nullptr) {
        return;
    }
    // Two whole intervals and one the app's end cut short.
    ThreadProfile game{"game_main", 64, 256, 64};
    Add(game, {kJit}, 20);
    Add(game, {Alpha + 0, kJit}, 10);
    game.suspended_ns = 300'000'000;
    cp.suspended_ns = 600'000'000;
    std::string sample;
    WriteHeader(sample, image);
    BeginInterval(sample, 0.0, 30.0, "2026-01-02_03-04-05");
    WriteThread(sample, cp, frame, Symbol);
    WriteThread(sample, game, frame, Symbol);
    EndInterval(sample);
    cp.Clear();
    Add(cp, {Beta, Gamma, Alpha}, 2);
    Add(cp, {Library + 0x100, Library + 0x200, Alpha}, 6);
    BeginInterval(sample, 30.0, 60.0, "2026-01-02_03-04-35");
    WriteThread(sample, cp, frame, Symbol);
    EndInterval(sample);
    std::string cut;
    BeginInterval(cut, 60.0, 90.0, "2026-01-02_03-05-05");
    Add(cp, {Gamma, Alpha}, 1000);
    WriteThread(cut, cp, frame, Symbol);
    sample += cut.substr(0, cut.size() - 30);
    std::ofstream{sample_path} << sample;
    std::printf("sample written to %s\n", sample_path);
}

int main(int argc, char** argv) {
    TestWalk();
    TestFunctions();
    TestFold();
    TestTables();
    TestText(argc > 1 ? argv[1] : nullptr);
    std::printf("%d failure(s)\n", failures);
    return failures != 0;
}
