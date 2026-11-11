// Checks which of the title's finished frames the headset takes (core/vr/frame_queue.h, which
// holds nothing of the emulator and is compiled here alone): two deliveries between two takes
// are both shown, in order; a third gives the oldest up; the slots never run out.
//
//   g++ -std=c++20 -Wall -Wextra -I shadps4-arm64-main/src tools/tests/frame_queue_test.cpp
//       -o build/tests/frame_queue_test
//   build/tests/frame_queue_test
//
// -DQUEUE_LATEST builds it with the old behaviour (only the newest is kept), which fails.
#include <cstdio>
#include <string>
#include <vector>

#include "core/vr/frame_queue.h"

using namespace Core::Vr;

static int failures = 0;

static void Check(bool ok, const std::string& what) {
    std::printf("%s  %s\n", ok ? "ok  " : "FAIL", what.c_str());
    failures += ok ? 0 : 1;
}

constexpr std::size_t Slots = 8;
using Queue = FrameQueue<Slots>;

static Queue Make(bool latest = false) {
    Queue queue;
#ifdef QUEUE_LATEST
    latest = true;
#endif
    queue.take_latest = latest;
    return queue;
}

/// What the host does for a frame: finds a slot to draw into, draws, delivers. -1: none free.
static int Deliver(Queue& queue, std::size_t& next) {
    for (std::size_t attempt = 0; attempt < Slots; ++attempt) {
        const std::size_t slot = (next + attempt) % Slots;
        if (queue.Reusable(slot)) {
            next = (slot + 1) % Slots;
            queue.Begin(slot);
            queue.End(slot);
            return static_cast<int>(slot);
        }
    }
    return -1;
}

int main() {
    std::size_t next = 0;
    {
        Queue queue = Make();
        Check(queue.Take() == -1, "nothing delivered: nothing to take");
    }
    {
        Queue queue = Make(true);
        const int a = Deliver(queue, next);
        Check(queue.Take() == a, "one pending: taken (take latest)");
        Check(queue.Take() == -1, "the same frame is not taken twice (take latest)");
    }
    {
        Queue queue = Make();
        const int a = Deliver(queue, next);
        Check(queue.Take() == a, "one pending: taken");
        Check(queue.Take() == -1, "the same frame is not taken twice");
        queue.Return(static_cast<std::size_t>(a));
        Check(queue.State(static_cast<std::size_t>(a)) == SlotState::Free, "returned: free again");
        Check(queue.superseded == 0, "one pending: nothing given up");
    }
    {
        Queue queue = Make();
        const int a = Deliver(queue, next);
        const int b = Deliver(queue, next);
        Check(queue.Take() == a, "two pending: the older is taken first");
        Check(queue.Take() == b, "two pending: then the newer");
        Check(queue.Take() == -1, "two pending: and nothing more");
        Check(queue.superseded == 0, "two pending: none given up");
    }
    {
        Queue queue = Make();
        const int a = Deliver(queue, next);
        const int b = Deliver(queue, next);
        const int c = Deliver(queue, next);
        Check(queue.Reusable(static_cast<std::size_t>(a)), "three pending: the oldest may be drawn over");
        Check(!queue.Reusable(static_cast<std::size_t>(b)) && !queue.Reusable(static_cast<std::size_t>(c)),
              "three pending: the two newest are kept");
        Check(queue.Take() == b, "three pending: the second oldest is taken");
        Check(queue.Take() == c, "three pending: then the newest");
        Check(queue.Take() == -1, "three pending: and the oldest is not");
        queue.Begin(static_cast<std::size_t>(a));
        Check(queue.superseded == 1, "three pending: the oldest counts as given up");
    }
    {
        // After the older one was taken, a new delivery keeps the order: b, c.
        Queue queue = Make();
        const int a = Deliver(queue, next);
        const int b = Deliver(queue, next);
        Check(queue.Take() == a, "interleaved: a first");
        const int c = Deliver(queue, next);
        Check(queue.Take() == b, "interleaved: then b");
        Check(queue.Take() == c, "interleaved: then c");
    }
    {
        // Old behaviour, asked for: only the newest is taken; the one before is given up.
        Queue queue = Make(true);
        const int a = Deliver(queue, next);
        const int b = Deliver(queue, next);
        Check(queue.Reusable(static_cast<std::size_t>(a)), "take latest: the older is free to draw over");
        Check(queue.Take() == b, "take latest: the newest is taken");
        Check(queue.Take() == -1, "take latest: nothing more");
        Check(queue.Reusable(static_cast<std::size_t>(a)), "take latest: the older one stays free to draw over");
    }
    {
        // A drawn frame that is dropped frees its slot, and cannot be delivered.
        Queue queue = Make();
        queue.Begin(0);
        queue.Drop(0);
        Check(queue.State(0) == SlotState::Free && !queue.End(0), "dropped: free, and not delivered");
    }
    {
        // The slots never run out with at most 3 being drawn and 2 being read (the GPU a frame or
        // two ahead, the frame shown and the one the GPU still reads): 3 + 2 + 2 kept < 8.
        Queue queue = Make();
        std::size_t cursor = 0;
        std::vector<int> drawing, reading;
        unsigned seed = 12345;
        bool ran_out = false;
        int last_shown = -1;
        unsigned long long last_order = 0, delivered_order = 0;
        std::vector<unsigned long long> order(Slots, 0);
        bool in_order = true;
        for (int step = 0; step < 100000 && !ran_out; ++step) {
            seed = seed * 1103515245u + 12345u;
            switch ((seed >> 16) % 4) {
            case 0:
                if (drawing.size() < 3) {
                    int slot = -1;
                    for (std::size_t attempt = 0; attempt < Slots && slot < 0; ++attempt) {
                        const std::size_t s = (cursor + attempt) % Slots;
                        if (queue.Reusable(s)) {
                            slot = static_cast<int>(s);
                            cursor = (s + 1) % Slots;
                        }
                    }
                    if (slot < 0) {
                        ran_out = true;
                    } else {
                        queue.Begin(static_cast<std::size_t>(slot));
                        drawing.push_back(slot);
                    }
                }
                break;
            case 1:
                if (!drawing.empty()) {
                    queue.End(static_cast<std::size_t>(drawing.front()));
                    order[static_cast<std::size_t>(drawing.front())] = ++delivered_order;
                    drawing.erase(drawing.begin());
                }
                break;
            case 2:
                if (reading.size() < 2) {
                    const int slot = queue.Take();
                    if (slot >= 0) {
                        in_order = in_order && order[static_cast<std::size_t>(slot)] > last_order;
                        last_order = order[static_cast<std::size_t>(slot)];
                        last_shown = slot;
                        reading.push_back(slot);
                    }
                }
                break;
            default:
                if (!reading.empty()) {
                    queue.Return(static_cast<std::size_t>(reading.front()));
                    reading.erase(reading.begin());
                }
                break;
            }
        }
        Check(!ran_out, "8 slots: a slot is always free to draw into");
        Check(in_order, "frames are taken in the order they were delivered");
        Check(last_shown >= 0, "frames were taken");
    }
    std::printf("%d failure(s)\n", failures);
    return failures != 0;
}
