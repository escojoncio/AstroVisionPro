// VPEngine renderer, shadow mode: see vpengine_renderer.h.
#include "vpengine_renderer.h"

#include <mach/mach.h>

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <span>
#include <string>
#include <vector>

#include "common/logging/log.h"
#include "shader_recompiler/frontend/fetch_shader.h"
#include "shader_recompiler/info.h"
#include "video_core/amdgpu/regs.h"
#include "vpgpu/core/device.h"
#include "vpgpu/metal/metal_backend.h"
#include "vpps4/renderer.h"

namespace VpengineRenderer {
namespace {

// Guest addresses are host addresses. Buffers alias guest memory through windows of this size
// (aligned), cut down to the mapped part around the address: one huge mapping as a single
// no-copy MTLBuffer can exceed the device's maximum buffer length.
constexpr u64 kWindow = 64ull << 20;

// The mapped span of [from, to) that contains `address`, walking the VM entries (guest memory is
// many entries with different protections); false if `address` is not mapped.
bool mappedSpan(u64 address, u64 from, u64 to, u64& begin, u64& end) {
    begin = end = address;
    vm_address_t at = vm_address_t(from);
    bool found = false;
    while (at < to) {
        vm_address_t base = at;
        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info{};
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        if (vm_region_64(mach_task_self(), &base, &size, VM_REGION_BASIC_INFO_64,
                         reinterpret_cast<vm_region_info_t>(&info), &count, &object) != KERN_SUCCESS)
            break;
        // (reserved, never-readable address space is not memory to alias; pages shadPS4 merely
        // protects to watch them are readable at most and stay in)
        const bool usable = (info.max_protection & VM_PROT_READ) != 0;
        if (!usable) {
            if (found) break;
            if (base + size > address && base <= address) return false;
            at = base + size;
            continue;
        }
        if (base > at) {  // a hole before the next entry
            if (found) break;
            if (base > address) return false;
        }
        const u64 lo = std::max<u64>(base, from), hi = std::min<u64>(base + size, to);
        if (!found) {
            if (address >= lo && address < hi) {
                found = true;
                begin = lo;
                end = hi;
            }
        } else if (lo == end) {
            end = hi;
        } else {
            break;
        }
        at = base + size;
    }
    if (!found) return false;
    // Extend backwards: entries before `address` inside the window, contiguous with `begin`.
    for (u64 probe = begin; probe > from;) {
        vm_address_t base = vm_address_t(probe - 1);
        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info{};
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        if (vm_region_64(mach_task_self(), &base, &size, VM_REGION_BASIC_INFO_64,
                         reinterpret_cast<vm_region_info_t>(&info), &count, &object) != KERN_SUCCESS ||
            base > probe - 1 || base + size < probe || !(info.max_protection & VM_PROT_READ))
            break;
        begin = std::max<u64>(base, from);
        probe = begin;
    }
    return true;
}

// MSL from the shader translator, as the Metal backend takes it (msl.h argument contract).
vpgpu::metal::MslShader toMetal(const vpmsl::MslShader& s) {
    vpgpu::metal::MslShader m;
    m.source = s.source;
    m.entry = "vp_main";
    m.argumentBufferIndex = 0;
    m.threadsPerGroup = s.workgroupSize;
    m.colorOutputs = s.colorOutputs;
    for (const vpmsl::Argument& a : s.arguments)
        m.arguments.push_back({vpgpu::BindKind(uint8_t(a.kind) + 1), uint16_t(a.index), a.offset});
    return m;
}

struct Engine {
    std::mutex lock;
    vpgpu::metal::ShaderTable shaders;
    std::unique_ptr<vpgpu::metal::MetalBackend> backend;
    std::unique_ptr<vpgpu::Device> device;
    std::unique_ptr<vpps4::Renderer> renderer;
    std::atomic<u64> frames{0};
    std::atomic<unsigned> errorLines{0};
    // Invalidations come from the page-fault handler: queued without the engine lock (it may be
    // held for long, or by the faulting thread itself) and applied before the next draw.
    std::atomic_flag pendingLock = ATOMIC_FLAG_INIT;
    std::vector<std::pair<u64, u64>> pending;
    void applyPending() {
        while (pendingLock.test_and_set(std::memory_order_acquire)) {}
        std::vector<std::pair<u64, u64>> work;
        work.swap(pending);
        pendingLock.clear(std::memory_order_release);
        if (renderer)
            for (auto [a, n] : work) renderer->invalidate(a, n);
    }
    bool failed = false;

    // Per-frame lines of the core ("gpu.frame/cut/pso/enc", GPU times) only every kEvery frames;
    // errors always (up to 200 lines).
    static constexpr u64 kEvery = 120;
    void log(const std::string& line) {
        const bool error = line.rfind("gpu.err", 0) == 0 || line.rfind("vpps4.shader error", 0) == 0;
        if (error) {
            if (errorLines++ < 200) LOG_WARNING(Render_Vulkan, "VPENGINE_GPU {}", line);
            return;
        }
        const u64 f = frames.load();
        if (line.rfind("gpu.", 0) == 0 && line.rfind("gpu.metal", 0) != 0 && f != 0 && f % kEvery != 1) return;
        LOG_INFO(Render_Vulkan, "VPENGINE_GPU {}", line);
    }

    bool start() {
        if (renderer || failed) return renderer != nullptr;
        backend = std::make_unique<vpgpu::metal::MetalBackend>(shaders, [this](const std::string& l) { log(l); });
        if (!backend->ok()) {
            failed = true;
            LOG_ERROR(Render_Vulkan, "VPENGINE_GPU no Metal device: shadow renderer off");
            return false;
        }
        device = std::make_unique<vpgpu::Device>(*backend, 2, [this](const std::string& l) { log(l); });
        vpps4::Hooks hooks;
        hooks.region = [](uint64_t address, uint64_t size, vpps4::GuestRegion& out) {
            if (address < 0x10000) return false;
            const u64 from = address & ~(kWindow - 1);
            const u64 to = std::max(from + kWindow, (address + size + kWindow - 1) & ~(kWindow - 1));
            u64 begin, end;
            if (!mappedSpan(address, from, to, begin, end) || address + size > end) return false;
            out = {begin, end - begin, reinterpret_cast<void*>(begin)};
            return true;
        };
        hooks.shader = [this](uint64_t id, vpir::Stage, const vpmsl::MslShader& s) { shaders.add(id, toMetal(s)); };
        hooks.log = [this](const std::string& l) { log(l); };
        renderer = std::make_unique<vpps4::Renderer>(*device, std::move(hooks));
        renderer->setSummaryEvery(kEvery);
        LOG_INFO(Render_Vulkan, "VPENGINE_GPU shadow renderer on (VPEngine runs every draw in Metal; the picture is still Vulkan's)");
        return true;
    }
};

Engine& engine() {
    static Engine e;
    return e;
}

// The program of a stage as the renderer wants it: code (whole binary), user data, address.
void fillStage(vpps4::Stage& st, const AmdGpu::ShaderProgram& program) {
    const auto params = AmdGpu::GetParams(program);
    st.code = params.code;
    st.address = reinterpret_cast<uint64_t>(params.code.data());
    std::copy_n(program.user_data.begin(), 16, st.userData.begin());
    st.userSgprs = uint8_t(program.settings.num_user_regs);
}

} // namespace

bool Enabled() {
    static const bool on = [] {
        const char* v = std::getenv("SHADPS4_VPENGINE_RENDERER");
        return v != nullptr && v[0] == '1';
    }();
    return on;
}

void Draw(const AmdGpu::Regs& regs, const Shader::Info& vs, const Shader::Info* ps, bool indexed, u32 index_offset) {
    Engine& e = engine();
    std::lock_guard g(e.lock);
    if (!e.start()) return;
    e.applyPending();
    vpps4::DrawState d;
    if (vs.stage != Shader::Stage::Vertex) {
        // (tessellation / geometry pipelines: the vertex stage is an ES or LS program)
        static std::atomic<bool> told{false};
        if (!told.exchange(true)) LOG_INFO(Render_Vulkan, "VPENGINE_GPU first draw with ES/LS stages: such draws are left out");
        return;
    }

    // Targets.
    for (unsigned i = 0; i < 8; ++i) {
        const auto& cb = regs.color_buffers[i];
        if (!cb) continue;
        vpps4::ColorTarget& c = d.color[i];
        c.address = cb.Address();
        c.width = cb.Pitch();
        c.height = cb.Height();
        c.pitch = cb.Pitch();
        c.format = uint8_t(cb.info.format);
        c.numberType = uint8_t(cb.info.number_type);
        c.compSwap = uint8_t(cb.info.comp_swap);
        c.tileMode = cb.info.linear_general ? 31 : uint8_t(cb.attrib.tile_mode_index);
        c.sliceStart = uint16_t(cb.BaseSlice());
        c.sliceCount = uint16_t(cb.NumSlices());
        c.samples = uint8_t(cb.NumSamples());
        c.writeMask = uint8_t(regs.color_target_mask.GetMask(i) & regs.color_shader_mask.GetMask(i));
        const auto& b = regs.blend_control[i];
        vpps4::Blend& bl = d.blend[i];
        bl.enable = b.enable;
        bl.separateAlpha = b.separate_alpha_blend;
        bl.colorSrc = uint8_t(b.color_src_factor);
        bl.colorDst = uint8_t(b.color_dst_factor);
        bl.colorFunc = uint8_t(b.color_func);
        bl.alphaSrc = uint8_t(b.alpha_src_factor);
        bl.alphaDst = uint8_t(b.alpha_dst_factor);
        bl.alphaFunc = uint8_t(b.alpha_func);
    }
    d.blendColor = regs.blend_constants;
    const auto& db = regs.depth_buffer;
    if (db.DepthValid() || db.StencilValid()) {
        d.depth.zAddress = db.DepthAddress();
        d.depth.stencilAddress = db.StencilAddress();
        d.depth.width = db.Pitch();
        d.depth.height = db.Height();
        d.depth.zFormat = db.DepthValid() ? uint8_t(db.z_info.format) : 0;
        d.depth.stencilFormat = db.StencilValid() ? uint8_t(db.stencil_info.format) : 0;
        d.depth.tileMode = uint8_t(db.z_info.tile_mode_index);
        d.depth.sliceStart = uint16_t(regs.depth_view.slice_start);
        d.depth.sliceCount = uint16_t(regs.depth_view.NumSlices());
        d.depth.samples = uint8_t(db.NumSamples());
        d.depth.depthClear = regs.depth_render_control.depth_clear_enable;
        d.depth.stencilClear = regs.depth_render_control.stencil_clear_enable;
        d.depth.clearDepth = regs.depth_clear;
        d.depth.clearStencil = uint8_t(regs.stencil_clear);
    }
    const auto& dc = regs.depth_control;
    d.depthStencil.depthTest = dc.depth_enable;
    d.depthStencil.depthWrite = dc.depth_enable && dc.depth_write_enable;
    d.depthStencil.depthFunc = uint8_t(dc.depth_func);
    d.depthStencil.stencilTest = dc.stencil_enable;
    d.depthStencil.backfaceEnable = dc.backface_enable;
    const auto& sc = regs.stencil_control;
    d.depthStencil.front = {uint8_t(dc.stencil_ref_func), uint8_t(sc.stencil_fail_front), uint8_t(sc.stencil_zpass_front),
                            uint8_t(sc.stencil_zfail_front), regs.stencil_ref_front.stencil_test_val,
                            regs.stencil_ref_front.stencil_mask, regs.stencil_ref_front.stencil_write_mask};
    d.depthStencil.back = {uint8_t(dc.stencil_bf_func), uint8_t(sc.stencil_fail_back), uint8_t(sc.stencil_zpass_back),
                           uint8_t(sc.stencil_zfail_back), regs.stencil_ref_back.stencil_test_val,
                           regs.stencil_ref_back.stencil_mask, regs.stencil_ref_back.stencil_write_mask};

    // Rasterizer state.
    const auto& vp = regs.viewports[0];
    d.viewport = {vp.xscale, vp.xoffset, vp.yscale, vp.yoffset, vp.zscale, vp.zoffset};
    const auto& ss = regs.screen_scissor;
    d.scissor = {ss.top_left_x, ss.top_left_y, ss.bottom_right_x, ss.bottom_right_y};
    d.raster.cullFront = regs.polygon_control.cull_front;
    d.raster.cullBack = regs.polygon_control.cull_back;
    d.raster.frontFaceClockwise = regs.polygon_control.front_face == AmdGpu::FrontFace::Clockwise;
    d.primitive = vpps4::PrimitiveType(uint8_t(regs.primitive_type));

    // Geometry.
    d.count = regs.num_indices;
    d.instances = regs.num_instances.NumInstances();
    const bool index32 = regs.index_buffer_type.index_type == AmdGpu::IndexType::Index32;
    if (indexed) {
        d.indexAddress = regs.index_base_address.Address<VAddr>() + u64(index_offset) * (index32 ? 4 : 2);
        d.index32 = index32;
    }
    d.firstVertex = regs.index_offset;

    // Stages.
    fillStage(d.vs, regs.vs_program);
    d.vs.vgprCompCnt = uint8_t(regs.vs_program.settings.vgpr_comp_cnt);
    d.vs.instanceStepRate = {regs.vgt_instance_step_rate_0, regs.vgt_instance_step_rate_1};
    if (vs.has_fetch_shader) {
        if (const auto data = Shader::Gcn::ParseFetchShader(vs)) {
            const u32* p = Shader::Gcn::GetFetchShaderCode(vs, vs.fetch_shader_sgpr_base);
            d.vs.fetch = std::span<const uint32_t>(p, data->size / 4);
            // (instance offsets of the fetch shader are not passed yet: DrawState has no first instance)
            if (regs.index_offset == 0 && data->vertex_offset_sgpr >= 0 && data->vertex_offset_sgpr < 16)
                d.firstVertex = regs.vs_program.user_data[data->vertex_offset_sgpr];
        }
    }
    if (ps != nullptr) {
        fillStage(d.ps, regs.ps_program);
        u32 addr = 0;
        std::memcpy(&addr, &regs.ps_input_addr, sizeof(addr));
        d.ps.psInputAddr = addr & 0xffff;
        for (unsigned k = 0; k < 8; ++k) d.ps.exportFormat[k] = uint8_t(regs.color_export_format.GetFormat(k));
        d.ps.psNumInterp = uint8_t(regs.num_interp);
        for (unsigned k = 0; k < 32; ++k) std::memcpy(&d.ps.psInputCntl[k], &regs.ps_inputs[k], sizeof(u32));
    }
    e.renderer->draw(d);
}

void Dispatch(const AmdGpu::ComputeProgram& cs, const Shader::Info&) {
    if (cs.address == 0) return;
    Engine& e = engine();
    std::lock_guard g(e.lock);
    if (!e.start()) return;
    e.applyPending();
    vpps4::DispatchState d;
    const auto params = AmdGpu::GetParams(cs);
    d.cs.code = params.code;
    d.cs.address = reinterpret_cast<uint64_t>(params.code.data());
    std::copy_n(cs.user_data.begin(), 16, d.cs.userData.begin());
    u64 settings = 0;
    std::memcpy(&settings, &cs.settings, sizeof(settings));
    // COMPUTE_PGM_RSRC1 is the low word, RSRC2 the high one.
    const u32 rsrc2 = u32(settings >> 32);
    d.cs.userSgprs = uint8_t((rsrc2 >> 1) & 0x1f);
    for (unsigned k = 0; k < 3; ++k) d.cs.tgidEnable[k] = (rsrc2 >> (7 + k)) & 1;
    d.cs.tgSizeEnable = (rsrc2 >> 10) & 1;
    d.cs.tidigCompCnt = uint8_t((rsrc2 >> 11) & 3);
    d.cs.ldsBytes = cs.SharedMemSize();
    d.cs.workgroupSize = {cs.num_thread_x.full, cs.num_thread_y.full, cs.num_thread_z.full};
    d.groups = {cs.dim_x, cs.dim_y, cs.dim_z};
    e.renderer->dispatch(d);
}

void Invalidate(VAddr address, u64 size) {
    // Pages: shadPS4 unprotects the whole page, so later writes to it do not fault again.
    constexpr u64 kPage = 0x4000;
    const u64 a = address & ~(kPage - 1), b = (address + size + kPage - 1) & ~(kPage - 1);
    Engine& e = engine();
    while (e.pendingLock.test_and_set(std::memory_order_acquire)) {}
    if (e.pending.size() < 65536) e.pending.push_back({a, b - a});
    e.pendingLock.clear(std::memory_order_release);
}

void EndFrame() {
    Engine& e = engine();
    std::lock_guard g(e.lock);
    if (!e.renderer) return;
    ++e.frames;
    e.renderer->submit();
}

} // namespace VpengineRenderer
