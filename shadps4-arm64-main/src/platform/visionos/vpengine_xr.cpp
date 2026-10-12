#include "vpengine_xr.h"

#include "core/vr/openxr_host.h"

namespace VpengineXr {
bool Available() {
    return Core::Vr::OpenXrHost::Instance().IsAvailable();
}
void Start(void* mtl_device) {
    Core::Vr::OpenXrHost::Instance().StartMetal(mtl_device);
}
bool Begin(u32 width, u32 height, u32& index, void*& texture) {
    const auto t = Core::Vr::OpenXrHost::Instance().BeginMetalFrame(width, height);
    if (!t) {
        return false;
    }
    index = t->index;
    texture = t->texture;
    return true;
}
void End(u32 index, const Core::Vr::PresentedFrame& info) {
    Core::Vr::OpenXrHost::Instance().EndFrame(index, info);
}
void Drop(u32 index) {
    Core::Vr::OpenXrHost::Instance().DropFrame(index);
}
} // namespace VpengineXr
