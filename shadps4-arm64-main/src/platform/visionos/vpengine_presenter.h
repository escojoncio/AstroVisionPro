// The presenter videoout/driver.cpp talks to on visionOS: the headset's frames drawn by VPEngine
// (vpengine_renderer.h, Present::). Frames are tokens of Vulkan::Frame (vk_frame.h) with the
// compositor's slot in host_buffer; there is no window and no Vulkan device behind them.
#pragma once

#include <array>
#include <span>

#include "common/types.h"
#include "core/vr/vr_runtime.h"
#include "video_core/renderer_vulkan/vk_frame.h"

#include "video_core/amdgpu/resource.h"
namespace Libraries::VideoOut {
struct BufferAttributeGroup;
}

namespace VpengineRenderer {

class Presenter {
public:
    Presenter();

    void SetHDR(bool) {}
    bool IsHDRSupported() const {
        return false;
    }
    bool HasLocalHeadset() const;
    void RegisterVideoOutSurface(const Libraries::VideoOut::BufferAttributeGroup&, VAddr) {}

    Vulkan::HmdFrames PrepareHmdFrame(std::span<const AmdGpu::Image, 2> eye_textures,
                                      const Core::Vr::Fov& fov, u32 frame_id, u32& eye_width,
                                      u32& eye_height);
    Vulkan::HmdFrames PrepareScreenAsHmdFrame(
        const Libraries::VideoOut::BufferAttributeGroup& attribute, VAddr cpu_address,
        Core::Vr::Fov& fov, u32& eye_width, u32& eye_height);
    Vulkan::HmdFrames PrepareTextureAsScreenHmdFrame(const AmdGpu::Image& texture,
                                                     Core::Vr::Fov& fov, u32& eye_width,
                                                     u32& eye_height);
    bool DeliverHmdFrame(Vulkan::Frame* frame, const Core::Vr::PresentedFrame& info);
    bool IsFrameFinished(const Vulkan::Frame* frame) const;
    bool IsGpuBusy() const {
        return false;
    }

    // There is no window: these present nothing, but the flip completes (a frame that stands
    // for nothing; a null one would have the driver retry forever).
    Vulkan::Frame* PrepareFrame(const Libraries::VideoOut::BufferAttributeGroup&, VAddr) {
        return &no_window;
    }
    Vulkan::Frame* PrepareBlankFrame(bool) {
        return &no_window;
    }
    Vulkan::Frame* PrepareLastFrame() {
        return nullptr;
    }
    void Present(Vulkan::Frame*, bool = false) {}

private:
    Vulkan::HmdFrames Token(int slot, u32 width, u32 height);
    static constexpr u32 NumSlots = 6;
    std::array<Vulkan::Frame, NumSlots> tokens{};
    Vulkan::Frame no_window{};
};

} // namespace VpengineRenderer
