// VPKEngine: the only renderer on visionOS. Liverpool's draws, dispatches, DMA and memory events
// go to VpkengineRasterizer (VideoCore::RasterizerInterface), which turns them into VPKEngine work
// (vpps4::Renderer: lifted GCN shaders, Metal pipelines, guest memory used in place) on VPKEngine's
// own Metal backend. Present:: draws the headset's frames: the eyes' colour targets side by side,
// in the compositor's Metal textures (core/vr/openxr_host_visionos.mm); vpkengine_presenter.h hands
// them to videoout/driver.cpp.
// There is no Vulkan device: KosmicKrisp and MoltenVK are not used.
// Rasterizer::Mode::Shadow (ASTRO_RENDERER=shadow, behind video_core/tee_rasterizer.h): the same renderer
// built on VPKEngine's null backend, beside the Vulkan one that draws and presents. It has no GPU and
// no Metal device, and never writes guest memory (no DMA, write back, label, occlusion result or
// WRITE_DATA), never protects host pages (the page manager is the Vulkan renderer's alone: a second
// one would take over its fault handler) and never mirrors guest memory.
//
// Log lines: "VPKENGINE_GPU ..." (draws run / skipped and why, encoders, GPU ms per frame),
// "VPKENGINE_PRESENT ..." (headset frames).
#pragma once

#include <array>
#include <cstdint>
#include <functional>
#include <memory>
#include <span>
#include <string_view>

#include "common/types.h"
#include "core/vr/vr_runtime.h"
#include "video_core/rasterizer_interface.h"

namespace AmdGpu {
struct Liverpool;
struct Image;
}
namespace Libraries::VideoOut {
struct BufferAttributeGroup;
}
namespace VideoCore {
class PageManager;
}

namespace VpkengineRenderer {

class Rasterizer final : public VideoCore::RasterizerInterface {
public:
    enum class Mode { Primary, Shadow };
    /// Primary binds itself to `liverpool`; the shadow does not (the Tee does, to both).
    explicit Rasterizer(AmdGpu::Liverpool* liverpool, Mode mode = Mode::Primary);
    ~Rasterizer() override;

    /// The engine could not start (no Metal device): nothing is drawn. The Tee switches a failed shadow off.
    bool Failed() const;

    void Draw(bool is_indexed, u32 index_offset = 0) override;
    void DrawIndirect(bool is_indexed, VAddr arg_address, u32 offset, u32 size, u32 max_count,
                      VAddr count_address) override;
    void DispatchDirect() override;
    void DispatchIndirect(VAddr address, u32 offset, u32 size) override;

    void ScopeMarkerBegin(const std::string_view&, bool = false) override {}
    void ScopeMarkerEnd(bool = false) override {}
    void ScopedMarkerInsert(const std::string_view&, bool = false) override {}
    void ScopedMarkerInsertColor(const std::string_view&, const u32, bool = false) override {}

    void FillBuffer(VAddr address, u32 num_bytes, u32 value, bool is_gds) override;
    void CopyBuffer(VAddr dst, VAddr src, u32 num_bytes, bool dst_gds, bool src_gds) override;
    u32 ReadDataFromGds(u32 gds_offset) override;
    bool InvalidateMemory(VAddr addr, u64 size) override;
    bool ReadMemory(VAddr addr, u64 size) override;
    bool InvalidateHostPage(VAddr page, u64 size, bool write) override;
    bool IsMapped(VAddr addr, u64 size) override;
    void MapMemory(VAddr addr, u64 size) override;
    void UnmapMemory(VAddr addr, u64 size) override;

    bool ZPassDone(VAddr address, u32 pairs) override;
    bool SyncGpuWrites(VAddr addr, u64 size, bool wait) override;
    void OnCoherencePoint(VAddr base, u64 size, u32 coher_cntl) override;

    void CpSync() override {}
    u64 Flush() override;
    void Finish() override;
    void SyncGds() override;
    void ScheduleLabelWrite(void* address, u64 value, u32 size, std::function<void()> then) override;
    bool PrepareLabelWait(const void* address, u32 size, u32 function, u32 ref, u32 mask) override;
    bool IdleLabelWait(const void* address, u32 size) override;
    void WriteDataOrdered(void* address, const void* data, u32 size) override;
    void OnSubmit() override {}

    struct Impl;

private:
    void Dispatch(VAddr indirect);
    VAddr pendingCount = 0;  // the count buffer of the multi-draw being run (0 = none)
    u32 pendingIndex = 0;    // which draw of it
    VAddr pendingIndirect = 0;  // set while DrawIndirect runs Draw for one set of arguments
    std::unique_ptr<Impl> impl;
};

/// Shadow only: the picture was flipped (videoout Flip, headset frames included). The frame the shadow has
/// recorded goes to its null backend at its next Flush; this only sets a flag, it takes no lock.
void ShadowEndFrame();

/// «Modo diagnóstico» (L3+R3, astro_core.mm): starts the GPU test of video_core/renderer_vulkan/gpu_bench.h on this renderer
/// (what each pixel shader of the scene costs, by leaving its draws out). Not for the shadow: Vulkan's test is the one then.
void StartGpuBench();

/// «Modo diagnóstico» (L1 and R1 held, L3 pressed, astro_core.mm): captures the next whole picture of the title, to be asked
/// for with what is wrong on screen: a SCENEDRAW line for every draw on the scene's depth targets and pictures at full
/// resolution of what each view drew (vpps4::Renderer::beginSceneCapture; lines VPKENGINE_PROBE SCENECAP / SCENEDRAW /
/// FRAMECAP n=u<capture>.<frame>, files framecap-u<capture>.<frame>-*.ppm next to the logs). As many times as wanted.
/// The six pictures before it leave what was asked of the renderer in callcap-u<capture>.vp4, next to the logs too
/// (vpps4::Renderer::beginCallCapture; lines VPKENGINE_PROBE CALLCAP begin / end).
void RequestSceneCapture();

// The headset's frames (used by vpkengine_presenter.cpp, which hands them to videoout/driver.cpp):
// what is drawn goes into one of the compositor's Metal textures; a slot index stands for it,
// -1 when the host has none free (or nothing can be drawn).
namespace Present {
bool HasHeadset();
int ComposeEyes(std::span<const AmdGpu::Image, 2> eye_textures, const Core::Vr::Fov& fov, u32& eye_width,
                u32& eye_height);
int ComposeScreen(const Libraries::VideoOut::BufferAttributeGroup& attribute, VAddr cpu_address,
                  Core::Vr::Fov& fov, u32& eye_width, u32& eye_height);
int ComposeTexture(const AmdGpu::Image& texture, Core::Vr::Fov& fov, u32& eye_width, u32& eye_height);
/// Hands the frame of `slot` to the compositor once the GPU has drawn it (blocks until then).
void Deliver(int slot, const Core::Vr::PresentedFrame& info);
bool Finished(int slot);
/// Whether a frame handed to the GPU has not finished on it yet (takes no lock: looked at many times a refresh).
bool GpuBusy();
/// How long the GPU has worked on the engine's command buffers so far, in ns (the union of their intervals: the engine's
/// "GPU busy_union" timer, always on; takes no lock). 0 until one finished.
u64 GpuTimeNs();
} // namespace Present

} // namespace VpkengineRenderer
