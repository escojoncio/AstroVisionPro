// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

// The frames a presenter hands videoout/driver.cpp, apart from the presenter itself (the
// VPKEngine presenter on visionOS uses them as tokens, with no Vulkan device behind them).
#pragma once

#include <imgui.h>

#include "common/types.h"
#include "video_core/renderer_vulkan/vk_common.h"

typedef struct VmaAllocation_T* VmaAllocation;

namespace Vulkan {

class MasterSemaphore;

struct Frame {
    u32 width;
    u32 height;
    VmaAllocation allocation;
    vk::Image image;
    vk::ImageView image_view;
    vk::Fence present_done;
    /// The timeline the frame's commands were submitted on, and its tick once they have run.
    MasterSemaphore* ready_timeline{};
    vk::Semaphore ready_semaphore;
    u64 ready_tick;
    bool is_hdr{false};
    u8 id{};
    /// The VR host buffer this frame lives in, or -1 for a frame that is shown on the window.
    s8 host_buffer{-1};

    ImTextureID imgui_texture;
};

/// What a frame of the emulated headset is drawn into: the frame that goes on the window (or to
/// the application that owns the headset, on a machine where that is another process), and,
/// where the machine has a headset of its own, the frame that goes there.
struct HmdFrames {
    Frame* shown{};
    Frame* exported{};

    explicit operator bool() const {
        return shown != nullptr || exported != nullptr;
    }
};

} // namespace Vulkan
