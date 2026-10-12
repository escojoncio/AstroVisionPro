// VPEngine shader check: see vpengine_shader_check.h.
#include "vpengine_shader_check.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

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
#include <vector>

#include "common/logging/log.h"
#include "common/path_util.h"
#include "shader_recompiler/frontend/fetch_shader.h"
#include "shader_recompiler/info.h"
#include "shader_recompiler/runtime_info.h"
#include "vpgcn/lift.h"
#include "vpmsl/msl.h"

namespace VpengineShaderCheck {
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
    auto dir = Common::FS::GetUserPath(Common::FS::PathType::ShaderDir) / "vpengine";
    std::error_code e;
    std::filesystem::create_directories(dir, e);
    return dir;
}

void logTally(Tally& t) {
    LOG_INFO(Render_Vulkan,
             "VPENGINE_SHADERS: {} seen, {} other stages, {} lifted ({} via dispatch loop), {} lift errors, "
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

} // namespace

bool Enabled() {
    static const bool on = [] {
        const char* v = std::getenv("SHADPS4_VPENGINE_SHADER_CHECK");
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
        std::lock_guard g(t.lock);
        ++t.seen;
        ++t.skipped;
        return;
    }
    }
    in.code = code;
    in.fetch = fetch;
    in.userSgprs = runtime.num_user_data;

    const auto t0 = std::chrono::steady_clock::now();
    vpgcn::LiftResult r = vpgcn::lift(in);
    const double liftMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    if (!r.errors.empty()) {
        std::string all;
        for (const std::string& e : r.errors) all += e + "\n";
        LOG_WARNING(Render_Vulkan, "VPENGINE_SHADER {} lift: {}", name, r.errors.front());
        std::ofstream(outDir() / (name + ".lift.txt")) << all;
        std::lock_guard g(t.lock);
        ++t.seen;
        ++t.liftFailed;
        for (const std::string& e : r.errors) countError(t, "lift: " + e);
        logTally(t);
        return;
    }
    vpmsl::EmitResult m = vpmsl::emitMsl(r.module);
    if (!m.errors.empty()) {
        LOG_WARNING(Render_Vulkan, "VPENGINE_SHADER {} verifier: {}", name, m.errors.front());
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
        LOG_WARNING(Render_Vulkan, "VPENGINE_SHADER no Metal device");
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
                  LOG_INFO(Render_Vulkan,
                           "VPENGINE_SHADER {} OK: lift {:.2f} ms ({}), {} bytes of MSL, Metal {:.1f} ms, {} notes",
                           name, liftMs, structured ? "structured" : "dispatch loop", mslBytes, ms, notes);
                  std::lock_guard g(tt.lock);
                  ++tt.compiled;
                  tt.compileMs += ms;
                  if ((tt.compiled + tt.compileFailed) % 10 == 0) logTally(tt);
                  return;
              }
              const std::string msg = firstLine(error.localizedDescription);
              LOG_WARNING(Render_Vulkan, "VPENGINE_SHADER {} Metal: {}", name, msg);
              std::ofstream(outDir() / (name + ".metal")) << source;
              std::ofstream(outDir() / (name + ".metal.txt"))
                  << (error ? [error.localizedDescription UTF8String] : "(no message)");
              std::lock_guard g(tt.lock);
              ++tt.compileFailed;
              countError(tt, "Metal: " + msg);
              logTally(tt);
            }];
}

} // namespace VpengineShaderCheck
