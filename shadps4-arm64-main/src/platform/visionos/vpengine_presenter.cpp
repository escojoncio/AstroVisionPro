// See vpengine_presenter.h.
#include "vpengine_presenter.h"

#include <chrono>
#include <thread>

#include "vpengine_renderer.h"

namespace VpengineRenderer {

Presenter::Presenter() {
    for (u32 k = 0; k < NumSlots; ++k) {
        tokens[k].host_buffer = static_cast<s8>(k);
    }
}

bool Presenter::HasLocalHeadset() const {
    return Present::HasHeadset();
}

Vulkan::HmdFrames Presenter::Token(int slot, u32 width, u32 height) {
    if (slot < 0) {
        // The driver tries again at once: a little time for the compositor to free a frame.
        std::this_thread::sleep_for(std::chrono::milliseconds{2});
        return {};
    }
    Vulkan::Frame& frame = tokens[static_cast<u32>(slot) % NumSlots];
    frame.width = width * 2;
    frame.height = height;
    return {.shown = nullptr, .exported = &frame};
}

Vulkan::HmdFrames Presenter::PrepareHmdFrame(std::span<const AmdGpu::Image, 2> eye_textures,
                                             const Core::Vr::Fov& fov, u32, u32& eye_width,
                                             u32& eye_height) {
    const int slot = Present::ComposeEyes(eye_textures, fov, eye_width, eye_height);
    return Token(slot, eye_width, eye_height);
}

Vulkan::HmdFrames Presenter::PrepareScreenAsHmdFrame(
    const Libraries::VideoOut::BufferAttributeGroup& attribute, VAddr cpu_address,
    Core::Vr::Fov& fov, u32& eye_width, u32& eye_height) {
    const int slot = Present::ComposeScreen(attribute, cpu_address, fov, eye_width, eye_height);
    return Token(slot, eye_width, eye_height);
}

Vulkan::HmdFrames Presenter::PrepareTextureAsScreenHmdFrame(const AmdGpu::Image& texture,
                                                            Core::Vr::Fov& fov, u32& eye_width,
                                                            u32& eye_height) {
    const int slot = Present::ComposeTexture(texture, fov, eye_width, eye_height);
    return Token(slot, eye_width, eye_height);
}

bool Presenter::DeliverHmdFrame(Vulkan::Frame* frame, const Core::Vr::PresentedFrame& info) {
    if (frame == nullptr || frame->host_buffer < 0) {
        return false;
    }
    Present::Deliver(frame->host_buffer, info);
    return true;
}

bool Presenter::IsFrameFinished(const Vulkan::Frame* frame) const {
    return frame == nullptr || frame->host_buffer < 0 || Present::Finished(frame->host_buffer);
}

} // namespace VpengineRenderer
