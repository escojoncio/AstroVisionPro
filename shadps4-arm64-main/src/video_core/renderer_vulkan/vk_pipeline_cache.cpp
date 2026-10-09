// SPDX-FileCopyrightText: Copyright 2024-2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <deque>
#include <functional>
#include <thread>
#include <exception>
#include <mutex>
#include <string>
#include <utility>
#include <vector>
#include <ranges>

#include "common/hash.h"
#include "common/io_file.h"
#include "common/path_util.h"
#include "common/thread.h"
#include "core/debug_state.h"
#include "core/emulator_settings.h"
#include "shader_recompiler/backend/spirv/emit_spirv.h"
#include "shader_recompiler/backend/spirv/fma_split_diag.h"
#include "shader_recompiler/info.h"
#include "shader_recompiler/recompiler.h"
#include "shader_recompiler/runtime_info.h"
#include "video_core/amdgpu/liverpool.h"
#include "video_core/cache_storage.h"
#include "video_core/renderer_vulkan/legacy_vertex_attributes.h"
#include "video_core/renderer_vulkan/liverpool_to_vk.h"
#include "video_core/renderer_vulkan/vk_instance.h"
#include "video_core/renderer_vulkan/vk_pipeline_serialization.h"
#include "video_core/renderer_vulkan/vk_scheduler.h"
#include "video_core/renderer_vulkan/vk_shader_util.h"

namespace Vulkan {

using Shader::LogicalStage;
using Shader::Output;
using Shader::Stage;

constexpr static auto SpirvVersion1_6 = 0x00010600U;

constexpr static std::array DescriptorHeapSizes = {
    vk::DescriptorPoolSize{vk::DescriptorType::eUniformBuffer, 512},
    vk::DescriptorPoolSize{vk::DescriptorType::eStorageBuffer, 8192},
    vk::DescriptorPoolSize{vk::DescriptorType::eSampledImage, 8192},
    vk::DescriptorPoolSize{vk::DescriptorType::eStorageImage, 1024},
    vk::DescriptorPoolSize{vk::DescriptorType::eSampler, 1024},
};

#if defined(SHADPS4_VISIONOS)
// What a draw drawn without its geometry shader would have done: the export shader, the
// geometry shader and its copy shader as the console's code (GCN, dwords in hex), with where it
// draws to (the first colour target's slices, the viewports in use). Once for each pair of
// shaders, the first few: lines "GS_CODE <kind> <hash> <offset>: <dwords>".
static void LogGsBypassShaders(const AmdGpu::Regs& regs) {
    static std::mutex mutex;
    static std::vector<std::pair<u64, u64>> seen;
    const auto gs = AmdGpu::GetParams(regs.gs_program);
    const auto es = AmdGpu::GetParams(regs.es_program);
    const auto vc = AmdGpu::GetParams(regs.vs_program);
    {
        std::scoped_lock lock{mutex};
        const std::pair<u64, u64> pair{es.hash, gs.hash};
        if (seen.size() >= 6 || std::ranges::find(seen, pair) != seen.end()) {
            return;
        }
        seen.push_back(pair);
    }
    std::string viewports;
    for (u32 i = 0; i < AmdGpu::NUM_VIEWPORTS; ++i) {
        const auto& vp = regs.viewports[i];
        if (vp.xscale != 0.f) {
            viewports += fmt::format(" [{}: x {} {} y {} {}]", i, vp.xoffset, vp.xscale,
                                     vp.yoffset, vp.yscale);
        }
    }
    const auto& cb = regs.color_buffers[0];
    LOG_INFO(Render_Vulkan,
             "GS_INFO es {:#x} ({} dwords) gs {:#x} ({} dwords) copy {:#x} ({} dwords); esgs "
             "item {} gsvs item {} max out {} instances {}; target 0 at {:#x} slices {}..{}; "
             "viewports{}",
             es.hash, es.code.size(), gs.hash, gs.code.size(), vc.hash, vc.code.size(),
             u32(regs.vgt_esgs_ring_itemsize), u32(regs.vgt_gs_vert_itemsize[0]),
             u32(regs.vgt_gs_max_vert_out),
             regs.vgt_gs_instance_cnt.IsEnabled() ? u32(regs.vgt_gs_instance_cnt.count) : 1u,
             cb.Address(), cb.BaseSlice(), cb.NumSlices(), viewports);
    const auto dump = [](const char* kind, const Shader::ShaderParams& params) {
        const auto code = params.code;
        for (size_t offset = 0; offset < code.size(); offset += 16) {
            std::string line;
            for (size_t i = offset; i < std::min(code.size(), offset + 16); ++i) {
                line += fmt::format(" {:08x}", code[i]);
            }
            LOG_INFO(Render_Vulkan, "GS_CODE {} {:#x} {}:{}", kind, params.hash, offset, line);
        }
    };
    dump("es", es);
    dump("gs", gs);
    dump("copy", vc);
}
#endif

static u32 MapOutputs(std::span<Shader::OutputMap, 3> outputs, const AmdGpu::VsOutputControl& ctl) {
    u32 num_outputs = 0;

    if (ctl.vs_out_misc_enable) {
        auto& misc_vec = outputs[num_outputs++];
        misc_vec[0] = ctl.use_vtx_point_size ? Output::PointSize : Output::None;
        misc_vec[1] = ctl.use_vtx_edge_flag
                          ? Output::EdgeFlag
                          : (ctl.use_vtx_gs_cut_flag ? Output::GsCutFlag : Output::None);
        misc_vec[2] =
            ctl.use_vtx_kill_flag
                ? Output::KillFlag
                : (ctl.use_vtx_render_target_idx ? Output::RenderTargetIndex : Output::None);
        misc_vec[3] = ctl.use_vtx_viewport_idx ? Output::ViewportIndex : Output::None;
    }

    if (ctl.vs_out_ccdist0_enable) {
        auto& ccdist0 = outputs[num_outputs++];
        ccdist0[0] = ctl.IsClipDistEnabled(0)
                         ? Output::ClipDist0
                         : (ctl.IsCullDistEnabled(0) ? Output::CullDist0 : Output::None);
        ccdist0[1] = ctl.IsClipDistEnabled(1)
                         ? Output::ClipDist1
                         : (ctl.IsCullDistEnabled(1) ? Output::CullDist1 : Output::None);
        ccdist0[2] = ctl.IsClipDistEnabled(2)
                         ? Output::ClipDist2
                         : (ctl.IsCullDistEnabled(2) ? Output::CullDist2 : Output::None);
        ccdist0[3] = ctl.IsClipDistEnabled(3)
                         ? Output::ClipDist3
                         : (ctl.IsCullDistEnabled(3) ? Output::CullDist3 : Output::None);
    }

    if (ctl.vs_out_ccdist1_enable) {
        auto& ccdist1 = outputs[num_outputs++];
        ccdist1[0] = ctl.IsClipDistEnabled(4)
                         ? Output::ClipDist4
                         : (ctl.IsCullDistEnabled(4) ? Output::CullDist4 : Output::None);
        ccdist1[1] = ctl.IsClipDistEnabled(5)
                         ? Output::ClipDist5
                         : (ctl.IsCullDistEnabled(5) ? Output::CullDist5 : Output::None);
        ccdist1[2] = ctl.IsClipDistEnabled(6)
                         ? Output::ClipDist6
                         : (ctl.IsCullDistEnabled(6) ? Output::CullDist6 : Output::None);
        ccdist1[3] = ctl.IsClipDistEnabled(7)
                         ? Output::ClipDist7
                         : (ctl.IsCullDistEnabled(7) ? Output::CullDist7 : Output::None);
    }

    return num_outputs;
}

const Shader::RuntimeInfo& PipelineCache::BuildRuntimeInfo(Stage stage, LogicalStage l_stage) {
    auto& info = runtime_infos[u32(l_stage)];
    const auto& regs = liverpool->regs;
    const auto BuildCommon = [&](const auto& program) {
        info.num_user_data = program.settings.num_user_regs;
        info.num_input_vgprs = program.settings.vgpr_comp_cnt;
        info.num_allocated_vgprs = program.NumVgprs();
        info.fp_denorm_mode32 = program.settings.fp_denorm_mode32;
        info.fp_denorm_mode16_64 = program.settings.fp_denorm_mode64;
        info.fp_round_mode32 = program.settings.fp_round_mode32;
        info.fp_round_mode16_64 = program.settings.fp_round_mode64;
    };
    info.Initialize(stage);
    switch (stage) {
    case Stage::Local: {
        BuildCommon(regs.ls_program);
        Shader::TessellationDataConstantBuffer tess_constants{};
        const auto* hull_info = infos[u32(Shader::LogicalStage::TessellationControl)];
        hull_info->ReadTessConstantBuffer(tess_constants);
        info.ls_info.ls_stride = tess_constants.ls_stride;
        break;
    }
    case Stage::Hull: {
        BuildCommon(regs.hs_program);
        info.hs_info.num_input_control_points = regs.ls_hs_config.hs_input_control_points;
        info.hs_info.num_threads = regs.ls_hs_config.hs_output_control_points;
        info.hs_info.tess_type = regs.tess_config.type;
        info.hs_info.offchip_lds_enable = regs.hs_program.settings.oc_lds_en;

        // We need to initialize most hs_info fields after finding the V# with tess constants
        break;
    }
    case Stage::Export: {
        BuildCommon(regs.es_program);
        info.es_info.vertex_data_size = regs.vgt_esgs_ring_itemsize;
        if (l_stage == LogicalStage::TessellationEval) {
            info.es_vs_info.tess_type = regs.tess_config.type;
            info.es_vs_info.tess_topology = regs.tess_config.topology;
            info.es_vs_info.tess_partitioning = regs.tess_config.partitioning;
        }
        break;
    }
    case Stage::Vertex: {
        BuildCommon(regs.vs_program);
        info.vs_info.step_rate_0 = regs.vgt_instance_step_rate_0;
        info.vs_info.step_rate_1 = regs.vgt_instance_step_rate_1;
        info.vs_info.num_outputs = MapOutputs(info.vs_info.outputs, regs.vs_output_control);
        info.vs_info.emulate_depth_negative_one_to_one =
            !instance.IsDepthClipControlSupported() &&
            regs.clipper_control.clip_space == AmdGpu::ClipSpace::MinusWToW;
        info.vs_info.tess_emulated_primitive =
            regs.primitive_type == AmdGpu::PrimitiveType::RectList ||
            regs.primitive_type == AmdGpu::PrimitiveType::QuadList;
        info.vs_info.clip_disable = regs.IsClipDisabled();
        if (l_stage == LogicalStage::TessellationEval) {
            info.es_vs_info.tess_type = regs.tess_config.type;
            info.es_vs_info.tess_topology = regs.tess_config.topology;
            info.es_vs_info.tess_partitioning = regs.tess_config.partitioning;
        }
        break;
    }
    case Stage::Geometry: {
        BuildCommon(regs.gs_program);
        auto& gs_info = info.gs_info;
        gs_info.num_outputs = MapOutputs(gs_info.outputs, regs.vs_output_control);
        gs_info.output_vertices = regs.vgt_gs_max_vert_out;
        gs_info.num_invocations =
            regs.vgt_gs_instance_cnt.IsEnabled() ? regs.vgt_gs_instance_cnt.count : 1;
        if (regs.stage_enable.raw == AmdGpu::ShaderStageEnable::LsHsEsGs) {
            gs_info.in_primitive = [&]() {
                switch (regs.tess_config.topology) {
                case AmdGpu::TessellationTopology::Point:
                    return AmdGpu::PrimitiveType::PointList;
                case AmdGpu::TessellationTopology::Line:
                    return AmdGpu::PrimitiveType::LineList;
                case AmdGpu::TessellationTopology::TriangleCw:
                case AmdGpu::TessellationTopology::TriangleCcw:
                    return AmdGpu::PrimitiveType::TriangleList;
                default:
                    UNREACHABLE();
                }
            }();
        } else {
            gs_info.in_primitive = regs.primitive_type;
        }
        for (u32 stream_id = 0; stream_id < Shader::GsMaxOutputStreams; ++stream_id) {
            gs_info.out_primitive[stream_id] =
                regs.vgt_gs_out_prim_type.GetPrimitiveType(stream_id);
        }
        gs_info.in_vertex_data_size = regs.vgt_esgs_ring_itemsize;
        gs_info.out_vertex_data_size = regs.vgt_gs_vert_itemsize[0];
        gs_info.mode = regs.vgt_gs_mode.mode;
        const auto params_vc = AmdGpu::GetParams(regs.vs_program);
        gs_info.vs_copy = params_vc.code;
        gs_info.vs_copy_hash = params_vc.hash;
        DumpShader(gs_info.vs_copy, gs_info.vs_copy_hash, Shader::Stage::Vertex, 0, "copy.bin");
        break;
    }
    case Stage::Fragment: {
        BuildCommon(regs.ps_program);
        info.fs_info.en_flags = regs.ps_input_ena;
        info.fs_info.addr_flags = regs.ps_input_addr;
        info.fs_info.num_inputs = regs.num_interp;
        info.fs_info.z_export_format = regs.z_export_format;
        u8 stencil_ref_export_enable = regs.depth_shader_control.stencil_op_val_export_enable |
                                       regs.depth_shader_control.stencil_test_val_export_enable;
        info.fs_info.mrtz_mask = regs.depth_shader_control.z_export_enable |
                                 (stencil_ref_export_enable << 1) |
                                 (regs.depth_shader_control.mask_export_enable << 2) |
                                 (regs.depth_shader_control.coverage_to_mask_enable << 3);
        const auto& cb0_blend = regs.blend_control[0];
        if (cb0_blend.enable) {
            info.fs_info.dual_source_blending =
                LiverpoolToVK::IsDualSourceBlendFactor(cb0_blend.color_dst_factor) ||
                LiverpoolToVK::IsDualSourceBlendFactor(cb0_blend.color_src_factor);
            if (cb0_blend.separate_alpha_blend) {
                info.fs_info.dual_source_blending |=
                    LiverpoolToVK::IsDualSourceBlendFactor(cb0_blend.alpha_dst_factor) ||
                    LiverpoolToVK::IsDualSourceBlendFactor(cb0_blend.alpha_src_factor);
            }
        } else {
            info.fs_info.dual_source_blending = false;
        }
        const auto& ps_inputs = regs.ps_inputs;
        for (u32 i = 0; i < regs.num_interp; i++) {
            info.fs_info.inputs[i] = {
                .param_index = u8(ps_inputs[i].input_offset),
                .is_default = bool(ps_inputs[i].use_default),
                .is_flat = bool(ps_inputs[i].flat_shade),
                .default_value = u8(ps_inputs[i].default_value),
            };
        }
        for (u32 i = 0; i < Shader::MaxColorBuffers; i++) {
            info.fs_info.color_buffers[i] = graphics_key.color_buffers[i];
        }
        info.fs_info.clip_distance_emulation =
            regs.vs_output_control.clip_distance_enable &&
            !regs.stage_enable.IsStageEnabled(static_cast<u32>(Stage::Local)) &&
            profile.needs_clip_distance_emulation;
        break;
    }
    case Stage::Compute: {
        const auto& cs_pgm = liverpool->GetCsRegs();
        info.num_user_data = cs_pgm.settings.num_user_regs;
        info.num_allocated_vgprs = cs_pgm.settings.num_vgprs * 4;
        info.cs_info.workgroup_size = {cs_pgm.num_thread_x.full, cs_pgm.num_thread_y.full,
                                       cs_pgm.num_thread_z.full};
        info.cs_info.tgid_enable = {cs_pgm.IsTgidEnabled(0), cs_pgm.IsTgidEnabled(1),
                                    cs_pgm.IsTgidEnabled(2)};
        info.cs_info.shared_memory_size = cs_pgm.SharedMemSize();
        break;
    }
    default:
        break;
    }
    return info;
}

/// A few threads that make pipelines, in the order they were asked for.
class PipelineCache::PipelineWorkers {
public:
    explicit PipelineWorkers(u32 count) {
        for (u32 i = 0; i < count; ++i) {
            threads.emplace_back([this, i] {
                Common::SetCurrentThreadName(fmt::format("shadPS4:Pipelines{}", i).c_str());
                Run();
            });
        }
    }

    ~PipelineWorkers() {
        {
            std::scoped_lock lock{mutex};
            stopping = true;
            jobs.clear();
        }
        wake.notify_all();
        for (auto& thread : threads) {
            thread.join();
        }
    }

    void Push(std::function<void()> job) {
        {
            std::scoped_lock lock{mutex};
            jobs.push_back(std::move(job));
        }
        wake.notify_one();
    }

private:
    void Run() {
        while (true) {
            std::function<void()> job;
            {
                std::unique_lock lock{mutex};
                wake.wait(lock, [this] { return stopping || !jobs.empty(); });
                if (stopping) {
                    return;
                }
                job = std::move(jobs.front());
                jobs.pop_front();
            }
            job();
        }
    }

    std::mutex mutex;
    std::condition_variable wake;
    std::deque<std::function<void()>> jobs;
    bool stopping{};
    std::vector<std::thread> threads;
};

PipelineCache::PipelineCache(const Instance& instance_, Scheduler& scheduler_,
                             AmdGpu::Liverpool* liverpool_)
    : instance{instance_}, scheduler{scheduler_}, liverpool{liverpool_},
      desc_heap{instance, scheduler.GetMasterSemaphore(), DescriptorHeapSizes} {
    const auto& vk12_props = instance.GetVk12Properties();
    profile = Shader::Profile{
        // When binding a UBO, we calculate its size considering the offset in the larger buffer
        // cache underlying resource. In some cases, it may produce sizes exceeding the system
        // maximum allowed UBO range, so we need to reduce the threshold to prevent issues.
        .max_ubo_size = instance.UniformMaxSize() - instance.UniformMinAlignment(),
        .max_viewport_width = instance.GetMaxViewportWidth(),
        .max_viewport_height = instance.GetMaxViewportHeight(),
        .max_shared_memory_size = instance.MaxComputeSharedMemorySize(),
        .supported_spirv = SpirvVersion1_6,
        .subgroup_size = instance.SubgroupSize(),
        .support_int8 = instance.IsShaderInt8Supported(),
        .support_int16 = instance.IsShaderInt16Supported(),
        .support_int64 = instance.IsShaderInt64Supported(),
        .support_float16 = instance.IsShaderFloat16Supported(),
        .support_float64 = instance.IsShaderFloat64Supported(),
        .supports_denorm_behavior_independence =
            vk12_props.denormBehaviorIndependence != vk::ShaderFloatControlsIndependence::eNone,
        .supports_rounding_mode_independence =
            vk12_props.roundingModeIndependence != vk::ShaderFloatControlsIndependence::eNone,
        .support_fp16_denorm_preserve = bool(vk12_props.shaderDenormPreserveFloat16),
        .support_fp16_denorm_flush = bool(vk12_props.shaderDenormFlushToZeroFloat16),
        .support_fp16_round_to_zero = bool(vk12_props.shaderRoundingModeRTZFloat16),
        .support_fp32_denorm_preserve = bool(vk12_props.shaderDenormPreserveFloat32),
        .support_fp32_denorm_flush = bool(vk12_props.shaderDenormFlushToZeroFloat32),
        .support_fp32_round_to_zero = bool(vk12_props.shaderRoundingModeRTZFloat32),
        .support_fp64_denorm_preserve = bool(vk12_props.shaderDenormPreserveFloat64),
        .support_fp64_denorm_flush = bool(vk12_props.shaderDenormFlushToZeroFloat64),
        .support_fp64_round_to_zero = bool(vk12_props.shaderRoundingModeRTZFloat64),
        .support_fp16_signed_zero_inf_nan_preserve =
            bool(vk12_props.shaderSignedZeroInfNanPreserveFloat16),
        .support_fp32_signed_zero_inf_nan_preserve =
            bool(vk12_props.shaderSignedZeroInfNanPreserveFloat32),
        .support_fp64_signed_zero_inf_nan_preserve =
            bool(vk12_props.shaderSignedZeroInfNanPreserveFloat64),
        .support_legacy_vertex_attributes = instance_.IsLegacyVertexAttributesSupported(),
        .supports_image_load_store_lod = instance_.IsImageLoadStoreLodSupported(),
        .supports_native_cube_calc = instance_.IsAmdGcnShaderSupported(),
        .supports_trinary_minmax = instance_.IsAmdShaderTrinaryMinMaxSupported(),
        .supports_buffer_fp32_atomic_min_max =
            instance_.IsShaderAtomicFloatBuffer32MinMaxSupported(),
        .supports_image_fp32_atomic_min_max = instance_.IsShaderAtomicFloatImage32MinMaxSupported(),
        .supports_buffer_int64_atomics = instance_.IsBufferInt64AtomicsSupported(),
        .supports_shared_int64_atomics = instance_.IsSharedInt64AtomicsSupported(),
        .supports_workgroup_explicit_memory_layout =
            instance_.IsWorkgroupMemoryExplicitLayoutSupported(),
        .supports_amd_shader_explicit_vertex_parameter =
            instance_.IsAmdShaderExplicitVertexParameterSupported(),
        .supports_fragment_shader_barycentric = instance_.IsFragmentShaderBarycentricSupported(),
        .needs_manual_interpolation = instance.IsFragmentShaderBarycentricSupported() &&
                                      instance.GetDriverID() == vk::DriverId::eNvidiaProprietary,
        .needs_lds_barriers = instance.GetDriverID() == vk::DriverId::eNvidiaProprietary ||
                              instance.GetDriverID() == vk::DriverId::eMesaKosmickrisp,
        .needs_buffer_offsets = instance.StorageMinAlignment() > 4,
        .needs_unorm_fixup = instance.GetDriverID() == vk::DriverId::eMesaKosmickrisp,
        .needs_clip_distance_emulation = instance.GetDriverID() == vk::DriverId::eNvidiaProprietary,
        .needs_bit_preserving_buffer0_loads =
            ShouldForceBitPreservingBuffer0Loads(instance_.GetModelName()),
        .supports_shader_stencil_export = instance_.IsShaderStencilExportSupported(),
        .supports_shader_cull_distance = instance_.IsShaderCullDistanceSupported(),
        .max_clip_distances = instance_.GetMaxClipDistances(),
        .max_cull_distances = instance_.GetMaxCullDistances(),
        .max_combined_clip_and_cull_distances = instance_.GetMaxCombinedClipAndCullDistances(),
    };
    if (profile.needs_bit_preserving_buffer0_loads) {
        LOG_WARNING(Render_Vulkan,
                    "Forcing buffer #0 F32 loads as U32 bitcast on {} (IEEE-bit preserving)",
                    instance_.GetModelName());
    }
    WarmUp();

    auto [cache_result, cache] = instance.GetDevice().createPipelineCacheUnique({});
    ASSERT_MSG(cache_result == vk::Result::eSuccess, "Failed to create pipeline cache: {}",
               vk::to_string(cache_result));
    pipeline_cache = std::move(cache);

#if defined(SHADPS4_VISIONOS)
    async_pipelines = true;
#endif
    if (const char* value = std::getenv("SHADPS4_ASYNC_PIPELINES")) {
        async_pipelines = std::string_view{value} != "0";
    }
    if (async_pipelines) {
        const u32 cores = std::max(1u, std::thread::hardware_concurrency());
        const u32 count = std::clamp(cores / 3, 2u, 4u);
        workers = std::make_unique<PipelineWorkers>(count);
        LOG_INFO(Render_Vulkan,
                 "Graphics pipelines are made on {} threads of their own; a draw whose pipeline "
                 "is not ready yet is left out",
                 count);
    }
}

PipelineCache::~PipelineCache() = default;

/// How long a draw waits for its pipeline being made on a worker before it is left out
/// (SHADPS4_PIPELINE_WAIT_MS, 0 to 200; 40 by default). Most come from the driver's shader cache
/// in a few milliseconds: a draw left out for them is a picture without what it draws (a
/// world shown whole for a moment before the title's own effect of building it up starts).
static std::chrono::milliseconds PipelineWait() {
    static const std::chrono::milliseconds wait = [] {
        long ms = 40;
        if (const char* value = std::getenv("SHADPS4_PIPELINE_WAIT_MS"); value && *value) {
            ms = std::clamp(std::atol(value), 0L, 200L);
        }
        return std::chrono::milliseconds{ms};
    }();
    return wait;
}

/// Waits for the job to be done, the first draw that asks only; true when it is.
template <typename Job>
static bool WaitForJob(Job& job) {
    const auto& done = job.done;
    if (done.load(std::memory_order_acquire)) {
        return true;
    }
    if (std::exchange(job.waited, true)) {
        return false;
    }
    // No more than PipelineWait in all in any tenth of a second: many new pipelines at once
    // (a level coming in) cost a few frames, not one of seconds.
    using Clock = std::chrono::steady_clock;
    static Clock::time_point window_start{};
    static Clock::duration window_waited{};
    const auto now = Clock::now();
    if (now - window_start > std::chrono::milliseconds(100)) {
        window_start = now;
        window_waited = {};
    }
    const auto budget = PipelineWait() - window_waited;
    if (budget <= Clock::duration::zero()) {
        return false;
    }
    const auto until = now + budget;
    bool ready = true;
    while (!done.load(std::memory_order_acquire)) {
        if (Clock::now() >= until) {
            ready = false;
            break;
        }
        std::this_thread::sleep_for(std::chrono::microseconds(250));
    }
    window_waited += Clock::now() - now;
    return ready;
}

const GraphicsPipeline* PipelineCache::GetGraphicsPipeline() {
    const auto started = std::chrono::steady_clock::now();
    if (!RefreshGraphicsKey()) {
        return nullptr;
    }
    if (async_pipelines) {
        if (const auto ready = graphics_pipelines.find(graphics_key);
            ready != graphics_pipelines.end()) {
            fetch_shader.reset();
            return ready->second.get();
        }
        if (const auto pending = pending_graphics_pipelines.find(graphics_key);
            pending != pending_graphics_pipelines.end()) {
            fetch_shader.reset();
            if (!WaitForJob(*pending->second)) {
                ++skipped_draws;
                return nullptr;
            }
            const auto job = pending->second;
            pending_graphics_pipelines.erase(pending);
            return FinishPendingGraphicsPipeline(*job);
        }
        // A new one: what it needs is taken now, it is made on a worker thread.
        auto job = std::make_shared<PendingGraphicsPipeline>();
        job->key = graphics_key;
        job->hash = std::hash<GraphicsPipelineKey>{}(graphics_key);
        for (u32 stage = 0; stage < MaxShaderStages; ++stage) {
            job->live_infos[stage] = infos[stage];
            if (infos[stage] != nullptr) {
                job->info_copies[stage].emplace(*infos[stage]);
                job->copy_infos[stage] = &*job->info_copies[stage];
            }
        }
        job->runtime_infos = runtime_infos;
        job->modules = modules;
        job->fetch_shader = fetch_shader;
        job->queued = std::chrono::steady_clock::now();
        GraphicsPipeline::PrepareSerialization(instance, job->key, job->copy_infos,
                                               job->runtime_infos, job->fetch_shader,
                                               job->sdata);
        pending_graphics_pipelines.emplace(graphics_key, job);
        LOG_INFO(Render_Vulkan, "Compiling graphics pipeline {:#x} (on a worker)", job->hash);
        const vk::PipelineCache cache_handle = *pipeline_cache;
        workers->Push([this, job, cache_handle] {
            const auto begun = std::chrono::steady_clock::now();
            try {
                job->result = std::make_unique<GraphicsPipeline>(
                    instance, scheduler, desc_heap, profile, job->key, cache_handle,
                    job->copy_infos, job->runtime_infos, job->fetch_shader, job->modules,
                    job->sdata, true);
            } catch (const std::exception& ex) {
                job->error = ex.what();
                job->result.reset();
            }
            job->compile_ms = static_cast<u32>(
                std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - begun)
                    .count());
            job->done.store(true, std::memory_order_release);
        });
        fetch_shader.reset();
        if (WaitForJob(*job)) {
            const auto it_pending = pending_graphics_pipelines.find(graphics_key);
            const auto ready_job = it_pending->second;
            pending_graphics_pipelines.erase(it_pending);
            return FinishPendingGraphicsPipeline(*ready_job);
        }
        ++skipped_draws;
        return nullptr;
    }

    const auto [it, is_new] = graphics_pipelines.try_emplace(graphics_key);
    if (is_new) {
        const auto pipeline_hash = std::hash<GraphicsPipelineKey>{}(graphics_key);
        LOG_INFO(Render_Vulkan, "Compiling graphics pipeline {:#x}", pipeline_hash);

        GraphicsPipeline::SerializationSupport sdata{};
        try {
            if (const auto* vs = infos[u32(Shader::LogicalStage::Vertex)]) {
                LOG_INFO(Render_Vulkan,
                         "Pipeline {:#x} resources vs buf={} img={} samp={} fetch={}",
                         pipeline_hash, vs->buffers.size(), vs->images.size(), vs->samplers.size(),
                         fetch_shader ? fetch_shader->attributes.size() : 0);
            }
            if (const auto* fs = infos[u32(Shader::LogicalStage::Fragment)]) {
                LOG_INFO(Render_Vulkan, "Pipeline {:#x} resources fs buf={} img={} samp={}",
                         pipeline_hash, fs->buffers.size(), fs->images.size(),
                         fs->samplers.size());
            }
            it.value() = std::make_unique<GraphicsPipeline>(
                instance, scheduler, desc_heap, profile, graphics_key, *pipeline_cache, infos,
                runtime_infos, fetch_shader, modules, sdata, false);
        } catch (const std::exception& ex) {
            LOG_ERROR(Render_Vulkan, "Graphics pipeline {:#x} compile failed: {}", pipeline_hash,
                      ex.what());
            it.value().reset();
            fetch_shader.reset();
            return nullptr;
        }

        RegisterPipelineData(graphics_key, pipeline_hash, sdata);
        ++num_new_pipelines;
        // How long the draw waited for its shaders and pipeline (all of it on this thread).
        const auto took = std::chrono::duration_cast<std::chrono::milliseconds>(
                              std::chrono::steady_clock::now() - started)
                              .count();
        if (took >= 30) {
            LOG_INFO(Render_Vulkan, "PIPELINE_SLOW {:#x}: {} ms (pipeline {} of this run)",
                     pipeline_hash, took, num_new_pipelines);
        }

        if (EmulatorSettings.IsShaderCollect()) {
            for (auto stage = 0; stage < MaxShaderStages; ++stage) {
                if (infos[stage]) {
                    auto& m = modules[stage];
                    module_related_pipelines[m].emplace_back(graphics_key);
                }
            }
        }
        fetch_shader.reset();
    }
    return it->second.get();
}

const GraphicsPipeline* PipelineCache::FinishPendingGraphicsPipeline(
    PendingGraphicsPipeline& job) {
    const auto waited = std::chrono::duration_cast<std::chrono::milliseconds>(
                            std::chrono::steady_clock::now() - job.queued)
                            .count();
    if (!job.result) {
        LOG_ERROR(Render_Vulkan, "Graphics pipeline {:#x} compile failed: {}", job.hash,
                  job.error);
        graphics_pipelines.emplace(job.key, nullptr);
        return nullptr;
    }
    // From now on the draws bind what the live descriptions say, as for any other pipeline.
    job.result->UseStages(job.live_infos);
    RegisterPipelineData(job.key, job.hash, job.sdata);
    ++num_new_pipelines;
    if (job.compile_ms >= 30 || waited >= 100) {
        LOG_INFO(Render_Vulkan,
                 "PIPELINE_SLOW {:#x}: {} ms to make, ready {} ms after its first draw (pipeline "
                 "{} of this run; {} draws left out so far)",
                 job.hash, job.compile_ms, waited, num_new_pipelines, skipped_draws);
    }
    if (EmulatorSettings.IsShaderCollect()) {
        for (auto stage = 0; stage < MaxShaderStages; ++stage) {
            if (job.live_infos[stage]) {
                module_related_pipelines[job.modules[stage]].emplace_back(job.key);
            }
        }
    }
    const auto [it, inserted] = graphics_pipelines.emplace(job.key, std::move(job.result));
    return it->second.get();
}

const ComputePipeline* PipelineCache::GetComputePipeline() {
    if (!RefreshComputeKey()) {
        return nullptr;
    }
    const auto [it, is_new] = compute_pipelines.try_emplace(compute_key);
    if (is_new) {
        const auto pipeline_hash = std::hash<ComputePipelineKey>{}(compute_key);
        LOG_INFO(Render_Vulkan, "Compiling compute pipeline {:#x}", pipeline_hash);

        ComputePipeline::SerializationSupport sdata{};
        it.value() = std::make_unique<ComputePipeline>(instance, scheduler, desc_heap, profile,
                                                       *pipeline_cache, compute_key, *infos[0],
                                                       modules[0], sdata, false);
        RegisterPipelineData(compute_key, sdata);
        ++num_new_pipelines;

        if (EmulatorSettings.IsShaderCollect()) {
            auto& m = modules[0];
            module_related_pipelines[m].emplace_back(compute_key);
        }
    }
    return it->second.get();
}

bool PipelineCache::RefreshGraphicsKey() {
    std::memset(&graphics_key, 0, sizeof(GraphicsPipelineKey));
    const auto& regs = liverpool->regs;
    auto& key = graphics_key;

    const bool db_enabled = regs.depth_buffer.DepthValid() || regs.depth_buffer.StencilValid();

    key.z_format = regs.depth_buffer.DepthValid() ? regs.depth_buffer.z_info.format
                                                  : AmdGpu::DepthBuffer::ZFormat::Invalid;
    key.stencil_format = regs.depth_buffer.StencilValid()
                             ? regs.depth_buffer.stencil_info.format
                             : AmdGpu::DepthBuffer::StencilFormat::Invalid;
    key.depth_clamp_enable = !regs.depth_render_override.disable_viewport_clamp;
    key.depth_clip_enable = regs.clipper_control.ZclipEnable();
    key.clip_space = regs.clipper_control.clip_space;
    key.provoking_vtx_last = regs.polygon_control.provoking_vtx_last;
    key.prim_type = regs.primitive_type;
    key.polygon_mode = regs.polygon_control.PolyMode();
    key.patch_control_points =
        regs.stage_enable.hs_en ? regs.ls_hs_config.hs_input_control_points : 0;
    key.logic_op = regs.color_control.rop3;
    key.depth_samples = db_enabled ? regs.depth_buffer.NumSamples() : 1;
    key.num_samples = key.depth_samples;
    key.cb_shader_mask = regs.color_shader_mask;

    const bool skip_cb_binding =
        regs.color_control.mode == AmdGpu::ColorControl::OperationMode::Disable;

    // First pass to fill render target information needed by shader recompiler
    for (s32 cb = 0; cb < AmdGpu::NUM_COLOR_BUFFERS && !skip_cb_binding; ++cb) {
        const auto& col_buf = regs.color_buffers[cb];
        if (!col_buf || !regs.color_target_mask.GetMask(cb)) {
            // No attachment bound or writing to it is disabled.
            continue;
        }

        // Fill color target information
        auto& color_buffer = key.color_buffers[cb];
        color_buffer.data_format = col_buf.GetDataFmt();
        color_buffer.num_format = col_buf.GetNumberFmt();
        color_buffer.num_conversion = col_buf.GetNumberConversion();
        color_buffer.export_format = regs.color_export_format.GetFormat(cb);
        color_buffer.swizzle = col_buf.Swizzle();
    }

    // Compile and bind shader stages
    if (!RefreshGraphicsStages()) {
        return false;
    }

    // Targets this pass of a draw leaves out (LeaveTargetsOut): the shaders are the ones of
    // the whole draw, what they write there goes nowhere.
    if (targets_left_out != 0) {
        key.mrt_mask &= ~targets_left_out;
        key.num_color_attachments = std::bit_width(key.mrt_mask);
        for (s32 cb = 0; cb < AmdGpu::NUM_COLOR_BUFFERS; ++cb) {
            if ((targets_left_out & (1u << cb)) != 0) {
                std::memset(&key.color_buffers[cb], 0, sizeof(Shader::PsColorBuffer));
            }
        }
    }

    // Second pass to mask out render targets not written by shader and fill remaining info
    u8 color_samples = 0;
    bool all_color_samples_same = true;
    for (s32 cb = 0; cb < key.num_color_attachments && !skip_cb_binding; ++cb) {
        const auto& col_buf = regs.color_buffers[cb];
        const u32 target_mask = regs.color_target_mask.GetMask(cb);
        if (!col_buf || !target_mask) {
            continue;
        }
        if ((key.mrt_mask & (1u << cb)) == 0) {
            std::memset(&key.color_buffers[cb], 0, sizeof(Shader::PsColorBuffer));
            continue;
        }

        // Fill color blending information
        if (regs.blend_control[cb].enable && !col_buf.info.blend_bypass) {
            key.blend_controls[cb] = regs.blend_control[cb];
        }

        // Apply swizzle to target mask
        key.write_masks[cb] =
            vk::ColorComponentFlags{key.color_buffers[cb].swizzle.ApplyMask(target_mask)};

        // Fill color samples
        const u8 prev_color_samples = std::exchange(color_samples, col_buf.NumSamples());
        all_color_samples_same &= color_samples == prev_color_samples || prev_color_samples == 0;
        key.color_samples[cb] = color_samples;
        key.num_samples = std::max(key.num_samples, color_samples);
    }

    // Force all color samples to match depth samples to avoid unsupported MSAA configuration
    if (color_samples != 0) {
        const bool depth_mismatch = db_enabled && color_samples != key.depth_samples;
        if (!all_color_samples_same && !instance.IsMixedAnySamplesSupported() ||
            all_color_samples_same && depth_mismatch && !instance.IsMixedDepthSamplesSupported()) {
            key.color_samples.fill(key.depth_samples);
            key.num_samples = key.depth_samples;
        }
    }

    // A draw made in a pass that has more targets than it (MakeForOpenPass): the pipeline is
    // made for all of the pass's, and those that are not the draw's own are written to by
    // nothing (no channel, no blending). The shaders stay the draw's.
    if (const auto* pass = open_pass_targets) {
        for (u32 cb = 0; cb < AmdGpu::NUM_COLOR_BUFFERS; ++cb) {
            const bool own = (pass->own_colors & (1u << cb)) != 0;
            if (own && cb < pass->num_color_attachments) {
                continue;
            }
            key.color_buffers[cb] =
                cb < pass->num_color_attachments ? pass->color_buffers[cb] : Shader::PsColorBuffer{};
            key.blend_controls[cb] = {};
            key.write_masks[cb] = {};
            key.color_samples[cb] = cb < pass->num_color_attachments ? pass->color_samples[cb] : 0;
        }
        key.num_color_attachments = pass->num_color_attachments;
        key.num_samples = pass->num_samples;
        key.depth_samples = pass->depth_samples;
        key.z_format = pass->z_format;
        key.stencil_format = pass->stencil_format;
    }

    return true;
}

bool PipelineCache::RefreshGraphicsStages() {
    const auto& regs = liverpool->regs;
    auto& key = graphics_key;
    fetch_shader = std::nullopt;

    Shader::Backend::Bindings binding{};
    const auto bind_stage = [&](Shader::Stage stage_in, Shader::LogicalStage stage_out) -> bool {
        const auto stage_in_idx = static_cast<u32>(stage_in);
        const auto stage_out_idx = static_cast<u32>(stage_out);
        if (!regs.stage_enable.IsStageEnabled(stage_in_idx)) {
            key.stage_hashes[stage_out_idx] = 0;
            infos[stage_out_idx] = nullptr;
            return false;
        }

        const auto* pgm = regs.ProgramForStage(stage_in_idx);
        if (!pgm || !pgm->Address<u32*>()) {
            key.stage_hashes[stage_out_idx] = 0;
            infos[stage_out_idx] = nullptr;
            return false;
        }

        const auto params = AmdGpu::GetParams(*pgm);
        std::optional<Shader::Gcn::FetchShaderData> fetch_shader_;
        std::tie(infos[stage_out_idx], modules[stage_out_idx], fetch_shader_,
                 key.stage_hashes[stage_out_idx]) =
            GetProgram(stage_in, stage_out, params, binding);
        if (fetch_shader_) {
            fetch_shader = fetch_shader_;
        }
        return true;
    };

    infos.fill(nullptr);
    modules.fill(nullptr);
    const auto result = bind_stage(Stage::Fragment, LogicalStage::Fragment);
    if (!result && regs.vs_output_control.clip_distance_enable &&
        profile.needs_clip_distance_emulation) {
        // TODO: need to implement a discard only fallback shader
        LOG_WARNING(Render_Vulkan,
                    "Clip distance emulation is ineffective due to absense of fragment shader");
    }

    const auto* fs_info = infos[static_cast<u32>(LogicalStage::Fragment)];
    key.mrt_mask = fs_info ? fs_info->mrt_mask : 0u;
    key.num_color_attachments = std::bit_width(key.mrt_mask);

    switch (regs.stage_enable.raw) {
    case AmdGpu::ShaderStageEnable::VgtStages::EsGs:
        if (!instance.IsGeometryStageSupported()) {
#if defined(SHADPS4_VISIONOS)
            // Experimental: Metal has no geometry shaders. Instead of dropping the draw, the
            // export shader (what feeds the geometry shader) is drawn as the vertex shader, as if
            // the geometry shader passed its triangles through unchanged. Right for the many
            // that do (or that only pick a layer); wrong, but visible, for the rest.
            if (!regs.vgt_gs_mode.onchip && !regs.vgt_strmout_config.raw &&
                bind_stage(Stage::Export, LogicalStage::Vertex)) {
                static std::atomic<u32> reported{};
                if (reported.fetch_add(1, std::memory_order_relaxed) < 24) {
                    LOG_INFO(Render_Vulkan,
                             "GS_BYPASS: drawing without the geometry shader (instances {}, "
                             "max vertices out {}, primitive in {}, out {})",
                             regs.vgt_gs_instance_cnt.IsEnabled()
                                 ? u32(regs.vgt_gs_instance_cnt.count)
                                 : 1u,
                             u32(regs.vgt_gs_max_vert_out), u32(regs.primitive_type),
                             u32(regs.vgt_gs_out_prim_type.GetPrimitiveType(0)));
                }
                LogGsBypassShaders(regs);
                break;
            }
#endif
            LOG_WARNING(Render_Vulkan, "Geometry shader stage unsupported, skipping");
            return false;
        }
        if (regs.vgt_gs_mode.onchip || regs.vgt_strmout_config.raw) {
            LOG_WARNING(Render_Vulkan, "Geometry shader features unsupported, skipping");
            return false;
        }
        if (!bind_stage(Stage::Export, LogicalStage::Vertex)) {
            return false;
        }
        if (!bind_stage(Stage::Geometry, LogicalStage::Geometry)) {
            return false;
        }
#if defined(SHADPS4_VISIONOS)
        {
            // Which console shader each GS_DRAWS hash is, and (the first few) its code.
            static std::mutex named_mutex;
            static std::vector<size_t> named;
            const size_t hash = key.stage_hashes[static_cast<u32>(LogicalStage::Geometry)];
            bool is_new = false;
            {
                std::scoped_lock lock{named_mutex};
                if (named.size() < 64 && std::ranges::find(named, hash) == named.end()) {
                    named.push_back(hash);
                    is_new = true;
                }
            }
            if (is_new) {
                LOG_INFO(Render_Vulkan, "GS_HASH {:#x}: es {:#x} gs {:#x}", hash,
                         AmdGpu::GetParams(regs.es_program).hash,
                         AmdGpu::GetParams(regs.gs_program).hash);
                LogGsBypassShaders(regs);
            }
        }
#endif
        break;
    case AmdGpu::ShaderStageEnable::VgtStages::LsHs:
        if (!instance.IsTessellationSupported()) {
            return false;
        }
        if (!bind_stage(Stage::Hull, LogicalStage::TessellationControl)) {
            return false;
        }
        if (!bind_stage(Stage::Vertex, LogicalStage::TessellationEval)) {
            return false;
        }
        if (!bind_stage(Stage::Local, LogicalStage::Vertex)) {
            return false;
        }
        break;
    case AmdGpu::ShaderStageEnable::VgtStages::LsHsEsGs:
        if (!instance.IsTessellationSupported()) {
            return false;
        }
        if (!instance.IsGeometryStageSupported()) {
            LOG_WARNING(Render_Vulkan, "Geometry shader stage unsupported, skipping");
            return false;
        }
        if (regs.vgt_gs_mode.onchip || regs.vgt_strmout_config.raw) {
            LOG_WARNING(Render_Vulkan, "Geometry shader features unsupported, skipping");
            return false;
        }
        if (!bind_stage(Stage::Hull, LogicalStage::TessellationControl)) {
            return false;
        }
        if (!bind_stage(Stage::Export, LogicalStage::TessellationEval)) {
            return false;
        }
        if (!bind_stage(Stage::Local, LogicalStage::Vertex)) {
            return false;
        }
        if (!bind_stage(Stage::Geometry, LogicalStage::Geometry)) {
            return false;
        }
        break;
    case AmdGpu::ShaderStageEnable::VgtStages::Vs:
        bind_stage(Stage::Vertex, LogicalStage::Vertex);
        break;
    default:
        UNREACHABLE_MSG("unhandled stage_en: {}", (u32)regs.stage_enable.raw);
    }

    const auto* vs_info = infos[static_cast<u32>(Shader::LogicalStage::Vertex)];
    if (vs_info && fetch_shader && !instance.IsVertexInputDynamicState()) {
        // Without vertex input dynamic state, the pipeline needs to specialize on format.
        // Stride will still be handled outside the pipeline using dynamic state.
        u32 vertex_binding = 0;
        for (const auto& attrib : fetch_shader->attributes) {
            const auto& buffer = attrib.GetSharp(*vs_info);
            ASSERT_MSG(vertex_binding < MaxVertexBufferCount,
                       "Vertex attribute binding count exceeded limit: {} >= {}", vertex_binding,
                       MaxVertexBufferCount);
            key.vertex_buffer_formats[vertex_binding++] =
                Vulkan::LiverpoolToVK::SurfaceFormat(buffer.GetDataFmt(), buffer.GetNumberFmt());
        }
    }

    return true;
}

bool PipelineCache::RefreshComputeKey() {
    Shader::Backend::Bindings binding{};
    const auto& cs_pgm = liverpool->GetCsRegs();
    const auto cs_params = AmdGpu::GetParams(cs_pgm);
    std::tie(infos[0], modules[0], fetch_shader, compute_key.value) =
        GetProgram(Shader::Stage::Compute, LogicalStage::Compute, cs_params, binding);
    return true;
}

vk::ShaderModule PipelineCache::CompileModule(Shader::Info& info, Shader::RuntimeInfo& runtime_info,
                                              const std::span<const u32>& code, size_t perm_idx,
                                              Shader::Backend::Bindings& binding) {
    LOG_INFO(Render_Vulkan, "Compiling {} shader {:#x} {}", info.stage, info.pgm_hash,
             perm_idx != 0 ? "(permutation)" : "");
    DumpShader(code, info.pgm_hash, info.stage, perm_idx, "bin");

    const auto ir_program = Shader::TranslateProgram(code, pools, info, runtime_info, profile);
    auto spv = Shader::Backend::SPIRV::EmitSPIRV(profile, runtime_info, ir_program, binding);
    DumpShader(spv, info.pgm_hash, info.stage, perm_idx, "spv");
    if (Shader::Backend::SPIRV::ShouldSplitFmaNoContraction(info.pgm_hash, info.stage) &&
        EmulatorSettings.IsDumpShaders()) {
        const auto scan = Shader::Backend::SPIRV::ScanSpirvFmaOps(spv);
        const bool survived = Shader::Backend::SPIRV::SplitFmaSurvivedBackend(scan) &&
                              scan.contraction_off > 0;
        using namespace Common::FS;
        const auto dump_dir = GetUserPath(PathType::ShaderDir) / "dumps";
        if (!std::filesystem::exists(dump_dir)) {
            std::filesystem::create_directories(dump_dir);
        }
        const auto filename =
            fmt::format("{}.fmasplit.txt", GetShaderName(info.stage, info.pgm_hash, perm_idx));
        const auto file = IOFile{dump_dir / filename, FileAccessMode::Create};
        const auto text = fmt::format(
            "A830_FMA_SPLIT spirv scan\nshader={:#x}\nOpFMul={}\nOpFAdd={}\nGLSLstd450Fma={}\n"
            "OpFmaKHR={}\nNoContraction={}\nContractionOff={}\nsurvived={}\n",
            info.pgm_hash, scan.op_fmul, scan.op_fadd, scan.glsl_fma, scan.op_fma_khr,
            scan.no_contraction, scan.contraction_off, survived ? "YES" : "NO");
        file.WriteString(std::span<const char>{text.data(), text.size()});
    }

    vk::ShaderModule module;

    auto patch = GetShaderPatch(info.pgm_hash, info.stage, perm_idx, "spv");
    const bool is_patched = patch && EmulatorSettings.IsPatchShaders();
    if (is_patched) {
        LOG_INFO(Loader, "Loaded patch for {} shader {:#x}", info.stage, info.pgm_hash);
        module = CompileSPV(*patch, instance.GetDevice());
    } else {
        module = CompileSPV(spv, instance.GetDevice());
    }

    RegisterShaderBinary(std::move(spv), info.pgm_hash, perm_idx);

    const auto name = GetShaderName(info.stage, info.pgm_hash, perm_idx);
    Vulkan::SetObjectName(instance.GetDevice(), module, name);
    if (EmulatorSettings.IsShaderCollect()) {
        DebugState.CollectShader(name, info.l_stage, module, spv, code,
                                 patch ? *patch : std::span<const u32>{}, is_patched);
    }
    return module;
}

PipelineCache::Result PipelineCache::GetProgram(Stage stage, LogicalStage l_stage,
                                                const Shader::ShaderParams& params,
                                                Shader::Backend::Bindings& binding) {
    auto runtime_info = BuildRuntimeInfo(stage, l_stage);
    auto [it_pgm, new_program] = program_cache.try_emplace(params.hash);
    if (new_program) {
        it_pgm.value() = std::make_unique<Program>(stage, l_stage, params);
        auto& program = it_pgm.value();
        auto start = binding;
        const auto module = CompileModule(program->info, runtime_info, params.code, 0, binding);
        auto spec = Shader::StageSpecialization(program->info, runtime_info, profile, start);
        const auto perm_hash = HashCombine(params.hash, 0);

        RegisterShaderMeta(program->info, spec.fetch_shader_data, spec, perm_hash, 0);
        program->AddPermut(module, std::move(spec));
        return std::make_tuple(&program->info, module, program->modules[0].spec.fetch_shader_data,
                               perm_hash);
    }

    auto& program = it_pgm.value();
    auto& info = program->info;
    info.pgm_base = params.Base(); // Needs to be actualized for inline cbuffer address fixup
    info.user_data = params.user_data;
    info.RefreshFlatBuf();
    auto spec = Shader::StageSpecialization(info, runtime_info, profile, binding);

    size_t perm_idx = program->modules.size();
    u64 perm_hash = HashCombine(params.hash, perm_idx);

    vk::ShaderModule module{};

    const auto it = std::ranges::find(program->modules, spec, &Program::Module::spec);
    if (it == program->modules.end()) {
        auto new_info = Shader::Info(stage, l_stage, params);
        module = CompileModule(new_info, runtime_info, params.code, perm_idx, binding);

        RegisterShaderMeta(info, spec.fetch_shader_data, spec, perm_hash, perm_idx);
        program->AddPermut(module, std::move(spec));
    } else {
        info.AddBindings(binding);
        module = it->module;
        perm_idx = std::distance(program->modules.begin(), it);
        perm_hash = HashCombine(params.hash, perm_idx);
    }
    return std::make_tuple(&program->info, module,
                           program->modules[perm_idx].spec.fetch_shader_data, perm_hash);
}

std::optional<vk::ShaderModule> PipelineCache::ReplaceShader(vk::ShaderModule module,
                                                             std::span<const u32> spv_code) {
    std::optional<vk::ShaderModule> new_module{};
    for (const auto& [_, program] : program_cache) {
        for (auto& m : program->modules) {
            if (m.module == module) {
                const auto& d = instance.GetDevice();
                d.destroyShaderModule(m.module);
                m.module = CompileSPV(spv_code, d);
                new_module = m.module;
            }
        }
    }
    if (module_related_pipelines.contains(module)) {
        auto& pipeline_keys = module_related_pipelines[module];
        for (auto& key : pipeline_keys) {
            if (std::holds_alternative<GraphicsPipelineKey>(key)) {
                auto& graphics_key = std::get<GraphicsPipelineKey>(key);
                graphics_pipelines.erase(graphics_key);
            } else if (std::holds_alternative<ComputePipelineKey>(key)) {
                auto& compute_key = std::get<ComputePipelineKey>(key);
                compute_pipelines.erase(compute_key);
            }
        }
    }
    return new_module;
}

std::string PipelineCache::GetShaderName(Shader::Stage stage, u64 hash,
                                         std::optional<size_t> perm) {
    if (perm) {
        return fmt::format("{}_{:#018x}_{}", stage, hash, *perm);
    }
    return fmt::format("{}_{:#018x}", stage, hash);
}

void PipelineCache::DumpShader(std::span<const u32> code, u64 hash, Shader::Stage stage,
                               size_t perm_idx, std::string_view ext) {
    if (!EmulatorSettings.IsDumpShaders()) {
        return;
    }

    using namespace Common::FS;
    const auto dump_dir = GetUserPath(PathType::ShaderDir) / "dumps";
    if (!std::filesystem::exists(dump_dir)) {
        std::filesystem::create_directories(dump_dir);
    }
    const auto filename = fmt::format("{}.{}", GetShaderName(stage, hash, perm_idx), ext);
    const auto file = IOFile{dump_dir / filename, FileAccessMode::Create};
    file.WriteSpan(code);
}

std::optional<std::vector<u32>> PipelineCache::GetShaderPatch(u64 hash, Shader::Stage stage,
                                                              size_t perm_idx,
                                                              std::string_view ext) {

    using namespace Common::FS;
    const auto patch_dir = GetUserPath(PathType::ShaderDir) / "patch";
    if (!std::filesystem::exists(patch_dir)) {
        std::filesystem::create_directories(patch_dir);
    }
    const auto filename = fmt::format("{}.{}", GetShaderName(stage, hash, perm_idx), ext);
    const auto filepath = patch_dir / filename;
    if (!std::filesystem::exists(filepath)) {
        return {};
    }
    const auto file = IOFile{patch_dir / filename, FileAccessMode::Read};
    std::vector<u32> code(file.GetSize() / sizeof(u32));
    file.Read(code);
    return code;
}
} // namespace Vulkan
