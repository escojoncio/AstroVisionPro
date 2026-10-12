// The headset host's Metal frames (core/vr/openxr_host.h), for vpengine_renderer.mm: that header
// brings in vulkan.hpp, which does not compile under ARC (Objective-C pointers in its structs).
#pragma once

#include "common/types.h"
#include "core/vr/vr_runtime.h"

namespace VpengineXr {
bool Available();
void Start(void* mtl_device);
/// Slot index and its id<MTLTexture> (owned by the host); false if none is free.
bool Begin(u32 width, u32 height, u32& index, void*& texture);
void End(u32 index, const Core::Vr::PresentedFrame& info);
void Drop(u32 index);
} // namespace VpengineXr
