// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <functional>
#include <map>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "video_core/shadow_compare.h"
#include "video_core/shadow_record.h"

/// ASTRO_RENDERER=shadow, pixel comparison (ASTRO_SHADOW_PIXELS=<seconds|0>, default 10): once every N seconds one
/// picture is a capture frame. Each of its draws runs in isolation on both renderers: VPKEngine (on a real Metal
/// backend, see PixelCapture) starts from the pixels Vulkan had before the draw, and the rectangle the draw can reach
/// (viewport and scissor) is compared after it:
///   ASTRO_PIXEL diff seq=<n> op=<op> pgm=<hash> rt=<addr> fmt=<format> <w>x<h> pct=<%> maxerr=<e> psnr=<dB> first_divergent=yes|no
///   ASTRO_PIXEL summary draws=<n> compared=<n> equal=<n> diverged=<n> skipped=<n>(<reason>=<n>,...)
/// Plain C++ (no emulator headers): it is tested on its own.
namespace VideoCore::Shadow {

/// The layout of the texels of a host format name of either API ("R8G8B8A8Unorm", "RGBA8Srgb", "D32Sfloat"...):
/// what the comparison needs to read them. Kind says how an error is measured: a normalised 8 / 16 bit channel, a
/// float channel, or any other layout (packed, integer, signed), where the bytes must be equal.
struct PixelFormat {
    enum class Kind : uint8_t { Unorm, Srgb, Float, Exact };
    uint32_t bytes = 0;     // per texel
    uint32_t channels = 0;
    uint32_t bits = 0;      // per channel (0: not uniform)
    Kind kind = Kind::Exact;
    std::string order;      // channel letters in memory order ("rgba", "bgra", "r"; a depth image is "r")
};

inline std::optional<PixelFormat> ParsePixelFormat(std::string_view name) {
    std::string low(name);
    std::transform(low.begin(), low.end(), low.begin(), [](unsigned char c) { return char(std::tolower(c)); });
    const auto has = [&](const char* word) { return low.find(word) != std::string::npos; };
    const auto digit = [](char c) { return c >= '0' && c <= '9'; };
    PixelFormat f;
    if (low.size() > 1 && low[0] == 'd' && digit(low[1])) {  // depth: the Z plane alone
        unsigned bits = 0;
        for (size_t i = 1; i < low.size() && digit(low[i]); ++i) {
            bits = bits * 10 + unsigned(low[i] - '0');
        }
        if (has("s8") || (bits != 16 && bits != 32)) {
            return std::nullopt;
        }
        f.bytes = bits / 8, f.channels = 1, f.bits = bits, f.order = "r";
        f.kind = has("float") ? PixelFormat::Kind::Float : PixelFormat::Kind::Unorm;
        return f;
    }
    const auto channel = [](char c) { return c == 'r' || c == 'g' || c == 'b' || c == 'a'; };
    std::vector<unsigned> widths;
    size_t i = 0;
    while (i < low.size() && channel(low[i])) {
        size_t letters = 0;
        for (; i < low.size() && channel(low[i]); ++i, ++letters) {
            f.order += low[i];
        }
        if (i >= low.size() || !digit(low[i])) {
            return std::nullopt;
        }
        unsigned width = 0;
        for (; i < low.size() && digit(low[i]); ++i) {
            width = width * 10 + unsigned(low[i] - '0');
        }
        widths.insert(widths.end(), letters, width);  // ("rgba8": the width of each; "r8g8": of its own)
    }
    if (widths.empty() || low.size() - i > 16) {
        return std::nullopt;
    }
    unsigned total = 0;
    for (const unsigned w : widths) {
        total += w;
    }
    if (total == 0 || total % 8 != 0) {
        return std::nullopt;
    }
    f.bytes = total / 8;
    f.channels = unsigned(widths.size());
    const bool uniform = std::all_of(widths.begin(), widths.end(), [&](unsigned w) { return w == widths[0]; });
    f.bits = uniform ? widths[0] : 0;
    f.kind = PixelFormat::Kind::Exact;
    if (uniform && !has("pack")) {
        if (has("srgb") && widths[0] == 8) {
            f.kind = PixelFormat::Kind::Srgb;
        } else if (has("float") && (widths[0] == 16 || widths[0] == 32)) {
            f.kind = PixelFormat::Kind::Float;
        } else if (!has("snorm") && !has("uint") && !has("sint") && !has("float") && !has("srgb") &&
                   (widths[0] == 8 || widths[0] == 16)) {
            f.kind = PixelFormat::Kind::Unorm;
        }
    }
    return f;
}

/// The two formats hold the same texel bytes in the same order and are measured the same way.
inline bool SameLayout(const PixelFormat& a, const PixelFormat& b) {
    return a.bytes == b.bytes && a.order == b.order && a.kind == b.kind && a.bits == b.bits;
}

struct PixelStats {
    uint64_t texels = 0, differing = 0;
    double maxError = 0;  // largest error of one channel (1.0 = the whole range of a normalised channel)
    double sumSquares = 0;
    uint64_t samples = 0;  // channels measured
    double Percent() const { return texels ? 100.0 * double(differing) / double(texels) : 0.0; }
    double Psnr() const {
        if (samples == 0 || sumSquares <= 0) {
            return 99.0;
        }
        return std::min(99.0, 10.0 * std::log10(1.0 / (sumSquares / double(samples))));
    }
};

inline float HalfToFloat(uint16_t h) {
    const uint32_t sign = uint32_t(h >> 15) << 31;
    uint32_t exponent = (h >> 10) & 0x1f, mantissa = h & 0x3ff;
    uint32_t bits;
    if (exponent == 0) {
        if (mantissa == 0) {
            bits = sign;
        } else {  // subnormal
            exponent = 127 - 15 + 1;
            while (!(mantissa & 0x400)) {
                mantissa <<= 1;
                --exponent;
            }
            bits = sign | (exponent << 23) | ((mantissa & 0x3ff) << 13);
        }
    } else if (exponent == 31) {
        bits = sign | 0x7f800000u | (mantissa << 13);
    } else {
        bits = sign | ((exponent + 127 - 15) << 23) | (mantissa << 13);
    }
    float out;
    std::memcpy(&out, &bits, sizeof out);
    return out;
}

/// Compares two images of the same rectangle and format, rows tight. A texel differs when a channel is off by
/// more than 2/255 (normalised 8 / 16 bit), by more than 1e-3 relative (float; a difference under 1e-6 is none),
/// or at all (any other layout).
inline PixelStats ComparePixels(const PixelFormat& f, const uint8_t* a, const uint8_t* b, uint32_t width,
                                uint32_t height) {
    PixelStats stats;
    stats.texels = uint64_t(width) * height;
    const uint64_t count = stats.texels;
    for (uint64_t t = 0; t < count; ++t) {
        const uint8_t* pa = a + t * f.bytes;
        const uint8_t* pb = b + t * f.bytes;
        bool differs = false;
        if (f.kind == PixelFormat::Kind::Exact) {
            differs = std::memcmp(pa, pb, f.bytes) != 0;
            const double error = differs ? 1.0 : 0.0;
            stats.maxError = std::max(stats.maxError, error);
            stats.sumSquares += error * error;
            ++stats.samples;
        } else {
            for (uint32_t c = 0; c < f.channels; ++c) {
                double x, y, error, tolerance;
                if (f.kind == PixelFormat::Kind::Float) {
                    float fx, fy;
                    if (f.bits == 16) {
                        uint16_t hx, hy;
                        std::memcpy(&hx, pa + c * 2, 2);
                        std::memcpy(&hy, pb + c * 2, 2);
                        fx = HalfToFloat(hx), fy = HalfToFloat(hy);
                    } else {
                        std::memcpy(&fx, pa + c * 4, 4);
                        std::memcpy(&fy, pb + c * 4, 4);
                    }
                    if (std::isnan(fx) && std::isnan(fy)) {
                        ++stats.samples;
                        continue;
                    }
                    x = fx, y = fy;
                    error = std::isfinite(x - y) ? std::fabs(x - y) : 1.0;
                    tolerance = std::max(1e-6, 1e-3 * std::max(std::fabs(x), std::fabs(y)));
                    if (std::isinf(x) && x == y) {
                        error = 0;
                    }
                } else if (f.bits == 8) {
                    x = pa[c], y = pb[c];
                    error = std::fabs(x - y) / 255.0;
                    tolerance = 2.0 / 255.0;
                } else {
                    uint16_t ux, uy;
                    std::memcpy(&ux, pa + c * 2, 2);
                    std::memcpy(&uy, pb + c * 2, 2);
                    error = std::fabs(double(ux) - double(uy)) / 65535.0;
                    tolerance = 2.0 / 255.0;
                }
                differs |= error > tolerance;
                stats.maxError = std::max(stats.maxError, error);
                const double clamped = std::min(error, 1.0);
                stats.sumSquares += clamped * clamped;
                ++stats.samples;
            }
        }
        stats.differing += differs;
    }
    return stats;
}

struct PixelRect {
    uint32_t x = 0, y = 0, w = 0, h = 0;
    bool empty() const { return w == 0 || h == 0; }
};

/// The rectangle of a `width` x `height` surface a draw can reach: the viewport (x, y, width, height) and the
/// scissor (x, y, width, height) intersected with it. A side that gave none leaves the whole surface.
inline PixelRect DrawRegion(bool viewportValid, const float viewport[4], bool scissorValid, const int32_t scissor[4],
                            uint32_t width, uint32_t height) {
    int64_t x0 = 0, y0 = 0, x1 = width, y1 = height;
    if (viewportValid) {
        x0 = std::max<int64_t>(x0, int64_t(std::floor(viewport[0])));
        y0 = std::max<int64_t>(y0, int64_t(std::floor(viewport[1])));
        x1 = std::min<int64_t>(x1, int64_t(std::ceil(viewport[0] + viewport[2])));
        y1 = std::min<int64_t>(y1, int64_t(std::ceil(viewport[1] + viewport[3])));
    }
    if (scissorValid) {
        x0 = std::max<int64_t>(x0, scissor[0]);
        y0 = std::max<int64_t>(y0, scissor[1]);
        x1 = std::min<int64_t>(x1, int64_t{scissor[0]} + scissor[2]);
        y1 = std::min<int64_t>(y1, int64_t{scissor[1]} + scissor[3]);
    }
    if (x1 <= x0 || y1 <= y0) {
        return {};
    }
    return {uint32_t(x0), uint32_t(y0), uint32_t(x1 - x0), uint32_t(y1 - y0)};
}

/// The rows of `rect` of a surface `surfaceWidth` texels wide (rows tight, `bytes` per texel), tight.
inline std::vector<uint8_t> CropRect(const uint8_t* surface, uint32_t surfaceWidth, uint32_t bytes, PixelRect rect) {
    std::vector<uint8_t> out(size_t(rect.w) * rect.h * bytes);
    for (uint32_t row = 0; row < rect.h; ++row) {
        std::memcpy(out.data() + size_t(row) * rect.w * bytes,
                    surface + (size_t(rect.y + row) * surfaceWidth + rect.x) * bytes, size_t(rect.w) * bytes);
    }
    return out;
}

/// A whole surface made of a rectangle of it (the rest zero): what a renderer that starts from the rectangle holds.
inline std::vector<uint8_t> ExpandRect(const PixelImage& image, uint32_t bytes) {
    std::vector<uint8_t> out(size_t(image.surfaceWidth) * image.surfaceHeight * bytes);
    for (uint32_t row = 0; row < image.height && image.y + row < image.surfaceHeight; ++row) {
        std::memcpy(out.data() + (size_t(image.y + row) * image.surfaceWidth + image.x) * bytes,
                    image.texels.data() + size_t(row) * image.width * bytes, size_t(image.width) * bytes);
    }
    return out;
}

/// When pictures are capture frames. A capture frame is the picture between two presented pictures that starts at
/// the first call after an interval has passed; it ends when the next picture is presented, or when the budget (the
/// wall time its readbacks may take) is spent. 0 seconds: never.
class CaptureSchedule {
public:
    struct Step {
        bool ended = false;    // the capture that was running is over
        bool started = false;  // a capture begins with this call
    };

    CaptureSchedule(double intervalSeconds_, double budgetSeconds_)
        : interval{intervalSeconds_}, budget{budgetSeconds_} {}

    /// The value of ASTRO_SHADOW_PIXELS: seconds, "0" off, unset or unreadable the default.
    static double ParseInterval(const char* text, double fallback = 10.0) {
        if (text == nullptr || text[0] == '\0') {
            return fallback;
        }
        char* end = nullptr;
        const double value = std::strtod(text, &end);
        return end == text || value < 0 ? fallback : value;
    }

    Step Advance(uint64_t frames, double now) {
        Step step;
        if (interval <= 0) {
            return step;
        }
        if (!seen) {
            seen = true;
            last_frames = frames;
            last_start = now;  // the first capture is one interval after the first call
            return step;
        }
        if (frames != last_frames) {
            last_frames = frames;
            if (active) {
                active = false;
                step.ended = true;
            }
            if (now - last_start >= interval) {
                active = true;
                step.started = true;
                last_start = capture_start = now;
                ++id;
            }
        }
        return step;
    }

    /// Whether a call at `now` is still captured: a capture is running and its budget is not spent.
    bool Capturing(double now) const { return active && now - capture_start < budget; }
    bool Active() const { return active; }
    uint64_t Id() const { return id; }
    /// The capture is over before its picture is (the budget): the next frame boundary reports `ended`.
    double Budget() const { return budget; }

private:
    double interval, budget;
    bool seen = false, active = false;
    uint64_t last_frames = 0, id = 0;
    double last_start = 0, capture_start = 0;
};

/// Compares the two halves of the captured draws and writes the lines described at the top of this file.
class PixelAggregator {
public:
    using Sink = std::function<void(const std::string&)>;

    explicit PixelAggregator(Sink sink_, size_t maxLines_ = 300) : sink{std::move(sink_)}, max_lines{maxLines_} {}

    /// A capture begins: counters and the first-divergent marks start again.
    void Begin() {
        std::scoped_lock lock{mutex};
        draws = compared = equal = diverged = 0;
        lines = 0;
        skipped.clear();
        diverged_rts.clear();
    }

    /// One captured draw whose both halves are in the record (`pixels` set).
    void Submit(const Record& record) {
        if (!record.pixels) {
            return;
        }
        const PixelCapture& pc = *record.pixels;
        struct Result {
            size_t index;
            const PixelTarget* target;
            PixelStats stats;
            std::string format;
            PixelRect rect;
        };
        std::vector<Result> results;
        std::string skip;
        if (record.vk.status != Status::Drawn) {  // (nothing was drawn to compare)
            skip = "vk:" + detail::StatusText(record.vk);
        } else if (record.vpk.status != Status::Drawn) {
            skip = "vpk:" + detail::StatusText(record.vpk);
        } else if (!pc.vkSkip.empty()) {
            skip = "vk:" + pc.vkSkip;
        } else if (!pc.vpkSkip.empty()) {
            skip = "vpk:" + pc.vpkSkip;
        } else {
            for (size_t i = 0; i < pc.color.size() && skip.empty(); ++i) {
                const PixelTarget& t = pc.color[i];
                if (!t.used) {
                    continue;
                }
                std::string why;
                const auto stats = Measure(t, why);
                if (!stats) {
                    skip = why;
                    break;
                }
                results.push_back({i, &t, *stats, t.post.format, {t.post.x, t.post.y, t.post.width, t.post.height}});
            }
            if (skip.empty() && results.empty()) {
                skip = "no colour target";
            }
        }
        std::scoped_lock lock{mutex};
        ++draws;
        if (!skip.empty()) {
            ++skipped[skip];
            return;
        }
        ++compared;
        bool any = false;
        for (const Result& r : results) {
            if (r.stats.differing == 0) {
                continue;
            }
            any = true;
            const bool first = diverged_rts.insert(r.target->address).second;
            Line("ASTRO_PIXEL diff seq=" + std::to_string(record.seq) + " op=" + OpName(record.op) +
                 " pgm=" + detail::Hex(detail::MainHash(record.vk) != 0 ? detail::MainHash(record.vk)
                                                                        : detail::MainHash(record.vpk)) +
                 " rt=" + detail::Hex(r.target->address) + " fmt=" + r.format + " " + std::to_string(r.rect.w) + "x" +
                 std::to_string(r.rect.h) + " pct=" + Fixed(r.stats.Percent(), 3) +
                 " maxerr=" + Fixed(r.stats.maxError, 4) + " psnr=" + Fixed(r.stats.Psnr(), 1) +
                 " first_divergent=" + (first ? "yes" : "no"));
        }
        if (!any) {
            ++equal;
            return;
        }
        ++diverged;
        // What the two renderers resolved differently for the draw that diverged.
        size_t shown = 0;
        for (const Diff& d : Compare(record).diffs) {
            if (shown++ == 20) {
                Line("ASTRO_PIXEL record_diff seq=" + std::to_string(record.seq) + " (more omitted)");
                break;
            }
            Line("ASTRO_PIXEL record_diff seq=" + std::to_string(record.seq) + " field=" + d.field + " vk=" + d.vk +
                 " vpk=" + d.vpk);
        }
    }

    /// The capture is over: its summary.
    void End() {
        std::scoped_lock lock{mutex};
        std::string reasons;
        uint64_t total = 0;
        for (const auto& [reason, n] : skipped) {
            reasons += (reasons.empty() ? "" : ",") + detail::Sanitize(reason) + "=" + std::to_string(n);
            total += n;
        }
        sink("ASTRO_PIXEL summary draws=" + std::to_string(draws) + " compared=" + std::to_string(compared) +
             " equal=" + std::to_string(equal) + " diverged=" + std::to_string(diverged) +
             " skipped=" + std::to_string(total) + "(" + reasons + ")");
    }

    struct Counts {
        uint64_t draws, compared, equal, diverged;
    };
    Counts Snapshot() const {
        std::scoped_lock lock{mutex};
        return {draws, compared, equal, diverged};
    }

private:
    std::optional<PixelStats> Measure(const PixelTarget& t, std::string& why) {
        if (t.post.empty() || t.vpkPost.empty()) {
            why = "no pixels";
            return std::nullopt;
        }
        const auto a = ParsePixelFormat(t.post.format);
        const auto b = ParsePixelFormat(t.vpkPost.format);
        if (!a || !b) {
            why = "format unknown";
            return std::nullopt;
        }
        if (!SameLayout(*a, *b)) {
            why = "format differs";
            return std::nullopt;
        }
        if (t.post.width != t.vpkPost.width || t.post.height != t.vpkPost.height ||
            t.post.texels.size() != size_t(t.post.width) * t.post.height * a->bytes ||
            t.vpkPost.texels.size() != t.post.texels.size()) {
            why = "size differs";
            return std::nullopt;
        }
        return ComparePixels(*a, t.post.texels.data(), t.vpkPost.texels.data(), t.post.width, t.post.height);
    }
    static std::string Fixed(double v, int digits) {
        char text[32];
        std::snprintf(text, sizeof text, "%.*f", digits, v);
        return text;
    }
    void Line(const std::string& text) {
        if (lines >= max_lines) {
            if (lines++ == max_lines) {
                sink("ASTRO_PIXEL diff cap reached lines=" + std::to_string(max_lines) + " (the rest is only counted)");
            }
            return;
        }
        ++lines;
        sink(text);
    }

    Sink sink;
    size_t max_lines;
    mutable std::mutex mutex;
    uint64_t draws = 0, compared = 0, equal = 0, diverged = 0;
    size_t lines = 0;
    std::map<std::string, uint64_t> skipped;
    std::set<uint64_t> diverged_rts;
};

} // namespace VideoCore::Shadow
