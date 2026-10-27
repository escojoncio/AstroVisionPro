// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <string_view>
#include <tuple>
#include <vector>

#include "video_core/shadow_record.h"

/// ASTRO_RENDERER=shadow: compares the two halves of a Record and writes only the differences, to learn what
/// VPKEngine (the vpk half) does differently from shadPS4's Vulkan renderer (the vk half, the reference).
///   ASTRO_SHADOW diff seq=<n> op=<op> field=<field> vk=<value> vpk=<value> pgm=<hash>
///   ASTRO_SHADOW summary frames=<n> ops=<n> equal=<n> different=<n> skipped_vk=<n> skipped_vpk=<n> ...
///   ASTRO_SHADOW top rank=<n> field=<field> pgm=<hash> count=<n> first_seq=<n>
/// Plain C++ (no emulator headers): it is tested on its own.
namespace VideoCore::Shadow {

/// The host format name of either API ("R8G8B8A8Unorm" of Vulkan, "RGBA8Unorm" of VPKEngine) as texel bits,
/// channels and numeric kind, so that the same format has the same text whichever API named it. Channel order is
/// left out. Names it cannot read are kept as they are (lower case).
inline std::string NormalizeFormat(std::string_view name) {
    if (name.empty()) {
        return "none";
    }
    std::string low(name);
    if (low.size() > 1 && low[0] == 'e' && low[1] >= 'A' && low[1] <= 'Z') {
        low.erase(0, 1);
    }
    std::transform(low.begin(), low.end(), low.begin(), [](unsigned char c) { return char(std::tolower(c)); });
    const auto has = [&](const char* word) { return low.find(word) != std::string::npos; };
    const auto digit = [](char c) { return c >= '0' && c <= '9'; };
    const char* kind = has("srgb")    ? "srgb"
                       : has("float") ? "float"
                       : has("snorm") ? "snorm"
                       : has("sint")  ? "sint"
                       : has("uint")  ? "uint"
                                      : "unorm";
    // Compressed: the family (bc1, etc2, astc4x4) and the kind.
    for (const char* family : {"bc", "etc2", "eac", "astc", "pvrtc"}) {
        if (low.rfind(family, 0) == 0) {
            size_t i = 0;
            while (i < low.size() && low[i] >= 'a' && low[i] <= 'z') {
                ++i;
            }
            while (i < low.size() && digit(low[i])) {
                ++i;
            }
            if (i + 1 < low.size() && low[i] == 'x' && digit(low[i + 1])) {
                for (++i; i < low.size() && digit(low[i]); ++i) {
                }
            }
            return low.substr(0, i) + ":" + kind;
        }
    }
    // Depth / stencil: depth bits and whether there is a stencil.
    if (low.rfind("x8d24", 0) == 0) {
        return "d24";
    }
    if (low.size() > 1 && (low[0] == 'd' || low[0] == 's') && digit(low[1])) {
        size_t i = 1;
        while (i < low.size() && digit(low[i])) {
            ++i;
        }
        return low.substr(0, i) + (low[0] == 'd' && has("s8") ? "s8" : "");
    }
    // Colour: runs of channel letters, each followed by its width.
    const auto channel = [](char c) { return c == 'r' || c == 'g' || c == 'b' || c == 'a' || c == 'e' || c == 'x'; };
    unsigned bits = 0, channels = 0;
    for (size_t i = 0; i < low.size() && channel(low[i]);) {
        unsigned run = 0;
        for (; i < low.size() && channel(low[i]); ++i) {
            ++run;
        }
        if (i >= low.size() || !digit(low[i])) {
            break;
        }
        unsigned width = 0;
        for (; i < low.size() && digit(low[i]); ++i) {
            width = width * 10 + unsigned(low[i] - '0');
        }
        bits += width * run;
        channels += run;
    }
    if (bits == 0) {
        return low;
    }
    return std::to_string(bits) + "b" + std::to_string(channels) + "c:" + kind;
}

struct Diff {
    std::string field, vk, vpk;
    uint64_t pgm = 0;
};

struct Outcome {
    bool compared = false;   // both sides have an answer
    bool bothSkipped = false;
    std::vector<Diff> diffs;
};

namespace detail {

inline std::string Hex(uint64_t v) {
    char text[24];
    std::snprintf(text, sizeof text, "0x%llx", static_cast<unsigned long long>(v));
    return text;
}
inline std::string Num(float v) {
    char text[32];
    std::snprintf(text, sizeof text, "%.2f", double(v));
    return text;
}
inline std::string Sanitize(std::string s) {
    std::replace(s.begin(), s.end(), ' ', '_');
    return s;
}
inline std::string StatusText(const Side& side) {
    switch (side.status) {
    case Status::Drawn: return "drawn";
    case Status::Handled: return "handled";
    case Status::Skipped: return "skip_" + Sanitize(side.reason);
    case Status::NotRun: break;
    }
    return "notrun";
}

inline uint64_t MainHash(const Side& s) {
    for (const Stage stage : {Stage::Ps, Stage::Vs, Stage::Cs}) {
        if (s.hash[size_t(stage)] != 0) {
            return s.hash[size_t(stage)];
        }
    }
    return 0;
}

struct Differ {
    std::vector<Diff>& out;
    uint64_t pgm = 0;

    void Add(std::string field, std::string vk, std::string vpk) {
        out.push_back({std::move(field), Sanitize(std::move(vk)), Sanitize(std::move(vpk)), pgm});
    }
    template <typename T>
    void Eq(const std::string& field, const T& vk, const T& vpk) {
        if (vk != vpk) {
            Add(field, std::to_string(vk), std::to_string(vpk));
        }
    }
    void Eq(const std::string& field, bool vk, bool vpk) {
        if (vk != vpk) {
            Add(field, vk ? "1" : "0", vpk ? "1" : "0");
        }
    }
    void Eq(const std::string& field, uint8_t vk, uint8_t vpk) {
        if (vk != vpk) {
            Add(field, std::to_string(unsigned(vk)), std::to_string(unsigned(vpk)));
        }
    }
    void EqHex(const std::string& field, uint64_t vk, uint64_t vpk) {
        if (vk != vpk) {
            Add(field, Hex(vk), Hex(vpk));
        }
    }
    void Format(const std::string& field, const std::string& vk, const std::string& vpk) {
        if (NormalizeFormat(vk) != NormalizeFormat(vpk)) {
            Add(field, vk.empty() ? "none" : vk, vpk.empty() ? "none" : vpk);
        }
    }
    void Near(const std::string& field, float vk, float vpk, float tolerance) {
        if (!(std::fabs(vk - vpk) <= tolerance)) {
            Add(field, Num(vk), Num(vpk));
        }
    }
};

/// Sorted by (stage, address), one entry per pair (the largest range of a repeated one).
template <typename T>
std::vector<T> ByKey(std::vector<T> list) {
    std::stable_sort(list.begin(), list.end(), [](const T& a, const T& b) {
        return std::tie(a.stage, a.address) < std::tie(b.stage, b.address);
    });
    std::vector<T> out;
    for (T& item : list) {
        if (!out.empty() && out.back().stage == item.stage && out.back().address == item.address) {
            if constexpr (requires { item.size; }) {
                if (item.size > out.back().size) {
                    out.back() = std::move(item);
                }
            }
        } else {
            out.push_back(std::move(item));
        }
    }
    return out;
}

/// Pairs the two lists by (stage, address): `both` for those in both, a difference for the others.
template <typename T, typename Fn>
void Align(Differ& d, const char* what, const Side& vk, const Side& vpk, std::vector<T> a, std::vector<T> b,
           Fn&& both) {
    a = ByKey(std::move(a));
    b = ByKey(std::move(b));
    const auto stageHash = [&](Stage s) {
        return vk.hash[size_t(s)] != 0 ? vk.hash[size_t(s)] : vpk.hash[size_t(s)];
    };
    size_t i = 0, j = 0;
    while (i < a.size() || j < b.size()) {
        const bool takeA = j >= b.size() || (i < a.size() && std::tie(a[i].stage, a[i].address) <
                                                                  std::tie(b[j].stage, b[j].address));
        const bool takeB = i >= a.size() || (j < b.size() && std::tie(b[j].stage, b[j].address) <
                                                                  std::tie(a[i].stage, a[i].address));
        if (takeA) {
            d.pgm = stageHash(a[i].stage);
            d.Add(std::string(what) + "." + StageName(a[i].stage) + ".only_vk", Hex(a[i].address), "-");
            ++i;
        } else if (takeB) {
            d.pgm = stageHash(b[j].stage);
            d.Add(std::string(what) + "." + StageName(b[j].stage) + ".only_vpk", "-", Hex(b[j].address));
            ++j;
        } else {
            d.pgm = stageHash(a[i].stage);
            both(a[i], b[j], std::string(what) + "." + StageName(a[i].stage) + ".");
            ++i;
            ++j;
        }
    }
}

inline std::string Signature(const SamplerBinding& s) {
    return "u" + std::to_string(s.addressU) + "v" + std::to_string(s.addressV) + "w" + std::to_string(s.addressW) +
           "_mag" + std::to_string(s.magFilter) + "min" + std::to_string(s.minFilter) + "mip" +
           std::to_string(s.mipFilter) + (s.anisotropy ? "_aniso" : "") + (s.compare ? "_cmp" : "");
}

inline void CompareBindings(Differ& d, const Side& a, const Side& b) {
    Align(d, "buf", a, b, a.buffers, b.buffers, [&](const BufferBinding& x, const BufferBinding& y, const std::string& p) {
        d.Eq(p + "size", x.size, y.size);
        d.Eq(p + "stride", x.stride, y.stride);
        d.Eq(p + "write", x.write, y.write);
    });
    Align(d, "tex", a, b, a.textures, b.textures, [&](const TextureBinding& x, const TextureBinding& y, const std::string& p) {
        d.Eq(p + "dataformat", x.dataFormat, y.dataFormat);
        d.Eq(p + "numformat", x.numFormat, y.numFormat);
        d.Eq(p + "type", x.type, y.type);
        d.Eq(p + "tile", x.tileMode, y.tileMode);
        d.Eq(p + "width", x.width, y.width);
        d.Eq(p + "height", x.height, y.height);
        d.Eq(p + "base_level", x.baseLevel, y.baseLevel);
        d.Eq(p + "last_level", x.lastLevel, y.lastLevel);
        d.Eq(p + "storage", x.storage, y.storage);
        if (x.dstSel != y.dstSel) {
            const auto text = [](const std::array<uint8_t, 4>& s) {
                return std::to_string(s[0]) + "," + std::to_string(s[1]) + "," + std::to_string(s[2]) + "," +
                       std::to_string(s[3]);
            };
            d.Add(p + "swizzle", text(x.dstSel), text(y.dstSel));
        }
        d.Eq(p + "found", x.found, y.found);
        if (x.found && y.found) {
            d.Format(p + "host_format", x.hostFormat, y.hostFormat);
            d.Eq(p + "host_width", x.hostWidth, y.hostWidth);
            d.Eq(p + "host_height", x.hostHeight, y.hostHeight);
        }
    });
    // Samplers have no address: per stage, their texts sorted (the order of the bindings differs).
    for (size_t s = 0; s < kStages; ++s) {
        std::vector<std::string> x, y;
        for (const SamplerBinding& v : a.samplers) {
            if (size_t(v.stage) == s) {
                x.push_back(Signature(v));
            }
        }
        for (const SamplerBinding& v : b.samplers) {
            if (size_t(v.stage) == s) {
                y.push_back(Signature(v));
            }
        }
        std::sort(x.begin(), x.end());
        std::sort(y.begin(), y.end());
        d.pgm = a.hash[s] != 0 ? a.hash[s] : b.hash[s];
        const std::string field = std::string("sampler.") + StageName(Stage(s));
        if (x.size() != y.size()) {
            d.Add(field + ".count", std::to_string(x.size()), std::to_string(y.size()));
        }
        for (size_t k = 0; k < std::min(x.size(), y.size()); ++k) {
            if (x[k] != y[k]) {
                d.Add(field, x[k], y[k]);
                break;
            }
        }
    }
}

/// `indirect`: the counts are read by the GPU from memory, there is nothing to compare them by.
inline void CompareDraw(Differ& d, const Side& a, const Side& b, bool indirect) {
    for (size_t i = 0; i < a.color.size(); ++i) {
        const Target& x = a.color[i];
        const Target& y = b.color[i];
        const std::string p = "color" + std::to_string(i) + ".";
        d.Eq(p + "used", x.used, y.used);
        if (!x.used || !y.used) {
            continue;
        }
        d.EqHex(p + "address", x.address, y.address);
        d.Eq(p + "width", x.width, y.width);
        d.Eq(p + "height", x.height, y.height);
        d.Eq(p + "pitch", x.pitch, y.pitch);
        d.Eq(p + "format", x.dataFormat, y.dataFormat);
        d.Eq(p + "number", x.numberType, y.numberType);
        d.Eq(p + "swap", x.compSwap, y.compSwap);
        d.Eq(p + "tile", x.tileMode, y.tileMode);
        d.Eq(p + "slice_start", x.sliceStart, y.sliceStart);
        d.Eq(p + "slice_count", x.sliceCount, y.sliceCount);
        d.Eq(p + "samples", x.samples, y.samples);
        d.Format(p + "host_format", x.hostFormat, y.hostFormat);
        d.Eq(p + "cleared", x.cleared, y.cleared);
    }
    {
        const Depth& x = a.depth;
        const Depth& y = b.depth;
        d.Eq("depth.used", x.used, y.used);
        if (x.used && y.used) {
            d.EqHex("depth.z_address", x.zAddress, y.zAddress);
            d.EqHex("depth.stencil_address", x.stencilAddress, y.stencilAddress);
            d.Eq("depth.width", x.width, y.width);
            d.Eq("depth.height", x.height, y.height);
            d.Eq("depth.z_format", x.zFormat, y.zFormat);
            d.Eq("depth.stencil_format", x.stencilFormat, y.stencilFormat);
            d.Eq("depth.tile", x.tileMode, y.tileMode);
            d.Eq("depth.samples", x.samples, y.samples);
            d.Format("depth.host_format", x.hostFormat, y.hostFormat);
            d.Eq("depth.depth_clear", x.depthClear, y.depthClear);
            d.Eq("depth.stencil_clear", x.stencilClear, y.stencilClear);
        }
    }
    d.EqHex("index.address", a.indexAddress, b.indexAddress);
    if (a.indexAddress != 0 && b.indexAddress != 0) {
        if (!indirect) {
            d.Eq("index.bytes", a.indexBytes, b.indexBytes);
        }
        d.Eq("index.is32", a.index32, b.index32);
    }
    if (!indirect) {
        d.Eq("count", a.count, b.count);
        d.Eq("instances", a.instances, b.instances);
    }
    d.Eq("topology", a.topology, b.topology);
    if (a.viewportValid != b.viewportValid) {
        d.Eq("viewport.valid", a.viewportValid, b.viewportValid);
    } else if (a.viewportValid) {
        static constexpr const char* names[] = {"x", "y", "width", "height", "min_depth", "max_depth"};
        for (size_t k = 0; k < 6; ++k) {
            d.Near(std::string("viewport.") + names[k], a.viewport[k], b.viewport[k], k < 4 ? 0.5f : 0.001f);
        }
    }
    if (a.scissorValid != b.scissorValid) {
        d.Eq("scissor.valid", a.scissorValid, b.scissorValid);
    } else if (a.scissorValid) {
        static constexpr const char* names[] = {"x", "y", "width", "height"};
        // (VPKEngine clips the scissor to its targets, Vulkan leaves the registers' rectangle: compared inside the targets)
        const auto clipped = [](const Side& side) {
            int64_t w = INT64_MAX, h = INT64_MAX;
            for (const Target& t : side.color) {
                if (t.used) {
                    w = std::min<int64_t>(w, t.width), h = std::min<int64_t>(h, t.height);
                }
            }
            if (side.depth.used) {
                w = std::min<int64_t>(w, side.depth.width), h = std::min<int64_t>(h, side.depth.height);
            }
            const int64_t x0 = std::max<int64_t>(0, side.scissor[0]), y0 = std::max<int64_t>(0, side.scissor[1]);
            const int64_t x1 = std::min<int64_t>(w, int64_t{side.scissor[0]} + side.scissor[2]);
            const int64_t y1 = std::min<int64_t>(h, int64_t{side.scissor[1]} + side.scissor[3]);
            return std::array<int32_t, 4>{int32_t(x0), int32_t(y0), int32_t(std::max<int64_t>(0, x1 - x0)),
                                          int32_t(std::max<int64_t>(0, y1 - y0))};
        };
        const auto sa = clipped(a);
        const auto sb = clipped(b);
        for (size_t k = 0; k < 4; ++k) {
            d.Eq(std::string("scissor.") + names[k], sa[k], sb[k]);
        }
    }
    if (a.stateValid && b.stateValid) {
        d.Eq("state.cull", a.cull, b.cull);
        d.Eq("state.front_clockwise", a.frontClockwise, b.frontClockwise);
        d.Eq("state.depth_test", a.depthTest, b.depthTest);
        d.Eq("state.depth_write", a.depthWrite, b.depthWrite);
        if (a.depthTest && b.depthTest) {
            d.Eq("state.depth_func", a.depthFunc, b.depthFunc);
        }
        d.Eq("state.stencil_test", a.stencilTest, b.stencilTest);
        for (size_t i = 0; i < a.blend.size(); ++i) {
            if (!a.color[i].used || !b.color[i].used) {
                continue;
            }
            const Blend& x = a.blend[i];
            const Blend& y = b.blend[i];
            const std::string p = "blend" + std::to_string(i) + ".";
            d.Eq(p + "enable", x.enable, y.enable);
            if (x.enable && y.enable) {
                d.Eq(p + "color_src", x.colorSrc, y.colorSrc);
                d.Eq(p + "color_dst", x.colorDst, y.colorDst);
                d.Eq(p + "color_func", x.colorFunc, y.colorFunc);
                d.Eq(p + "alpha_src", x.alphaSrc, y.alphaSrc);
                d.Eq(p + "alpha_dst", x.alphaDst, y.alphaDst);
                d.Eq(p + "alpha_func", x.alphaFunc, y.alphaFunc);
            }
        }
    } else {
        d.Eq("state.valid", a.stateValid, b.stateValid);
    }
}

} // namespace detail

/// Compares the two halves of a record.
inline Outcome Compare(const Record& r) {
    using namespace detail;
    Outcome out;
    const Side& a = r.vk;
    const Side& b = r.vpk;
    if (a.status == Status::NotRun || b.status == Status::NotRun) {
        return out;
    }
    out.compared = true;
    Differ d{out.diffs, MainHash(a) != 0 ? MainHash(a) : MainHash(b)};
    const uint64_t main = d.pgm;
    const bool skippedA = a.status == Status::Skipped;
    const bool skippedB = b.status == Status::Skipped;
    if (skippedA != skippedB) {
        d.Add("status.vk_" + StatusText(a) + ".vpk_" + StatusText(b), StatusText(a), StatusText(b));
        return out;
    }
    if (skippedA) {
        out.bothSkipped = true;
        return out;
    }
    if (a.status == Status::Handled || b.status == Status::Handled) {
        return out;  // (done as something other than a draw: the fields do not mean the same)
    }
    switch (r.op) {
    case Op::FillBuffer:
        d.EqHex("fill.address", a.dst, b.dst);
        d.Eq("fill.bytes", a.bytes, b.bytes);
        d.Eq("fill.value", a.value, b.value);
        return out;
    case Op::CopyBuffer:
        d.EqHex("copy.dst", a.dst, b.dst);
        d.EqHex("copy.src", a.src, b.src);
        d.Eq("copy.bytes", a.bytes, b.bytes);
        return out;
    default: break;
    }
    for (size_t s = 0; s < kStages; ++s) {
        d.pgm = main;
        d.EqHex(std::string("hash.") + StageName(Stage(s)), a.hash[s], b.hash[s]);
    }
    d.pgm = main;
    if (r.op == Op::DispatchDirect) {
        d.Eq("groups.x", a.groups[0], b.groups[0]);
        d.Eq("groups.y", a.groups[1], b.groups[1]);
        d.Eq("groups.z", a.groups[2], b.groups[2]);
    }
    if (r.op == Op::Draw || r.op == Op::DrawIndirect) {
        CompareDraw(d, a, b, r.op == Op::DrawIndirect);
    }
    CompareBindings(d, a, b);
    return out;
}

struct Totals {
    uint64_t ops = 0;          // calls seen
    uint64_t compared = 0;     // both sides answered and neither skipped
    uint64_t equal = 0;
    uint64_t different = 0;
    uint64_t skippedVk = 0;    // the Vulkan side skipped it (any case)
    uint64_t skippedVpk = 0;
    uint64_t skippedBoth = 0;
    uint64_t notCompared = 0;  // a side did not answer
};

/// Numbers the records, compares them and logs the differences: each (field, program) in full the first
/// `fullPerKey` times, then only counted; a summary every `summaryFrames` pictures; at most `maxLines` diff lines.
struct AggregatorConfig {
    uint64_t fullPerKey = 3;
    uint64_t maxLines = 4000;
    uint64_t summaryFrames = 600;
    size_t top = 30;
};

class Aggregator {
public:
    using Sink = std::function<void(const std::string&)>;
    using Config = AggregatorConfig;

    explicit Aggregator(Sink sink_, Config config_ = {}) : sink{std::move(sink_)}, config{config_} {}

    uint64_t NextSeq() {
        return next_seq.fetch_add(1, std::memory_order_relaxed);
    }

    /// Compares and logs one finished record.
    void Submit(const Record& record) {
        const Outcome outcome = Compare(record);
        std::scoped_lock lock{mutex};
        ++totals.ops;
        totals.skippedVk += record.vk.status == Status::Skipped;
        totals.skippedVpk += record.vpk.status == Status::Skipped;
        if (!outcome.compared) {
            ++totals.notCompared;
            return;
        }
        if (outcome.bothSkipped) {
            ++totals.skippedBoth;
            return;
        }
        ++totals.compared;
        if (outcome.diffs.empty()) {
            ++totals.equal;
            return;
        }
        ++totals.different;
        for (const Diff& diff : outcome.diffs) {
            Key& key = keys[{diff.field, diff.pgm}];
            if (key.count++ == 0) {
                key.first_seq = record.seq;
            }
            if (key.count > config.fullPerKey) {
                continue;
            }
            if (lines >= config.maxLines) {
                if (lines++ == config.maxLines) {
                    sink("ASTRO_SHADOW diff cap reached lines=" + std::to_string(config.maxLines) +
                         " (the rest is only counted, see summary)");
                }
                continue;
            }
            ++lines;
            sink("ASTRO_SHADOW diff seq=" + std::to_string(record.seq) + " op=" + OpName(record.op) +
                 " field=" + diff.field + " vk=" + diff.vk + " vpk=" + diff.vpk + " pgm=" + detail::Hex(diff.pgm));
        }
    }

    /// Writes the summary when `frames` pictures have passed since the last one.
    void Tick(uint64_t frames) {
        std::scoped_lock lock{mutex};
        if (config.summaryFrames == 0 || frames / config.summaryFrames <= last_summary) {
            return;
        }
        last_summary = frames / config.summaryFrames;
        WriteSummary(frames);
    }

    Totals Snapshot() const {
        std::scoped_lock lock{mutex};
        return totals;
    }

private:
    struct Key {
        uint64_t count = 0;
        uint64_t first_seq = 0;
    };

    void WriteSummary(uint64_t frames) {
        sink("ASTRO_SHADOW summary frames=" + std::to_string(frames) + " ops=" + std::to_string(totals.ops) +
             " compared=" + std::to_string(totals.compared) + " equal=" + std::to_string(totals.equal) +
             " different=" + std::to_string(totals.different) + " skipped_vk=" + std::to_string(totals.skippedVk) +
             " skipped_vpk=" + std::to_string(totals.skippedVpk) + " skipped_both=" + std::to_string(totals.skippedBoth) +
             " not_compared=" + std::to_string(totals.notCompared) + " keys=" + std::to_string(keys.size()));
        std::vector<std::map<std::pair<std::string, uint64_t>, Key>::const_iterator> order;
        for (auto it = keys.begin(); it != keys.end(); ++it) {
            order.push_back(it);
        }
        std::sort(order.begin(), order.end(), [](const auto& x, const auto& y) {
            return std::tie(y->second.count, x->second.first_seq) < std::tie(x->second.count, y->second.first_seq);
        });
        for (size_t i = 0; i < std::min(order.size(), config.top); ++i) {
            const auto& [key, value] = *order[i];
            sink("ASTRO_SHADOW top rank=" + std::to_string(i + 1) + " field=" + key.first + " pgm=" +
                 detail::Hex(key.second) + " count=" + std::to_string(value.count) +
                 " first_seq=" + std::to_string(value.first_seq));
        }
    }

    Sink sink;
    Config config;
    std::atomic<uint64_t> next_seq{1};
    mutable std::mutex mutex;
    Totals totals;
    std::map<std::pair<std::string, uint64_t>, Key> keys;
    uint64_t lines = 0;
    uint64_t last_summary = 0;
};

} // namespace VideoCore::Shadow
