// Checks the count of the writes that can change a draw's fixed state (video_core/amdgpu/state_serial.h, which holds nothing of
// the emulator and is compiled here alone) and that the command processor (video_core/amdgpu/liverpool.cpp, which cannot be
// compiled here) counts every write of the register file: the source is read, and each place that writes the register file
// must be one that counts (a write that is not found there fails the test and has to be looked at).
//
//   g++ -std=c++20 -Wall -Wextra -I shadps4-arm64-main/src tools/tests/state_serial_test.cpp
//       -o build/tests/state_serial_test
//   build/tests/state_serial_test shadps4-arm64-main/src/video_core/amdgpu/liverpool.cpp
#include <array>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

#include "video_core/amdgpu/state_serial.h"

using namespace AmdGpu;

static int failures = 0;

static void Check(bool ok, const std::string& what) {
    std::printf("%s  %s\n", ok ? "ok  " : "FAIL", what.c_str());
    failures += ok ? 0 : 1;
}

static void Unit() {
    constexpr std::array<RegRange, 2> inert = {RegRange{10, 12}, RegRange{20, 21}};
    std::array<std::uint32_t, 32> file{};
    StateSerial serial;
    const std::uint64_t start = serial.Value();
    Check(start != 0, "a new serial is not 0 (0 is 'not known')");

    const std::uint32_t same[3] = {0, 0, 0};
    serial.Write(file.data(), 4, same, 3, inert);
    Check(serial.Value() == start, "a write of what the registers hold does not move it");

    const std::uint32_t one[1] = {7};
    serial.Write(file.data(), 4, one, 1, inert);
    Check(serial.Value() == start + 1 && file[4] == 7, "a write that changes a register moves it, once, and lands");

    const std::uint32_t many[3] = {1, 2, 3};
    serial.Write(file.data(), 4, many, 3, inert);
    Check(serial.Value() == start + 2 && file[5] == 2 && file[6] == 3, "a write of several changed registers moves it once");
    serial.Write(file.data(), 4, many, 3, inert);
    Check(serial.Value() == start + 2, "and the same again does not");

    const std::uint32_t inertOnly[2] = {5, 6};
    serial.Write(file.data(), 10, inertOnly, 2, inert);
    Check(serial.Value() == start + 2 && file[10] == 5 && file[11] == 6, "a change of inert registers alone leaves it, and lands");
    serial.Write(file.data(), 20, one, 1, inert);
    Check(serial.Value() == start + 2 && file[20] == 7, "... a range of one too");

    const std::uint32_t edge[1] = {9};
    serial.Write(file.data(), 12, edge, 1, inert);
    Check(serial.Value() == start + 3, "the end of an inert range is not in it");
    serial.Write(file.data(), 9, edge, 1, inert);
    Check(serial.Value() == start + 4, "the register before an inert range is not in it");

    const std::uint32_t mixed[4] = {1, 1, 1, 1};
    serial.Write(file.data(), 9, mixed, 4, inert);  // 9 (changes), 10, 11 (inert), 12 (changes)
    Check(serial.Value() == start + 5, "inert registers and others changed in one write move it");
    const std::uint32_t reinert[2] = {0, 0};
    serial.Write(file.data(), 10, reinert, 2, inert);
    const std::uint32_t tail[3] = {1, 0, 0};
    serial.Write(file.data(), 9, tail, 3, inert);
    Check(serial.Value() == start + 5, "a write that changes only inert registers inside a longer one that equals the rest does not");

    serial.Write(file.data(), 4, many, 0, inert);
    Check(serial.Value() == start + 5, "a write of no registers does not");

    serial.Bump();
    Check(serial.Value() == start + 6, "Bump moves it");

    serial.Write(file.data(), 4, many, 3, {});
    Check(serial.Value() == start + 6, "with no inert registers an equal write still does not");
    const std::uint32_t other[1] = {42};
    serial.Write(file.data(), 10, other, 1, {});
    Check(serial.Value() == start + 7, "... and a changed register that would be inert does");
}

static std::vector<std::string> Lines(const std::string& path) {
    std::vector<std::string> out;
    std::ifstream in(path);
    for (std::string line; std::getline(in, line);) {
        out.push_back(line);
    }
    return out;
}

static bool Has(const std::string& line, const std::string& part) {
    return line.find(part) != std::string::npos;
}

static bool NearBefore(const std::vector<std::string>& lines, size_t at, size_t within, const std::string& part) {
    for (size_t k = at >= within ? at - within : 0; k <= at; ++k) {
        if (Has(lines[k], part)) {
            return true;
        }
    }
    return false;
}

static bool NearAfter(const std::vector<std::string>& lines, size_t at, size_t within, const std::string& part) {
    for (size_t k = at; k < lines.size() && k <= at + within; ++k) {
        if (Has(lines[k], part)) {
            return true;
        }
    }
    return false;
}

// The registers a draw packet writes by name: the fixed state does not follow them (liverpool.h, state_serial).
static bool DrawPacketRegister(const std::string& line) {
    for (const char* name : {"regs.index_buffer_type.raw =", "regs.max_index_size =", "regs.index_base_address.base_addr_lo =",
                             "regs.index_base_address.base_addr_hi =", "regs.num_indices =", "regs.draw_initiator =",
                             "regs.num_instances.num_instances =", "regs.cp_strmout_cntl.offset_update_done ="}) {
        if (Has(line, name)) {
            return true;
        }
    }
    return false;
}

static void Source(const std::string& path) {
    const std::vector<std::string> lines = Lines(path);
    Check(lines.size() > 1000, "the source of the command processor is there (" + path + ")");
    size_t writes = 0, reads = 0, consumers = 0, extents = 0, named = 0, regPtr = 0, clears = 0;
    for (size_t i = 0; i < lines.size(); ++i) {
        const std::string& l = lines[i];
        const std::string where = ":" + std::to_string(i + 1) + ": " + l;
        if (Has(l, "reg_array")) {
            if (Has(l, "state_serial.Write(regs.reg_array.data()")) {
                ++writes;
            } else if (Has(l, "ConsumePm4Type0(") || Has(l, "ConsumePm4Type1(")) {
                ++consumers;
                Check(NearBefore(lines, i, 1, "state_serial.Bump()"), "a type 0/1 packet writes registers, counted" + where);
            } else if (Has(l, "Test(regs.reg_array)") || Has(l, "regs.reg_array[wait_reg_mem->Reg()]")) {
                ++reads;
            } else if (Has(l, "return mmio < Regs::NumRegs ? &regs.reg_array[mmio]")) {
                ++regPtr;
                Check(NearBefore(lines, i, 8, "state_serial.Bump()"), "RegPtr counts, whoever writes through it" + where);
            } else if (Has(l, "//")) {
                continue;
            } else {
                Check(false, "a use of the register file that does not count (and is not a read the test knows)" + where);
            }
        }
        if (Has(l, "regs.SetDefaults()")) {
            ++clears;
            Check(NearAfter(lines, i, 1, "state_serial.Bump()"), "CLEAR_STATE counts" + where);
        }
        if ((Has(l, "last_cb_extent[") && Has(l, ".raw =")) || Has(l, "last_db_extent.raw =")) {
            ++extents;
            Check(NearAfter(lines, i, 6, "state_serial.Bump()"), "a size taken from a NOP hint counts" + where);
        }
        // A register written by name (a statement that starts with a field of `regs`): only the draw packets' own.
        const size_t first = l.find_first_not_of(' ');
        if (first != std::string::npos && l.compare(first, 5, "regs.") == 0 && Has(l, " = ")) {
            ++named;
            Check(DrawPacketRegister(l), "a register written by name is one the fixed state does not follow" + where);
        }
    }
    Check(writes == 5, "the set-register packets (config, context, gfx SH, uconfig, ASC SH) go through StateSerial::Write: " + std::to_string(writes));
    Check(consumers == 6, "the six places that consume type 0/1 packets count: " + std::to_string(consumers));
    Check(regPtr == 1 && clears == 1, "RegPtr and CLEAR_STATE are found once");
    Check(extents == 5, "the five assignments of a size hint count: " + std::to_string(extents));
    Check(named >= 8, "the draw packets' own registers were looked at: " + std::to_string(named));
    Check(reads >= 2, "the reads of the register file were looked at: " + std::to_string(reads));
}

int main(int argc, char** argv) {
    Unit();
    if (argc > 1) {
        Source(argv[1]);
    } else {
        Check(false, "no source path given (build/tests/state_serial_test <liverpool.cpp>)");
    }
    std::printf("%s\n", failures ? "FAILED" : "all ok");
    return failures ? 1 : 0;
}
