// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <array>
#include <atomic>
#include <cstdint>
#include <string>
#include <vector>

/// ASTRO_RENDERER=shadow: what each renderer RESOLVED for one call of the Tee (not the raw registers,
/// which are the same for both): targets with their host formats, the size each buffer is bound with, the
/// textures and samplers found, the programs, the viewport and the fixed-function state that was chosen.
/// The Tee gives each call a Record and makes it the thread's current one; the Vulkan rasterizer (vk side)
/// and the VPKEngine adapter (vpk side) fill their half while they run, and shadow_compare.h compares the two
/// halves afterwards. Outside the Tee no record is current: filling costs one thread-local load.
/// Plain C++ (no emulator headers): it is tested on its own.
namespace VideoCore::Shadow {

enum class Op : uint8_t { Draw, DrawIndirect, DispatchDirect, DispatchIndirect, FillBuffer, CopyBuffer };

inline const char* OpName(Op op) {
    switch (op) {
    case Op::Draw: return "draw";
    case Op::DrawIndirect: return "draw_indirect";
    case Op::DispatchDirect: return "dispatch";
    case Op::DispatchIndirect: return "dispatch_indirect";
    case Op::FillBuffer: return "fill";
    case Op::CopyBuffer: return "copy";
    }
    return "?";
}

/// How the call ended on one side. NotRun: the side filled nothing (it was not there, or switched off).
enum class Status : uint8_t { NotRun, Drawn, Handled, Skipped };

/// Shader stages by what they do, the same on both sides: Vs is the vertex stage (the ES of a geometry
/// pipeline), Copy the GS's copy shader.
enum class Stage : uint8_t { Vs, Ps, Cs, Gs, Copy, Count };
constexpr size_t kStages = size_t(Stage::Count);

inline const char* StageName(Stage s) {
    static constexpr const char* names[] = {"vs", "ps", "cs", "gs", "copy"};
    return size_t(s) < kStages ? names[size_t(s)] : "?";
}

struct Target {
    bool used = false;
    uint64_t address = 0;
    uint32_t width = 0, height = 0, pitch = 0;
    uint8_t dataFormat = 0, numberType = 0, compSwap = 0;  // CB_COLORn_INFO.FORMAT / NUMBER_TYPE / COMP_SWAP
    uint8_t tileMode = 0;
    uint16_t sliceStart = 0, sliceCount = 0;
    uint8_t samples = 0;
    std::string hostFormat;  // the host API's name of the format chosen (normalised when compared)
    bool cleared = false;    // fast clear / clear applied by this draw
};

struct Depth {
    bool used = false;
    uint64_t zAddress = 0, stencilAddress = 0;
    uint32_t width = 0, height = 0;
    uint8_t zFormat = 0, stencilFormat = 0, tileMode = 0, samples = 0;
    std::string hostFormat;
    bool depthClear = false, stencilClear = false;
};

/// A buffer a stage reads or writes through a V# (and a vertex buffer, as the stage that fetches it).
/// `size` is the range it was bound with after the host clamped it to the memory that exists: 0 for a buffer
/// that was not bound for real.
struct BufferBinding {
    Stage stage = Stage::Vs;
    uint64_t address = 0;
    uint64_t size = 0;
    uint32_t stride = 0;
    bool write = false;
};

struct TextureBinding {
    Stage stage = Stage::Ps;
    uint64_t address = 0;
    uint8_t dataFormat = 0, numFormat = 0, type = 0, tileMode = 0, baseLevel = 0, lastLevel = 0;
    uint32_t width = 0, height = 0;
    std::array<uint8_t, 4> dstSel{};
    bool storage = false;
    bool found = false;  // the host found / made an image for it
    std::string hostFormat;
    uint32_t hostWidth = 0, hostHeight = 0;
};

/// A sampler as the host made it. Address modes: 0 repeat, 1 mirror, 2 clamp to edge, 3 mirror clamp to edge,
/// 4 border. Filters: 0 nearest, 1 linear (the mip filter's "none" is nearest).
struct SamplerBinding {
    Stage stage = Stage::Ps;
    uint8_t addressU = 0, addressV = 0, addressW = 0;
    uint8_t magFilter = 0, minFilter = 0, mipFilter = 0;
    bool anisotropy = false, compare = false;
};

struct Blend {
    bool enable = false;
    uint8_t colorSrc = 0, colorDst = 0, colorFunc = 0, alphaSrc = 0, alphaDst = 0, alphaFunc = 0;  // CB_BLENDn_CONTROL encodings
};

/// One side of a Record.
struct Side {
    Status status = Status::NotRun;
    std::string reason;  // why it was skipped / what it was handled as
    std::array<Target, 8> color;
    Depth depth;
    // Draw
    uint64_t indexAddress = 0;  // 0: not indexed
    uint64_t indexBytes = 0;    // the range bound
    bool index32 = false;
    uint32_t count = 0, instances = 0;
    uint8_t topology = 0;  // host class: 0 points, 1 lines, 2 triangles, 3 patches
    // Programs by stage (the GCN binary info's hash; 0: no such stage)
    std::array<uint64_t, kStages> hash{};
    std::vector<BufferBinding> buffers;
    std::vector<TextureBinding> textures;
    std::vector<SamplerBinding> samplers;
    bool viewportValid = false;
    float viewport[6]{};  // x, y, width, height (positive: a flipped one is normalised), min depth, max depth
    bool scissorValid = false;
    int32_t scissor[4]{};  // x, y, width, height
    bool stateValid = false;
    uint8_t cull = 0;  // 0 none, 1 front, 2 back
    bool frontClockwise = false;
    bool depthTest = false, depthWrite = false;
    uint8_t depthFunc = 7;  // FRAG_* (7 always)
    bool stencilTest = false;
    std::array<Blend, 8> blend;
    // Dispatch
    std::array<uint32_t, 3> groups{};
    // DMA
    uint64_t dst = 0, src = 0, bytes = 0;
    uint32_t value = 0;
};

struct Record {
    uint64_t seq = 0;
    Op op = Op::Draw;
    Side vk, vpk;
};

/// The record of the Tee call in progress on this thread (null outside one, and with the shadow off).
inline Record*& Current() {
    static thread_local Record* current = nullptr;
    return current;
}

class Scope {
public:
    explicit Scope(Record* record) : previous{Current()} {
        Current() = record;
    }
    ~Scope() {
        Current() = previous;
    }
    Scope(const Scope&) = delete;
    Scope& operator=(const Scope&) = delete;

private:
    Record* previous;
};

/// Pictures presented so far (the summary is written every N of them). Counted by VPKEngine's
/// ShadowEndFrame, which the video-out flip calls.
inline std::atomic<uint64_t>& Frames() {
    static std::atomic<uint64_t> frames{0};
    return frames;
}

} // namespace VideoCore::Shadow
