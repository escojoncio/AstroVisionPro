// Census: what the GPU emulation ignores or approximates, counted. Always on and cheap (a hash
// lookup and one relaxed atomic add per event, no lock, no allocation after the first sighting of a
// key), except the "reg" category: the audit of the context registers runs only in diagnostics mode,
// on one draw in 64. A summary goes to the log every 10 s and at exit: category, key, count, first detail.
//
// Anything the emulation skips, stubs or approximates reports itself here (unhandled PM4 opcodes,
// draws left out and why, shader translation errors, unsupported formats / tile modes, context
// registers set to non-reset values that nothing reads): the list in the log is the work list.
//
// Plain C++ with no emulator dependency (tests/video_core/test_census.cpp builds it alone).
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace Census {

// Receives one summary line at a time (already prefixed "PS4_CENSUS"). Default: stderr.
using Sink = void (*)(std::string_view line);
void SetSink(Sink sink);

// Seconds between summaries (default 10). 0 stops the periodic summary (the one at exit remains).
void SetPeriodSeconds(unsigned seconds);

// One event. `category` groups ("pm4", "draw-skip", "shader", "format", "reg", ...), `key` names
// what happened (an opcode, a reason, a register=value), `detail` is kept from the first sighting
// only (truncated to 127 bytes). Keys longer than 95 bytes are cut. Thread-safe.
void Note(std::string_view category, std::string_view key, std::string_view detail = {});
// `count` events of one key at once (callers that aggregate per frame).
void NoteN(std::string_view category, std::string_view key, std::string_view detail, uint64_t count);

// Writes the final summary now and stops the periodic summary and the one at exit: for the owner of the
// log to call before it tears the log down (a summary written after the log sink is gone is lost, or
// worse, uses a dead sink). Events after it are still counted. Safe to call more than once.
void Shutdown();

struct Entry {
    std::string category;
    std::string key;
    std::string detail;  // of the first event
    uint64_t count = 0;
};

// Every key seen so far, sorted by category then count (descending).
std::vector<Entry> Snapshot();

// Writes the summary to the sink: with `all` false only when something happened since the last
// summary (and only keys with new events), with `all` true every key.
void Flush(bool all);

// Distinct keys that did not fit in the table (their events are counted here, not per key).
uint64_t Overflowed();

// Tests: forget everything.
void ResetForTests();

} // namespace Census

// For code that must not depend on C++ (VPKEngine reports through vpps4::setReportSink; the
// integration wires that sink to this).
extern "C" void vpkengine_census_note(const char* category, const char* key, const char* detail);
