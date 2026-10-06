// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

// The headset of an Apple Vision Pro, as far as the emulator is concerned.
//
// This is what core/vr/openxr_host.cpp is on a PC, with the work divided differently: visionOS
// has no OpenXR, and what shows pictures in the headset (Compositor Services), tracks the head
// and the hands (ARKit) and reads the controller (GameController) is in the Swift app around the
// emulator (visionos/App). That app pulls the finished frames from here through
// platform/visionos/astro_core.h and draws them for the headset, turned to where the head points
// by the time they are shown - which is what an OpenXR runtime's compositor does with the
// projection layer openxr_host.cpp hands it.
//
// The frames are images of the emulator's Vulkan device (MoltenVK) that are Metal textures as
// well (VK_EXT_metal_objects): the app samples them without any copy.

#ifndef VK_USE_PLATFORM_METAL_EXT
#define VK_USE_PLATFORM_METAL_EXT
#endif

#import <Metal/Metal.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <mutex>

#include "common/logging/log.h"
#include "core/vr/openxr_host.h"
#include "core/vr/vr_runtime.h"
#include "platform/visionos/astro_core.h"

namespace Core::Vr {

namespace {

using Clock = std::chrono::steady_clock;

/// One being drawn, one waiting to be shown, one being shown, and one to spare (as on the PC).
constexpr u32 NumSlots = 4;

float EnvFloat(const char* name, float fallback) {
    const char* value = std::getenv(name);
    return value != nullptr && *value != '\0' ? static_cast<float>(std::atof(value)) : fallback;
}

bool EnvFlag(const char* name, bool fallback) {
    const char* value = std::getenv(name);
    return value != nullptr && *value != '\0' ? value[0] != '0' : fallback;
}

} // namespace

struct OpenXrHost::Impl {
    struct Slot {
        enum class State { Free, Drawing, Ready, Reading };

        vk::Image image;
        vk::DeviceMemory memory;
        vk::ImageView view;
        id<MTLTexture> texture{nil};
        u32 width{};
        u32 height{};
        State state{State::Free};
        PresentedFrame info;
    };

    struct Retired {
        vk::Image image;
        vk::DeviceMemory memory;
        vk::ImageView view;
        Clock::time_point since;
    };

    // Settings.
    bool enabled{true};
    bool pause_when_away{true};

    bool available{};
    Graphics graphics{};
    bool started{};

    std::mutex slot_mutex;
    std::array<Slot, NumSlots> slots;
    s32 latest{-1};
    u32 next_slot{};
    std::vector<Retired> retired;
    std::atomic<bool> accepting{};
    std::atomic<bool> showing{};
    std::atomic<u32> delivered_frames{};
    Clock::time_point last_delivery;
    double longest_gap{};
    u32 long_gaps{};
    bool reported_worn{true};
    float ipd{0.063f};

    void UpdateWorn() {
        const bool worn = !pause_when_away || (accepting.load() && showing.load());
        if (worn != reported_worn) {
            reported_worn = worn;
            LOG_INFO(Core_Vr, "The headset is {}",
                     worn ? "on the head and shows the game"
                          : "off the head, or shows something else: the game waits");
            Runtime::Instance().SetHeadsetWorn(worn);
        }
    }

    void Retire(Slot& slot) {
        if (slot.image) {
            retired.push_back({slot.image, slot.memory, slot.view, Clock::now()});
        }
        slot.image = nullptr;
        slot.memory = nullptr;
        slot.view = nullptr;
        slot.texture = nil;
        slot.width = 0;
        slot.height = 0;
    }

    void DestroyRetired() {
        // Whatever still used an image that was replaced has long finished by then.
        const auto now = Clock::now();
        std::erase_if(retired, [&](const Retired& old) {
            if (now - old.since < std::chrono::seconds{3}) {
                return false;
            }
            graphics.device.destroyImageView(old.view);
            graphics.device.destroyImage(old.image);
            graphics.device.freeMemory(old.memory);
            return true;
        });
    }

    bool Create(Slot& slot, u32 width, u32 height) {
        const vk::Device device = graphics.device;
        Retire(slot);
        // The image has to be a Metal texture the app can be handed.
        const vk::ExportMetalObjectCreateInfoEXT export_info{
            .exportObjectType = vk::ExportMetalObjectTypeFlagBitsEXT::eMetalTexture,
        };
        const auto [image_result, image] = device.createImage(vk::ImageCreateInfo{
            .pNext = &export_info,
            .imageType = vk::ImageType::e2D,
            .format = FrameFormat,
            .extent = {width, height, 1},
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = vk::SampleCountFlagBits::e1,
            .usage = vk::ImageUsageFlagBits::eColorAttachment |
                     vk::ImageUsageFlagBits::eTransferSrc | vk::ImageUsageFlagBits::eSampled,
        });
        if (image_result != vk::Result::eSuccess) {
            return false;
        }
        const auto requirements = device.getImageMemoryRequirements(image);
        const auto memory_properties = graphics.physical_device.getMemoryProperties();
        u32 memory_type = memory_properties.memoryTypeCount;
        for (u32 type = 0; type < memory_properties.memoryTypeCount; ++type) {
            if ((requirements.memoryTypeBits & (1u << type)) != 0 &&
                (memory_properties.memoryTypes[type].propertyFlags &
                 vk::MemoryPropertyFlagBits::eDeviceLocal)) {
                memory_type = type;
                break;
            }
        }
        if (memory_type == memory_properties.memoryTypeCount) {
            device.destroyImage(image);
            return false;
        }
        const auto [memory_result, memory] = device.allocateMemory(vk::MemoryAllocateInfo{
            .allocationSize = requirements.size,
            .memoryTypeIndex = memory_type,
        });
        if (memory_result != vk::Result::eSuccess) {
            device.destroyImage(image);
            return false;
        }
        if (device.bindImageMemory(image, memory, 0) != vk::Result::eSuccess) {
            device.destroyImage(image);
            device.freeMemory(memory);
            return false;
        }
        const auto [view_result, view] = device.createImageView(vk::ImageViewCreateInfo{
            .image = image,
            .viewType = vk::ImageViewType::e2D,
            .format = FrameFormat,
            .subresourceRange{
                .aspectMask = vk::ImageAspectFlagBits::eColor,
                .levelCount = 1,
                .layerCount = 1,
            },
        });
        if (view_result != vk::Result::eSuccess) {
            device.destroyImage(image);
            device.freeMemory(memory);
            return false;
        }

        // The Metal texture behind the image.
        vk::ExportMetalTextureInfoEXT texture_info{
            .image = image,
            .plane = vk::ImageAspectFlagBits::ePlane0,
        };
        vk::ExportMetalObjectsInfoEXT objects_info{.pNext = &texture_info};
        device.exportMetalObjectsEXT(&objects_info);
        if (texture_info.mtlTexture == nil) {
            LOG_ERROR(Core_Vr, "The Vulkan driver gave no Metal texture for a frame image");
            device.destroyImageView(view);
            device.destroyImage(image);
            device.freeMemory(memory);
            return false;
        }

        slot.image = image;
        slot.memory = memory;
        slot.view = view;
        slot.texture = texture_info.mtlTexture;
        slot.width = width;
        slot.height = height;
        return true;
    }
};

OpenXrHost::OpenXrHost() : impl{std::make_unique<Impl>()} {}

OpenXrHost::~OpenXrHost() = default;

OpenXrHost& OpenXrHost::Instance() {
    static OpenXrHost* const instance = new OpenXrHost;
    return *instance;
}

void OpenXrHost::Shutdown() {
    impl->accepting = false;
    impl->available = false;
}

bool OpenXrHost::Connect() {
    impl->enabled = EnvFlag("SHADPS4_OPENXR", true);
    impl->pause_when_away = EnvFlag("SHADPS4_XR_PAUSE", true);
    if (!impl->enabled) {
        LOG_INFO(Core_Vr, "The headset is not used (SHADPS4_OPENXR=0)");
        return false;
    }
    // The app around the emulator is the headset's runtime: it is always there.
    impl->available = true;
    LOG_INFO(Core_Vr, "Apple Vision Pro: frames go to the app's immersive space");
    return true;
}

bool OpenXrHost::IsAvailable() const {
    return impl->available;
}

bool OpenXrHost::HasHeadset() const {
    return impl->available;
}

std::vector<std::string> OpenXrHost::VulkanInstanceExtensions() const {
    return {};
}

std::vector<std::string> OpenXrHost::VulkanDeviceExtensions() const {
    // The frame images are handed to the app as Metal textures.
    return {VK_EXT_METAL_OBJECTS_EXTENSION_NAME};
}

vk::PhysicalDevice OpenXrHost::PreferredPhysicalDevice(vk::Instance) const {
    // There is one GPU.
    return nullptr;
}

void OpenXrHost::Start(const Graphics& graphics) {
    if (!impl->available || impl->started) {
        return;
    }
    impl->graphics = graphics;
    impl->started = true;
    LOG_INFO(Core_Vr, "Frames are handed to the headset as Metal textures of {}",
             vk::to_string(FrameFormat));
}

std::optional<OpenXrHost::Target> OpenXrHost::BeginFrame(u32 width, u32 height) {
    if (!impl->started || !impl->accepting.load(std::memory_order_relaxed) || width == 0 ||
        height == 0) {
        return std::nullopt;
    }
    std::scoped_lock lock{impl->slot_mutex};
    impl->DestroyRetired();
    for (u32 attempt = 0; attempt < NumSlots; ++attempt) {
        const u32 index = (impl->next_slot + attempt) % NumSlots;
        Impl::Slot& slot = impl->slots[index];
        // Not what is still being drawn or shown, and not the frame that waits to be shown.
        const bool reusable = slot.state == Impl::Slot::State::Free ||
                              (slot.state == Impl::Slot::State::Ready &&
                               static_cast<s32>(index) != impl->latest);
        if (!reusable) {
            continue;
        }
        if ((!slot.image || slot.width != width || slot.height != height) &&
            !impl->Create(slot, width, height)) {
            LOG_ERROR(Core_Vr, "No image of {}x{} to hand frames to the headset in", width,
                      height);
            return std::nullopt;
        }
        impl->next_slot = (index + 1) % NumSlots;
        slot.state = Impl::Slot::State::Drawing;
        return Target{
            .index = index,
            .image = slot.image,
            .view = slot.view,
            .width = slot.width,
            .height = slot.height,
        };
    }
    return std::nullopt;
}

void OpenXrHost::EndFrame(u32 index, const PresentedFrame& info) {
    std::scoped_lock lock{impl->slot_mutex};
    Impl::Slot& slot = impl->slots[index % NumSlots];
    if (slot.state != Impl::Slot::State::Drawing) {
        return;
    }
    slot.state = Impl::Slot::State::Ready;
    slot.info = info;
    impl->latest = static_cast<s32>(index % NumSlots);
    impl->delivered_frames.fetch_add(1, std::memory_order_relaxed);
    const auto now = Clock::now();
    if (impl->last_delivery != Clock::time_point{}) {
        const double gap = std::chrono::duration<double>(now - impl->last_delivery).count();
        impl->longest_gap = std::max(impl->longest_gap, gap);
        if (gap > 0.050) {
            ++impl->long_gaps;
        }
    }
    impl->last_delivery = now;
}

void OpenXrHost::DropFrame(u32 index) {
    std::scoped_lock lock{impl->slot_mutex};
    Impl::Slot& slot = impl->slots[index % NumSlots];
    if (slot.state == Impl::Slot::State::Drawing) {
        slot.state = Impl::Slot::State::Free;
    }
}

bool OpenXrHost::IsShowing() const {
    return impl->showing.load(std::memory_order_relaxed);
}

std::string OpenXrHost::AudioOutputName() const {
    // The headset's speakers are the system's sound output.
    return {};
}

std::string OpenXrHost::AudioInputName() const {
    return {};
}

// --- what the app calls (platform/visionos/astro_core.h) ------------------------------------

struct VisionOsBridge {
    using Slot = OpenXrHost::Impl::Slot;

    static OpenXrHost::Impl& Host() {
        return *OpenXrHost::Instance().impl;
    }

    static void SetSessionRunning(bool running) {
        auto& host = Host();
        if (host.accepting.exchange(running) != running) {
            LOG_INFO(Core_Vr, "Headset session: {}", running ? "running" : "ended");
            // Nothing but the controller is at hand for resetting the view.
            Runtime::Instance().EnableViewGestures(running);
            if (!running) {
                host.showing = false;
            }
        }
        host.UpdateWorn();
    }

    static void SetShowing(bool showing) {
        auto& host = Host();
        host.showing = showing;
        host.UpdateWorn();
    }

    static void SetIpd(float ipd) {
        Host().ipd = ipd;
    }

    static bool TakeFrame(AstroFrame& frame) {
        auto& host = Host();
        std::scoped_lock lock{host.slot_mutex};
        if (host.latest < 0 || host.slots[host.latest].state != Slot::State::Ready) {
            return false;
        }
        Slot& slot = host.slots[host.latest];
        // A title with nothing to show hands over a black picture of a pixel an eye.
        if (slot.width < 64 || slot.height < 64) {
            slot.state = Slot::State::Free;
            return false;
        }
        slot.state = Slot::State::Reading;
        const PresentedFrame& info = slot.info;
        frame.slot = static_cast<u32>(host.latest);
        frame.frame_id = info.id;
        frame.texture = (__bridge void*)slot.texture;
        frame.width = slot.width;
        frame.height = slot.height;
        frame.eye_width = info.eye_width;
        frame.eye_height = info.eye_height;
        frame.position[0] = info.render_pose.position.x;
        frame.position[1] = info.render_pose.position.y;
        frame.position[2] = info.render_pose.position.z;
        // A rotation, whatever arrives: brought to length one, nothing usable is straight ahead.
        const Quat& q = info.render_pose.orientation;
        const float length = std::sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
        if (std::isfinite(length) && length > 0.5f) {
            frame.orientation[0] = q.x / length;
            frame.orientation[1] = q.y / length;
            frame.orientation[2] = q.z / length;
            frame.orientation[3] = q.w / length;
        } else {
            frame.orientation[0] = frame.orientation[1] = frame.orientation[2] = 0.0f;
            frame.orientation[3] = 1.0f;
        }
        frame.tan_out = info.fov.tan_out;
        frame.tan_in = info.fov.tan_in;
        frame.tan_up = info.fov.tan_top;
        frame.tan_down = info.fov.tan_bottom;
        frame.ipd = host.ipd;
        return true;
    }

    static void ReleaseFrame(u32 index) {
        auto& host = Host();
        std::scoped_lock lock{host.slot_mutex};
        Slot& slot = host.slots[index % NumSlots];
        if (slot.state == Slot::State::Reading) {
            slot.state = Slot::State::Free;
        }
    }

    static u32 FramesDelivered() {
        return Host().delivered_frames.load(std::memory_order_relaxed);
    }
};
} // namespace Core::Vr

extern "C" {

void astro_core_set_session_running(bool running) {
    Core::Vr::VisionOsBridge::SetSessionRunning(running);
}

void astro_core_set_showing(bool showing) {
    Core::Vr::VisionOsBridge::SetShowing(showing);
}

bool astro_core_take_frame(AstroFrame* frame) {
    return frame != nullptr && Core::Vr::VisionOsBridge::TakeFrame(*frame);
}

void astro_core_release_frame(uint32_t slot) {
    Core::Vr::VisionOsBridge::ReleaseFrame(slot);
}

uint32_t astro_core_frames_delivered(void) {
    return Core::Vr::VisionOsBridge::FramesDelivered();
}

void astro_core_update_ipd(float ipd) {
    if (!(ipd > 0.04f && ipd < 0.09f)) {
        return;
    }
    Core::Vr::VisionOsBridge::SetIpd(ipd);
    auto& runtime = Core::Vr::Runtime::Instance();
    // The field of view stays what the title was told (it asks once).
    runtime.UpdateOptics(runtime.GetConfig().fov, ipd);
}

} // extern "C"
