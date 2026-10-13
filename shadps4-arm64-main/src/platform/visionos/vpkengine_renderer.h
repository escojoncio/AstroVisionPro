// VPKEngine: the only renderer on visionOS. Liverpool's draws, dispatches, DMA and memory events
// go to VpkengineRasterizer (VideoCore::RasterizerInterface), which turns them into VPKEngine work
// (vpps4::Renderer: lifted GCN shaders, Metal pipelines, guest memory used in place) on VPKEngine's
// own Metal backend. Present:: draws the headset's frames: the eyes' colour targets side by side,
// in the compositor's Metal textures (core/vr/openxr_host_visionos.mm); vpkengine_presenter.h hands
// them to videoout/driver.cpp.
// There is no Vulkan device: KosmicKrisp and MoltenVK are not used.
//
// Log lines: "VPKENGINE_GPU ..." (draws run / skipped and why, encoders, GPU ms per frame),
// "VPKENGINE_PRESENT ..." (headset frames).
#pragma once

#include <array>
#include <cstdint>
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
    explicit Rasterizer(AmdGpu::Liverpool* liverpool);
    ~Rasterizer() override;

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
    bool IsMapped(VAddr addr, u64 size) override;
    void MapMemory(VAddr addr, u64 size) override;
    void UnmapMemory(VAddr addr, u64 size) override;

    void CpSync() override {}
    u64 Flush() override;
    void Finish() override;
    void OnSubmit() override {}

    struct Impl;

private:
    void Dispatch(VAddr indirect);
    VAddr pendingIndirect = 0;  // set while DrawIndirect runs Draw for one set of arguments
    std::unique_ptr<Impl> impl;
};

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
} // namespace Present

} // namespace VpkengineRenderer
