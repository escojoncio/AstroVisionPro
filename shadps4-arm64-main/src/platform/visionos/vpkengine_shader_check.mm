// VPKEngine shader check: see vpkengine_shader_check.h.
#include "vpkengine_shader_check.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <mach/mach.h>

#include <algorithm>
#include <array>
#include <optional>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include <fmt/format.h>

#include "common/logging/log.h"
#include "common/path_util.h"
#include "shader_recompiler/frontend/fetch_shader.h"
#include "shader_recompiler/info.h"
#include "shader_recompiler/runtime_info.h"
#include "video_core/amdgpu/resource.h"
#include "vpgcn/lift.h"
#include "vpmsl/msl.h"

namespace VpkengineShaderCheck {
namespace {

struct Tally {
    std::mutex lock;
    unsigned seen = 0, skipped = 0, lifted = 0, liftFailed = 0, emitFailed = 0, compiled = 0, compileFailed = 0;
    unsigned dispatchLoops = 0;
    double compileMs = 0;
    std::map<std::string, unsigned> errors;  // lift / verifier / Metal error -> count
};

Tally& tally() {
    static Tally t;
    return t;
}

// Per program hash: what VPKEngine made of it (any permutation failing makes it Failed).
enum class Status : uint8_t { Pending, Ok, Failed, Unsupported };
struct Program {
    Status status = Status::Pending;
    const char* stage = "??";
    std::string reason;  // first error
};
struct Census {
    std::mutex lock;
    std::unordered_map<uint64_t, Program> programs;
    // Since the last report.
    unsigned frames = 0;
    uint64_t draws = 0, drawsOk = 0, drawsPending = 0, dispatches = 0, dispatchesOk = 0, dispatchesPending = 0;
    std::unordered_map<uint64_t, uint64_t> blocking;  // hash -> draws + dispatches it kept from VPKEngine
    std::chrono::steady_clock::time_point since = std::chrono::steady_clock::now();
};
Census& census() {
    static Census c;
    return c;
}
void setStatus(uint64_t hash, const char* stage, Status s, const std::string& reason = {}) {
    Census& c = census();
    std::lock_guard g(c.lock);
    Program& p = c.programs[hash];
    p.stage = stage;
    if (p.status == Status::Failed || p.status == Status::Unsupported) return;  // sticky
    if (s == Status::Pending && p.status == Status::Ok) return;                // another permutation
    p.status = s;
    if (!reason.empty()) p.reason = reason.substr(0, 160);
}
// Worst status of a draw's shaders (lock held). Unknown hashes (compiled before the check, or
// loaded from the pipeline cache) count as pending.
Status worst(Census& c, const uint64_t* hashes, size_t n, uint64_t& blocker) {
    Status w = Status::Ok;
    for (size_t k = 0; k < n; ++k) {
        if (hashes[k] == 0) continue;
        auto it = c.programs.find(hashes[k]);
        Status s = it == c.programs.end() ? Status::Pending : it->second.status;
        auto rank = [](Status x) { return x == Status::Ok ? 0 : x == Status::Pending ? 1 : 2; };
        if (rank(s) > rank(w)) {
            w = s;
            blocker = hashes[k];
        }
    }
    return w;
}

// At most this many Metal compiles in flight: a game compiles hundreds of shaders at once.
dispatch_semaphore_t inFlight() {
    static dispatch_semaphore_t s = dispatch_semaphore_create(4);
    return s;
}

id<MTLDevice> device() {
    static id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    return d;
}

const char* stageName(Shader::Stage s) {
    switch (s) {
    case Shader::Stage::Fragment: return "fs";
    case Shader::Stage::Vertex: return "vs";
    case Shader::Stage::Compute: return "cs";
    case Shader::Stage::Geometry: return "gs";
    case Shader::Stage::Export: return "es";
    case Shader::Stage::Hull: return "hs";
    case Shader::Stage::Local: return "ls";
    }
    return "??";
}

std::filesystem::path outDir() {
    auto dir = Common::FS::GetUserPath(Common::FS::PathType::ShaderDir) / "vpkengine";
    std::error_code e;
    std::filesystem::create_directories(dir, e);
    return dir;
}

void logTally(Tally& t) {
    LOG_INFO(Render_Vulkan,
             "VPKENGINE_SHADERS: {} seen, {} other stages, {} lifted ({} via dispatch loop), {} lift errors, "
             "{} verifier errors, {} Metal OK, {} Metal errors, {:.1f} ms Metal compile on average",
             t.seen, t.skipped, t.lifted, t.dispatchLoops, t.liftFailed, t.emitFailed, t.compiled,
             t.compileFailed, t.compiled ? t.compileMs / t.compiled : 0.0);
}

void countError(Tally& t, const std::string& e) {
    if (t.errors.size() < 64 || t.errors.count(e)) ++t.errors[e];
}

// The first line of a Metal compiler message (the rest is the source excerpt).
std::string firstLine(NSString* s) {
    std::string text = s ? std::string([s UTF8String]) : std::string("(no message)");
    size_t nl = text.find('\n');
    return nl == std::string::npos ? text : text.substr(0, nl);
}

// The dwords of a descriptor where the lifter traced it, read from this draw's user data and guest
// memory (guest addresses are host addresses). Guest reads go through vm_read_overwrite, which
// fails instead of faulting on an unmapped address (user data of a pipeline preloaded from disk
// may hold stale pointers).
std::optional<std::array<uint32_t, 8>> readDescriptor(const vpgcn::DescriptorSource& src, const Shader::Info& info) {
    std::array<uint32_t, 8> d{};
    auto readGuest = [&](VAddr at, void* out, size_t bytes) {
        if (at < 0x10000) return false;
        vm_size_t got = 0;
        return vm_read_overwrite(mach_task_self(), vm_address_t(at), vm_size_t(bytes), vm_address_t(out), &got) ==
                   KERN_SUCCESS &&
               got == bytes;
    };
    switch (src.kind) {
    case vpgcn::DescriptorSource::UserData:
        for (unsigned k = 0; k < 8; ++k)
            d[k] = src.sgpr + k < info.user_data.size() ? info.user_data[src.sgpr + k] : 0;
        return d;
    case vpgcn::DescriptorSource::Pointer: {
        if (src.path.empty() || src.sgpr + 1u >= info.user_data.size()) return std::nullopt;
        VAddr at = (VAddr(info.user_data[src.sgpr + 1]) << 32 | info.user_data[src.sgpr]) & 0xFFFFFFFFFFFFull;
        for (size_t k = 0; k + 1 < src.path.size(); ++k) {
            uint64_t next = 0;
            if (!readGuest(at + src.path[k], &next, 8)) return std::nullopt;
            at = next & 0xFFFFFFFFFFFFull;
        }
        // (a 4-dword V#/S# may end a mapping: then its 16 bytes alone)
        if (!readGuest(at + src.path.back(), d.data(), sizeof(d)) && !readGuest(at + src.path.back(), d.data(), 16))
            return std::nullopt;
        return d;
    }
    case vpgcn::DescriptorSource::Code:
        if (src.path.empty() || (!readGuest(info.pgm_base + src.path[0], d.data(), sizeof(d)) &&
                                 !readGuest(info.pgm_base + src.path[0], d.data(), 16)))
            return std::nullopt;
        return d;
    }
    return std::nullopt;
}

// What the lifter needs from a descriptor: a T#'s dimension and texel type, a V#'s data and number
// formats (both read from the same dwords: the lifter takes the fields of the kind it asked for).
std::optional<vpgcn::DescriptorInfo> describeDescriptor(const vpgcn::DescriptorSource& src, const Shader::Info& info) {
    const auto d = readDescriptor(src, info);
    if (!d) return std::nullopt;
    vpgcn::DescriptorInfo out;
    AmdGpu::Image image{};
    std::memcpy(&image, d->data(), sizeof(image) < 32 ? sizeof(image) : 32);
    switch (static_cast<AmdGpu::ImageType>(image.type)) {
    case AmdGpu::ImageType::Color1D: out.dim = vpir::TexDim::D1; break;
    case AmdGpu::ImageType::Color3D: out.dim = vpir::TexDim::D3; break;
    case AmdGpu::ImageType::Cube: out.dim = image.last_array > 5 ? vpir::TexDim::CubeArray : vpir::TexDim::Cube; break;
    case AmdGpu::ImageType::Color1DArray: // (no 1D arrays in VPIR: as 2D arrays)
    case AmdGpu::ImageType::Color2DArray:
    case AmdGpu::ImageType::Color2DMsaaArray: out.dim = vpir::TexDim::D2Array; break;
    default: out.dim = vpir::TexDim::D2; break;
    }
    const auto nfmt = static_cast<AmdGpu::NumberFormat>(image.num_format);
    out.elem = nfmt == AmdGpu::NumberFormat::Uint   ? vpir::Scalar::U32
               : nfmt == AmdGpu::NumberFormat::Sint ? vpir::Scalar::I32
                                                    : vpir::Scalar::F32;
    // V#: dword 3, num_format [14:12], data_format [18:15]
    out.nfmt = uint8_t((*d)[3] >> 12 & 7);
    out.dfmt = uint8_t((*d)[3] >> 15 & 15);
    return out;
}

} // namespace

bool Enabled() {
    static const bool on = [] {
        const char* v = std::getenv("SHADPS4_VPKENGINE_SHADER_CHECK");
        return v && v[0] == '1';
    }();
    return on;
}

void Check(std::span<const uint32_t> code, const Shader::Info& info, const Shader::RuntimeInfo& runtime,
           size_t perm_idx) {
    char nameBuf[64];
    std::snprintf(nameBuf, sizeof nameBuf, "%s_%016llx_%zu", stageName(info.stage),
                  static_cast<unsigned long long>(info.pgm_hash), perm_idx);
    const std::string name = nameBuf;
    Tally& t = tally();

    vpgcn::LiftInput in;
    std::vector<uint32_t> fetch;
    switch (info.stage) {
    case Shader::Stage::Vertex:
        in.stage = vpgcn::ShaderStage::Vertex;
        in.vgprCompCnt = runtime.num_input_vgprs ? runtime.num_input_vgprs - 1 : 0;
        in.instanceStepRate[0] = runtime.vs_info.step_rate_0;
        in.instanceStepRate[1] = runtime.vs_info.step_rate_1;
        if (info.has_fetch_shader) {
            if (const auto data = Shader::Gcn::ParseFetchShader(info)) {
                const u32* p = Shader::Gcn::GetFetchShaderCode(info, info.fetch_shader_sgpr_base);
                fetch.assign(p, p + data->size / 4);
            }
        }
        break;
    case Shader::Stage::Fragment: {
        in.stage = vpgcn::ShaderStage::Pixel;
        uint32_t addr = 0;
        std::memcpy(&addr, &runtime.fs_info.addr_flags, sizeof(addr));
        in.psInputAddr = addr & 0xffff;
        for (unsigned k = 0; k < Shader::MaxColorBuffers; ++k) {
            switch (runtime.fs_info.color_buffers[k].export_format) {
            case AmdGpu::ShaderExportFormat::ABGR_UNORM16:
                in.compressedExport[k] = vpgcn::CompressedExport::Unorm16;
                break;
            case AmdGpu::ShaderExportFormat::ABGR_SNORM16:
                in.compressedExport[k] = vpgcn::CompressedExport::Snorm16;
                break;
            case AmdGpu::ShaderExportFormat::ABGR_UINT16:
                in.compressedExport[k] = vpgcn::CompressedExport::Uint16;
                break;
            case AmdGpu::ShaderExportFormat::ABGR_SINT16:
                in.compressedExport[k] = vpgcn::CompressedExport::Sint16;
                break;
            default: in.compressedExport[k] = vpgcn::CompressedExport::Fp16; break;
            }
        }
        break;
    }
    case Shader::Stage::Compute:
        in.stage = vpgcn::ShaderStage::Compute;
        for (unsigned k = 0; k < 3; ++k) {
            in.workgroupSize[k] = runtime.cs_info.workgroup_size[k];
            in.tgidEnable[k] = runtime.cs_info.tgid_enable[k];
        }
        in.tidigCompCnt = runtime.num_input_vgprs ? runtime.num_input_vgprs - 1 : 0;
        in.ldsBytes = runtime.cs_info.shared_memory_size;
        break;
    default: {
        setStatus(info.pgm_hash, stageName(info.stage), Status::Unsupported,
                  std::string("stage ") + stageName(info.stage) + " not lifted yet");
        std::lock_guard g(t.lock);
        ++t.seen;
        ++t.skipped;
        return;
    }
    }
    const uint64_t hash = info.pgm_hash;
    const char* stage = stageName(info.stage);
    setStatus(hash, stage, Status::Pending);
    in.code = code;
    in.fetch = fetch;
    in.userSgprs = runtime.num_user_data;
    // The real descriptors of this draw: texture dimensions and texel types, typed buffer formats.
    in.describe = [&info](const vpgcn::DescriptorSource& src) { return describeDescriptor(src, info); };

    const auto t0 = std::chrono::steady_clock::now();
    vpgcn::LiftResult r = vpgcn::lift(in);
    const double liftMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    if (!r.errors.empty()) {
        std::string all;
        for (const std::string& e : r.errors) all += e + "\n";
        LOG_WARNING(Render_Vulkan, "VPKENGINE_SHADER {} lift: {}", name, r.errors.front());
        std::ofstream(outDir() / (name + ".lift.txt")) << all;
        setStatus(hash, stage, Status::Failed, "lift: " + r.errors.front());
        std::lock_guard g(t.lock);
        ++t.seen;
        ++t.liftFailed;
        for (const std::string& e : r.errors) countError(t, "lift: " + e);
        logTally(t);
        return;
    }
    vpmsl::EmitResult m = vpmsl::emitMsl(r.module);
    if (!m.errors.empty()) {
        LOG_WARNING(Render_Vulkan, "VPKENGINE_SHADER {} verifier: {}", name, m.errors.front());
        setStatus(hash, stage, Status::Failed, "verify: " + m.errors.front());
        std::lock_guard g(t.lock);
        ++t.seen;
        ++t.emitFailed;
        for (const std::string& e : m.errors) countError(t, "verify: " + e);
        logTally(t);
        return;
    }
    {
        std::lock_guard g(t.lock);
        ++t.seen;
        ++t.lifted;
        t.dispatchLoops += !r.structured;
    }
    id<MTLDevice> dev = device();
    if (!dev) {
        LOG_WARNING(Render_Vulkan, "VPKENGINE_SHADER no Metal device");
        setStatus(hash, stage, Status::Failed, "no Metal device");
        return;
    }
    const size_t mslBytes = m.shader.source.size();
    const size_t notes = r.notes.size();
    const bool structured = r.structured;
    std::string source = std::move(m.shader.source);
    NSString* text = [[NSString alloc] initWithBytes:source.data() length:source.size() encoding:NSUTF8StringEncoding];
    MTLCompileOptions* options = [MTLCompileOptions new];
    options.languageVersion = MTLLanguageVersion3_1;
    options.mathMode = MTLMathModeFast;
    dispatch_semaphore_t slots = inFlight();
    dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
    const auto c0 = std::chrono::steady_clock::now();
    [dev newLibraryWithSource:text
                      options:options
            completionHandler:^(id<MTLLibrary> library, NSError* error) {
              dispatch_semaphore_signal(slots);
              const double ms =
                  std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - c0).count();
              Tally& tt = tally();
              if (library) {
                  setStatus(hash, stage, Status::Ok);
                  LOG_INFO(Render_Vulkan,
                           "VPKENGINE_SHADER {} OK: lift {:.2f} ms ({}), {} bytes of MSL, Metal {:.1f} ms, {} notes",
                           name, liftMs, structured ? "structured" : "dispatch loop", mslBytes, ms, notes);
                  std::lock_guard g(tt.lock);
                  ++tt.compiled;
                  tt.compileMs += ms;
                  if ((tt.compiled + tt.compileFailed) % 10 == 0) logTally(tt);
                  return;
              }
              const std::string msg = firstLine(error.localizedDescription);
              LOG_WARNING(Render_Vulkan, "VPKENGINE_SHADER {} Metal: {}", name, msg);
              setStatus(hash, stage, Status::Failed, "Metal: " + msg);
              std::ofstream(outDir() / (name + ".metal")) << source;
              std::ofstream(outDir() / (name + ".metal.txt"))
                  << (error ? [error.localizedDescription UTF8String] : "(no message)");
              std::lock_guard g(tt.lock);
              ++tt.compileFailed;
              countError(tt, "Metal: " + msg);
              logTally(tt);
            }];
}

void NoteDraw(const uint64_t* stage_hashes, size_t count) {
    if (!Enabled()) return;
    Census& c = census();
    std::lock_guard g(c.lock);
    uint64_t blocker = 0;
    const Status s = worst(c, stage_hashes, count, blocker);
    ++c.draws;
    c.drawsOk += s == Status::Ok;
    c.drawsPending += s == Status::Pending;
    if (s == Status::Failed || s == Status::Unsupported) ++c.blocking[blocker];
}

void NoteDispatch(uint64_t cs_hash) {
    if (!Enabled()) return;
    Census& c = census();
    std::lock_guard g(c.lock);
    uint64_t blocker = 0;
    const Status s = worst(c, &cs_hash, 1, blocker);
    ++c.dispatches;
    c.dispatchesOk += s == Status::Ok;
    c.dispatchesPending += s == Status::Pending;
    if (s == Status::Failed || s == Status::Unsupported) ++c.blocking[blocker];
}

void EndFrame() {
    if (!Enabled()) return;
    Census& c = census();
    std::lock_guard g(c.lock);
    ++c.frames;
    const auto now = std::chrono::steady_clock::now();
    if (now - c.since < std::chrono::seconds(10)) return;
    const double n = c.frames;
    auto pct = [](uint64_t part, uint64_t whole) {
        return whole ? fmt::format("{:.1f}%", 100.0 * double(part) / double(whole)) : std::string("n/a");
    };
    // Ready = every shader lifted and compiled by Metal; waiting = a shader not checked (yet): compiled
    // before diagnostic mode or still in the queue; the rest is blocked (listed below).
    LOG_INFO(Render_Vulkan,
             "VPKENGINE_DRAWS: {} frames, per frame {:.0f} draws ({} ready in VPKEngine, {} waiting, {} blocked) and "
             "{:.1f} dispatches ({} ready, {} waiting, {} blocked); {} programs known",
             c.frames, c.draws / n, pct(c.drawsOk, c.draws), pct(c.drawsPending, c.draws),
             pct(c.draws - c.drawsOk - c.drawsPending, c.draws), c.dispatches / n, pct(c.dispatchesOk, c.dispatches),
             pct(c.dispatchesPending, c.dispatches), pct(c.dispatches - c.dispatchesOk - c.dispatchesPending, c.dispatches),
             c.programs.size());
    std::vector<std::pair<uint64_t, uint64_t>> top(c.blocking.begin(), c.blocking.end());
    std::sort(top.begin(), top.end(), [](const auto& a, const auto& b) { return a.second > b.second; });
    for (size_t k = 0; k < top.size() && k < 8; ++k) {
        const Program& p = c.programs[top[k].first];
        LOG_INFO(Render_Vulkan, "VPKENGINE_DRAWS   blocked by {}_{:016x}: {:.1f} per frame ({})", p.stage, top[k].first,
                 top[k].second / n, p.reason.empty() ? "?" : p.reason);
    }
    c.frames = 0;
    c.draws = c.drawsOk = c.drawsPending = c.dispatches = c.dispatchesOk = c.dispatchesPending = 0;
    c.blocking.clear();
    c.since = now;
}

} // namespace VpkengineShaderCheck
