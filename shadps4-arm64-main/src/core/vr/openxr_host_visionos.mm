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
// The frames are images of the emulator's Vulkan device (KosmicKrisp or MoltenVK) that are Metal
// textures as well (VK_EXT_metal_objects): the app samples them without any copy.

#ifndef VK_USE_PLATFORM_METAL_EXT
#define VK_USE_PLATFORM_METAL_EXT
#endif

#import <Metal/Metal.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdlib>
#include <mutex>

#include "common/diagnostics.h"
#include "common/logging/log.h"
#include "core/vr/frame_queue.h"
#include "core/vr/openxr_host.h"
#include "core/vr/vr_runtime.h"
#include "platform/visionos/astro_core.h"

namespace Core::Vr {

namespace {

using Clock = std::chrono::steady_clock;

/// Being drawn (the GPU may be a frame or two ahead), waiting to be shown, being shown, and
/// some to spare: with fewer, the GPU thread found none free at times and stalled. Two of them
/// wait to be shown (FrameQueue). The same number is in vpkengine_presenter.h and
/// vpkengine_renderer.mm (kSlots).
constexpr u32 NumSlots = 8;

float EnvFloat(const char* name, float fallback) {
    const char* value = std::getenv(name);
    return value != nullptr && *value != '\0' ? static_cast<float>(std::atof(value)) : fallback;
}

bool EnvFlag(const char* name, bool fallback) {
    const char* value = std::getenv(name);
    return value != nullptr && *value != '\0' ? value[0] != '0' : fallback;
}

/// Gaps between deliveries, in milliseconds: under 2, 5, 10, 20, 40, and more.
constexpr std::array<double, 5> GapLimits{0.002, 0.005, 0.010, 0.020, 0.040};

} // namespace

struct OpenXrHost::Impl {
    struct Slot {
        vk::Image image;
        vk::DeviceMemory memory;
        vk::ImageView view;
        id<MTLTexture> texture{nil};
        u32 width{};
        u32 height{};
        PresentedFrame info;
    };

    struct Retired {
        vk::Image image;
        vk::DeviceMemory memory;
        vk::ImageView view;
        id<MTLTexture> metal{nil}; // a texture of our own (Metal frames): released when destroyed
        Clock::time_point since;
    };

    // Settings.
    bool enabled{true};
    bool pause_when_away{true};

    bool available{};
    Graphics graphics{};
    bool started{};
    id<MTLDevice> metal_device{nil}; // set: frames are Metal textures of our own (no Vulkan)

    std::mutex slot_mutex;
    std::condition_variable slot_freed;
    std::array<Slot, NumSlots> slots;
    FrameQueue<NumSlots> queue; // the state of each slot: which is taken next
    u32 next_slot{};
    std::vector<Retired> retired;
    std::atomic<bool> accepting{};
    std::atomic<bool> showing{};
    std::atomic<u32> delivered_frames{};
    u32 taken_frames{};
    Clock::time_point last_delivery;
    double longest_gap{};
    u32 long_gaps{};
    // Diagnostics: gaps between deliveries (GapLimits and over), every five seconds.
    std::array<u32, GapLimits.size() + 1> gap_counts{};
    double report_longest_gap{};
    Clock::time_point last_report;
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
            retired.push_back({slot.image, slot.memory, slot.view, nil, Clock::now()});
        } else if (slot.texture != nil && metal_device != nil) {
            retired.push_back({nullptr, nullptr, nullptr, slot.texture, Clock::now()});
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
            if (old.metal != nil) {
                [old.metal release];
                return true;
            }
            graphics.device.destroyImageView(old.view);
            graphics.device.destroyImage(old.image);
            graphics.device.freeMemory(old.memory);
            return true;
        });
    }

    bool CreateMetal(Slot& slot, u32 width, u32 height) {
        Retire(slot);
        @autoreleasepool {
        MTLTextureDescriptor* d =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB
                                                               width:width
                                                              height:height
                                                           mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModePrivate;
        id<MTLTexture> texture = [metal_device newTextureWithDescriptor:d]; // +1, ours
        if (texture == nil) {
            return false;
        }
        texture.label = @"headset frame";
        slot.texture = texture;
        slot.width = width;
        slot.height = height;
        return true;
        }
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
    // ASTRO_TAKE_LATEST=1: the headset takes only the newest frame, as it did before.
    const char* latest = std::getenv("ASTRO_TAKE_LATEST");
    impl->queue.take_latest = latest != nullptr && latest[0] == '1';
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

void OpenXrHost::StartMetal(void* mtl_device) {
    if (!impl->available || impl->started || mtl_device == nullptr) {
        return;
    }
    impl->metal_device = [(id<MTLDevice>)mtl_device retain];
    impl->started = true;
    LOG_INFO(Core_Vr, "Frames are handed to the headset as Metal textures of our own (RGBA8 sRGB)");
}

std::optional<OpenXrHost::MetalTarget> OpenXrHost::BeginMetalFrame(u32 width, u32 height) {
    if (!impl->started || impl->metal_device == nil ||
        !impl->accepting.load(std::memory_order_relaxed) || width == 0 || height == 0) {
        return std::nullopt;
    }
    std::unique_lock lock{impl->slot_mutex};
    impl->DestroyRetired();
    const auto reusable = [&](u32 index) { return impl->queue.Reusable(index); };
    impl->slot_freed.wait_for(lock, std::chrono::milliseconds{100}, [&] {
        for (u32 index = 0; index < NumSlots; ++index) {
            if (reusable(index)) {
                return true;
            }
        }
        return false;
    });
    for (u32 attempt = 0; attempt < NumSlots; ++attempt) {
        const u32 index = (impl->next_slot + attempt) % NumSlots;
        if (!reusable(index)) {
            continue;
        }
        Impl::Slot& slot = impl->slots[index];
        if ((slot.texture == nil || slot.width != width || slot.height != height) &&
            !impl->CreateMetal(slot, width, height)) {
            LOG_ERROR(Core_Vr, "No Metal texture of {}x{} to hand frames to the headset in", width,
                      height);
            return std::nullopt;
        }
        impl->next_slot = (index + 1) % NumSlots;
        impl->queue.Begin(index);
        return MetalTarget{
            .index = index,
            .texture = (void*)slot.texture,
            .width = slot.width,
            .height = slot.height,
        };
    }
    return std::nullopt;
}

std::optional<OpenXrHost::Target> OpenXrHost::BeginFrame(u32 width, u32 height) {
    if (!impl->started || !impl->accepting.load(std::memory_order_relaxed) || width == 0 ||
        height == 0) {
        return std::nullopt;
    }
    std::unique_lock lock{impl->slot_mutex};
    impl->DestroyRetired();
    // All in use: the app gives one back once the GPU has shown it, which is soon. Waiting a
    // little here beats the GPU thread trying again and again.
    const auto has_free = [&] {
        for (u32 index = 0; index < NumSlots; ++index) {
            if (impl->queue.Reusable(index)) {
                return true;
            }
        }
        return false;
    };
    impl->slot_freed.wait_for(lock, std::chrono::milliseconds{100}, has_free);
    for (u32 attempt = 0; attempt < NumSlots; ++attempt) {
        const u32 index = (impl->next_slot + attempt) % NumSlots;
        Impl::Slot& slot = impl->slots[index];
        // Not what is still being drawn or shown, and not the frames that wait to be shown.
        if (!impl->queue.Reusable(index)) {
            continue;
        }
        if ((!slot.image || slot.width != width || slot.height != height) &&
            !impl->Create(slot, width, height)) {
            LOG_ERROR(Core_Vr, "No image of {}x{} to hand frames to the headset in", width,
                      height);
            return std::nullopt;
        }
        impl->next_slot = (index + 1) % NumSlots;
        impl->queue.Begin(index);
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
    std::unique_lock lock{impl->slot_mutex};
    Impl::Slot& slot = impl->slots[index % NumSlots];
    if (!impl->queue.End(index % NumSlots)) {
        return;
    }
    slot.info = info;
    impl->delivered_frames.fetch_add(1, std::memory_order_relaxed);
    impl->slot_freed.notify_all();
    const auto now = Clock::now();
    if (impl->last_delivery != Clock::time_point{}) {
        const double gap = std::chrono::duration<double>(now - impl->last_delivery).count();
        impl->longest_gap = std::max(impl->longest_gap, gap);
        if (gap > 0.050) {
            ++impl->long_gaps;
        }
        if (Common::Diagnostics()) {
            impl->report_longest_gap = std::max(impl->report_longest_gap, gap);
            ++impl->gap_counts[std::upper_bound(GapLimits.begin(), GapLimits.end(), gap) -
                               GapLimits.begin()];
        }
    }
    impl->last_delivery = now;
    if (!Common::Diagnostics()) {
        return;
    }
    if (impl->last_report == Clock::time_point{}) {
        impl->last_report = now;
    }
    if (now - impl->last_report < std::chrono::seconds{5}) {
        return;
    }
    const auto counts = impl->gap_counts;
    const double longest = impl->report_longest_gap;
    const u32 superseded = impl->queue.superseded;
    const u32 taken = impl->taken_frames;
    impl->gap_counts = {};
    impl->report_longest_gap = 0.0;
    impl->last_report = now;
    lock.unlock();
    LOG_INFO(Core_Vr,
             "DIAG: deliveries by gap (<2 <5 <10 <20 <40 >=40 ms): {} {} {} {} {} {}; {:.0f} ms the "
             "longest; {} delivered, {} taken, {} superseded in all",
             counts[0], counts[1], counts[2], counts[3], counts[4], counts[5], longest * 1e3,
             impl->delivered_frames.load(std::memory_order_relaxed), taken, superseded);
}

void OpenXrHost::DropFrame(u32 index) {
    std::scoped_lock lock{impl->slot_mutex};
    impl->queue.Drop(index % NumSlots);
    impl->slot_freed.notify_all();
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

void OpenXrHost::AudioDevicesChanged() {
    // The headset's speakers and microphone are the system's own: nothing to ask again.
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
        // The oldest of the frames that wait (two at most), the newest with ASTRO_TAKE_LATEST=1.
        const int taken = host.queue.Take();
        if (taken < 0) {
            return false;
        }
        Slot& slot = host.slots[taken];
        // A title with nothing to show hands over a black picture of a pixel an eye.
        if (slot.width < 64 || slot.height < 64) {
            host.queue.Return(static_cast<u32>(taken));
            host.slot_freed.notify_all();
            return false;
        }
        ++host.taken_frames;
        // The pose is the one this frame was drawn for, not the newest one's.
        const PresentedFrame& info = slot.info;
        frame.slot = static_cast<u32>(taken);
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
        host.queue.Return(index % NumSlots);
        host.slot_freed.notify_all();
    }

    static u32 FramesDelivered() {
        return Host().delivered_frames.load(std::memory_order_relaxed);
    }

    static u32 FramesSuperseded() {
        auto& host = Host();
        std::scoped_lock lock{host.slot_mutex};
        return host.queue.superseded;
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

uint32_t astro_core_frames_superseded(void) {
    return Core::Vr::VisionOsBridge::FramesSuperseded();
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
