// SPDX-FileCopyrightText: Copyright 2024 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstring>
#include <mutex>
#include <optional>
#include <string>

#include "common/logging/log.h"
#include "core/guest_cpu/guest_watchdog.h"
#include "core/libraries/error_codes.h"
#include "core/libraries/hmd/hmd.h"
#include "core/libraries/hmd/hmd_error.h"
#include "core/libraries/libs.h"
#include "core/libraries/videoout/video_out.h"
#include "core/memory.h"
#include "core/vr/vr_runtime.h"

namespace Libraries::Hmd {

namespace {

struct UserEvent {
    Libraries::Kernel::OrbisKernelEqueue eq{};
    s32 id{};
    bool is_set{};

    void Trigger() const {
        if (!is_set) {
            return;
        }
        if (auto* equeue = Libraries::Kernel::GetEqueue(eq); equeue != nullptr) {
            equeue->TriggerEvent(id, Libraries::Kernel::OrbisKernelEvent::Filter::User, nullptr);
        }
    }
};

// On real hardware a system thread warps the latest submitted frame to the current head pose
// and scans it out on every panel refresh. Here the host compositor does the warping, so this
// only has to keep the guest-visible timing alive and pass submitted frames along.
struct Reprojection {
    std::mutex mutex;
    bool initialized{};
    s32 video_out_handle{-1};
    s32 display_index[2]{-1, -1};
    u32 submitted_frames{};
    UserEvent start_event;
    UserEvent end_event;
    // The frame labels of the last frames handed over (OrbisHmdReprojectionParam::frame_label).
    std::array<uintptr_t, 8> frame_labels{};
    u32 next_label{};
};

Reprojection g_reprojection;

Core::Vr::Fov FovFromUv(const OrbisHmdReprojectionEyeUv& left_eye) {
    // uv = tan * scale + offset, so the image edges (uv 0 and 1) give the half angles back.
    // On the left eye the left edge is the temple side.
    return {
        .tan_out = left_eye.offset_x / left_eye.scale_x,
        .tan_in = (1.0f - left_eye.offset_x) / left_eye.scale_x,
        .tan_top = left_eye.offset_y / left_eye.scale_y,
        .tan_bottom = (1.0f - left_eye.offset_y) / left_eye.scale_y,
    };
}

} // namespace

void OnVblank() {
    UserEvent start_event;
    UserEvent end_event;
    {
        std::scoped_lock lock{g_reprojection.mutex};
        if (!g_reprojection.initialized) {
            return;
        }
        start_event = g_reprojection.start_event;
        end_event = g_reprojection.end_event;
    }
    start_event.Trigger();
    end_event.Trigger();
}

s32 PS4_SYSV_ABI sceHmdReprojectionStartMultilayer() {
    LOG_ERROR(Lib_Hmd, "(STUBBED) called");
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionAddDisplayBuffer() {
    LOG_ERROR(Lib_Hmd, "(STUBBED) called");
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionClearUserEventEnd() {
    LOG_INFO(Lib_Hmd, "called");
    std::scoped_lock lock{g_reprojection.mutex};
    g_reprojection.end_event = {};
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionClearUserEventStart() {
    LOG_INFO(Lib_Hmd, "called");
    std::scoped_lock lock{g_reprojection.mutex};
    g_reprojection.start_event = {};
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionDebugGetLastInfo() {
    LOG_ERROR(Lib_Hmd, "(STUBBED) called");
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionDebugGetLastInfoMultilayer() {
    LOG_ERROR(Lib_Hmd, "(STUBBED) called");
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionFinalize() {
    LOG_INFO(Lib_Hmd, "called");
    std::scoped_lock lock{g_reprojection.mutex};
    g_reprojection.initialized = false;
    g_reprojection.video_out_handle = -1;
    g_reprojection.start_event = {};
    g_reprojection.end_event = {};
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionFinalizeCapture() {
    LOG_ERROR(Lib_Hmd, "(STUBBED) called");
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionInitialize(const OrbisHmdReprojectionResourceInfo* resource,
                                              s32 type, void* option) {
    if (resource == nullptr) {
        return ORBIS_HMD_ERROR_PARAMETER_NULL;
    }
    LOG_INFO(Lib_Hmd,
             "called, type = {}, thread_priority = {}, cpu_affinity_mask = {:#x}, pipe_id = {}, "
             "queue_id = {}",
             type, resource->thread_priority, resource->cpu_affinity_mask, resource->pipe_id,
             resource->queue_id);
    std::scoped_lock lock{g_reprojection.mutex};
    g_reprojection.initialized = true;
    g_reprojection.submitted_frames = 0;
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionInitializeCapture() {
    LOG_ERROR(Lib_Hmd, "(STUBBED) called");
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionQueryGarlicBuffAlign() {
    return 0x100;
}

s32 PS4_SYSV_ABI sceHmdReprojectionQueryGarlicBuffSize() {
    return 0x100000;
}

s32 PS4_SYSV_ABI sceHmdReprojectionQueryOnionBuffAlign() {
    return 0x100;
}

s32 PS4_SYSV_ABI sceHmdReprojectionQueryOnionBuffSize() {
    return 0x810;
}

s32 PS4_SYSV_ABI sceHmdReprojectionSetCallback() {
    LOG_ERROR(Lib_Hmd, "(STUBBED) called");
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionSetDisplayBuffers(s32 video_out_handle, s32 index0, s32 index1,
                                                     void* option) {
    LOG_INFO(Lib_Hmd, "called, video_out_handle = {}, index0 = {}, index1 = {}", video_out_handle,
             index0, index1);
    std::scoped_lock lock{g_reprojection.mutex};
    g_reprojection.video_out_handle = video_out_handle;
    g_reprojection.display_index[0] = index0;
    g_reprojection.display_index[1] = index1;
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionSetOutputMinColor(float red, float green, float blue) {
    LOG_DEBUG(Lib_Hmd, "called, red = {}, green = {}, blue = {}", red, green, blue);
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionSetUserEventEnd(Libraries::Kernel::OrbisKernelEqueue eq,
                                                   s32 id) {
    LOG_INFO(Lib_Hmd, "called, eq = {}, id = {}", eq, id);
    std::scoped_lock lock{g_reprojection.mutex};
    g_reprojection.end_event = {.eq = eq, .id = id, .is_set = true};
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionSetUserEventStart(Libraries::Kernel::OrbisKernelEqueue eq,
                                                     s32 id) {
    LOG_INFO(Lib_Hmd, "called, eq = {}, id = {}", eq, id);
    std::scoped_lock lock{g_reprojection.mutex};
    g_reprojection.start_event = {.eq = eq, .id = id, .is_set = true};
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionStart(const OrbisHmdReprojectionParam* param,
                                         const OrbisHmdReprojectionTrackerState* tracker_state,
                                         s64 flip_arg, s32 option) {
    if (param == nullptr || tracker_state == nullptr || param->texture[0] == nullptr ||
        param->texture[1] == nullptr) {
        return ORBIS_HMD_ERROR_PARAMETER_NULL;
    }

    Libraries::VideoOut::HmdFrame frame{};
    std::memcpy(&frame.eye_textures[0], param->texture[0], sizeof(AmdGpu::Image));
    std::memcpy(&frame.eye_textures[1], param->texture[1], sizeof(AmdGpu::Image));
    frame.fov = FovFromUv(param->uv[0]);
    frame.render_pose = {
        .position{tracker_state->position[0], tracker_state->position[1],
                  tracker_state->position[2]},
        .orientation{tracker_state->orientation[0], tracker_state->orientation[1],
                     tracker_state->orientation[2], tracker_state->orientation[3]},
    };
    frame.flip_arg = flip_arg;

    s32 video_out_handle;
    u32 frame_number;
    {
        std::scoped_lock lock{g_reprojection.mutex};
        if (!g_reprojection.initialized || g_reprojection.video_out_handle < 0) {
            return ORBIS_HMD_ERROR_NOT_INITIALIZED;
        }
        video_out_handle = g_reprojection.video_out_handle;
        frame_number = g_reprojection.submitted_frames++;
        if (param->frame_label != nullptr) {
            g_reprojection.frame_labels[g_reprojection.next_label++ %
                                        g_reprojection.frame_labels.size()] =
                reinterpret_cast<uintptr_t>(param->frame_label);
        }
        // The reprojection alternates between the two display buffers it was given.
        frame.display_index = g_reprojection.display_index[frame_number & 1];
    }

    if (frame_number < 4) {
        const auto& left = frame.eye_textures[0];
        LOG_INFO(Lib_Hmd,
                 "frame {}: flip_arg = {}, eye {}x{} at {:#x} / {:#x}, tan out/in/top/bottom = "
                 "{:.4f}/{:.4f}/{:.4f}/{:.4f}, unknown_40 = {:#x}, flags = {:#x}, option = {}",
                 frame_number, flip_arg, left.width + 1, left.height + 1, left.Address(),
                 frame.eye_textures[1].Address(), frame.fov.tan_out, frame.fov.tan_in,
                 frame.fov.tan_top, frame.fov.tan_bottom, param->unknown_40, param->flags, option);
        LOG_INFO(Lib_Hmd,
                 "frame {}: frame label at {} (now {:#x}), unknown_48 = {:#x}, unknown_50 = {:#x}",
                 frame_number, fmt::ptr(param->frame_label),
                 param->frame_label != nullptr ? *param->frame_label : 0, param->unknown_48,
                 param->unknown_50);
        LOG_INFO(Lib_Hmd,
                 "eye UV: left scale {:.6f}/{:.6f}, offset {:.6f}/{:.6f}; "
                 "right scale {:.6f}/{:.6f}, offset {:.6f}/{:.6f}",
                 param->uv[0].scale_x, param->uv[0].scale_y, param->uv[0].offset_x,
                 param->uv[0].offset_y, param->uv[1].scale_x, param->uv[1].scale_y,
                 param->uv[1].offset_x, param->uv[1].offset_y);
    }

    Core::GuestCpu::NoteGuestProgress();

    // How fast the title delivers frames is the number that matters for comfort; report it now
    // and then.
    {
        using Clock = std::chrono::steady_clock;
        static constexpr auto ReportInterval = std::chrono::seconds{10};
        static Clock::time_point report_time = Clock::now();
        static u32 report_frame = 0;
        const auto now = Clock::now();
        if (now - report_time >= ReportInterval) {
            const float seconds = std::chrono::duration<float>(now - report_time).count();
            LOG_INFO(Lib_Hmd, "{} headset frames so far, {:.1f} per second", frame_number,
                     static_cast<float>(frame_number - report_frame) / seconds);
            report_time = now;
            report_frame = frame_number;
        }
    }

    const s32 result = Libraries::VideoOut::SubmitHmdFrame(video_out_handle, frame);
    if (result != ORBIS_OK) {
        LOG_ERROR(Lib_Hmd, "Could not queue headset frame: {:#x}", static_cast<u32>(result));
    }
    return ORBIS_OK;
}

bool SatisfyReprojectionLabelWait(u32* address, u32 function, u32 ref, u32 mask,
                                  bool new_wait) {
    if (address == nullptr) {
        return false;
    }
    const auto at = reinterpret_cast<uintptr_t>(address);
    {
        std::scoped_lock lock{g_reprojection.mutex};
        const bool known = std::ranges::any_of(g_reprojection.frame_labels, [&](uintptr_t label) {
            return label != 0 && at >= label && at < label + sizeof(u64);
        });
        if (!known) {
            // A label next to the known ones (a title keeps one per frame in flight, side by
            // side) that the GPU waits on (==) before the title has handed its frame over: if
            // the title is in turn waiting for that GPU work, neither moves. Given up on once the
            // same wait has lasted 100 ms (labels of frames handed over are released at once).
            static constexpr uintptr_t Near = 0x80;
            const bool near = function == 3 && (at & 3) == 0 &&
                              std::ranges::any_of(g_reprojection.frame_labels, [&](uintptr_t l) {
                                  return l != 0 && at + Near >= l && at < l + Near;
                              });
            if (!near) {
                return false;
            }
            // One entry per address being waited on (gfx and the compute queues may each wait).
            struct NearWait {
                uintptr_t at;
                std::chrono::steady_clock::time_point since;
            };
            static std::array<NearWait, 4> waits{};
            static u32 next_slot{};
            const auto now = std::chrono::steady_clock::now();
            NearWait* entry = nullptr;
            for (auto& w : waits) {
                if (w.at == at) {
                    entry = &w;
                }
            }
            if (entry == nullptr) {
                entry = &waits[next_slot++ % waits.size()];
                entry->at = at;
                entry->since = now;
            } else if (new_wait) {
                entry->since = now; // the wait begins now
            }
            if (now - entry->since < std::chrono::milliseconds{100}) {
                return false;
            }
            entry->at = 0;
            static std::atomic<u32> near_told{};
            if (near_told.fetch_add(1, std::memory_order_relaxed) < 8) {
                LOG_WARNING(Lib_Hmd,
                            "REPROJECTION_LABEL_NEAR: the GPU has waited 100 ms on {} next to a "
                            "frame label, for a frame not handed over yet: released",
                            fmt::ptr(address));
            }
        }
    }
    // The comparisons of WAIT_REG_MEM (pm4_cmds.h): 1 <, 2 <=, 3 ==, 4 !=, 5 >=, 6 >.
    const u32 before = *address;
    u32 wanted;
    switch (function) {
    case 1:
        wanted = ref - 1;
        break;
    case 4:
        wanted = (ref ^ mask);
        break;
    case 6:
        wanted = ref + 1;
        break;
    default:
        wanted = ref;
        break;
    }
    const u32 value = (before & ~mask) | (wanted & mask);
    // As the GPU's own label writes are made (EOP, liverpool.cpp): through the memory's backing.
    if (!Core::Memory::Instance()->TryWriteBacking(address, &value,
                                                   sizeof(value))) {
        std::memcpy(address, &value, sizeof(value));
    }
    static std::atomic<u32> told{};
    if (told.fetch_add(1, std::memory_order_relaxed) < 8) {
        LOG_INFO(Lib_Hmd,
                 "REPROJECTION_LABEL: the GPU waits on a frame's label at {} (comparison {}, "
                 "{:#x} under mask {:#x}); it held {:#x}, now {:#x}, as once the reprojection has "
                 "read the frame",
                 fmt::ptr(address), function, ref, mask, before, *address);
    }
    return true;
}

namespace {

/// How many bytes from `addr` on (up to `want`) the guest can read: inside one mapped area with
/// CPU read access. 0 for anything else (a plain integer, an unmapped or GPU-only address).
u64 GuestReadable(u64 addr, u64 want, u32* prot_out = nullptr) {
    // Below the first 64 KB or past the 47-bit user space: an integer, not a pointer.
    if (addr < 0x10000 || addr >= (u64{1} << 47) || want == 0) {
        return 0;
    }
    void* start = nullptr;
    void* end = nullptr;
    u32 prot = 0;
    if (Core::Memory::Instance()->QueryProtection(addr, &start, &end, &prot) != ORBIS_OK) {
        return 0;
    }
    const u64 begin = reinterpret_cast<u64>(start);
    const u64 finish = reinterpret_cast<u64>(end);
    // (The area found is the one before the address when the address is past the last one.)
    if (addr < begin || addr >= finish ||
        (prot & static_cast<u32>(Core::MemoryProt::CpuRead)) == 0) {
        return 0;
    }
    if (prot_out != nullptr) {
        *prot_out = prot;
    }
    return std::min(want, finish - addr);
}

/// Whether 32 bytes look like a Gnm texture descriptor of a flat picture a title would show.
bool PlausibleTexture(const AmdGpu::Image& image) {
    // A plain 2D picture (an array would make an array view, which the composition cannot
    // sample).
    if (static_cast<AmdGpu::ImageType>(image.type) != AmdGpu::ImageType::Color2D ||
        image.depth != 0) {
        return false;
    }
    const u32 width = image.width + 1;
    const u32 height = image.height + 1;
    if (width < 64 || height < 64 || width > 4096 || height > 4096 || image.Pitch() < width ||
        image.Pitch() > 8192 || image.base_level > image.last_level || image.last_level > 12) {
        return false;
    }
    // Format and number format pairs a picture to look at comes in.
    const auto dfmt = static_cast<AmdGpu::DataFormat>(image.data_format);
    const auto nfmt = static_cast<AmdGpu::NumberFormat>(image.num_format);
    using DF = AmdGpu::DataFormat;
    using NF = AmdGpu::NumberFormat;
    u32 bytes_per_texel = 0;
    switch (dfmt) {
    case DF::Format8_8_8_8:
        bytes_per_texel = (nfmt == NF::Unorm || nfmt == NF::Srgb) ? 4 : 0;
        break;
    case DF::Format2_10_10_10:
    case DF::Format10_10_10_2:
        bytes_per_texel = nfmt == NF::Unorm ? 4 : 0;
        break;
    case DF::Format16_16_16_16:
        bytes_per_texel = (nfmt == NF::Float || nfmt == NF::Unorm) ? 8 : 0;
        break;
    case DF::Format11_11_10:
    case DF::Format10_11_11:
        bytes_per_texel = nfmt == NF::Float ? 4 : 0;
        break;
    default:
        break;
    }
    if (bytes_per_texel == 0) {
        return false;
    }
    // Colour tilings of 2D pictures the texture cache detiles.
    switch (image.GetTileMode()) {
    case AmdGpu::TileMode::DisplayLinearAligned:
    case AmdGpu::TileMode::DisplayLinearGeneral:
    case AmdGpu::TileMode::Display1DThin:
    case AmdGpu::TileMode::Display2DThin:
    case AmdGpu::TileMode::Thin1DThin:
    case AmdGpu::TileMode::Thin2DThin:
        break;
    default:
        return false;
    }
    // The picture's memory has to be mapped, all of it (it may be GPU-only: not read here).
    // Its size is at least pitch x height texels (tiling only pads it further).
    void* start = nullptr;
    void* end = nullptr;
    u32 prot = 0;
    const VAddr address = image.Address();
    const u64 size = (u64{image.Pitch()} * height * bytes_per_texel + 0xFF) & ~u64{0xFF};
    return address != 0 &&
           Core::Memory::Instance()->QueryProtection(address, &start, &end, &prot) == ORBIS_OK &&
           address >= reinterpret_cast<u64>(start) &&
           address + size <= reinterpret_cast<u64>(end);
}

/// A texture descriptor read from guest memory at `addr`, if one is there.
std::optional<AmdGpu::Image> TextureAt(u64 addr) {
    if ((addr & 7) != 0 || GuestReadable(addr, sizeof(AmdGpu::Image)) < sizeof(AmdGpu::Image)) {
        return std::nullopt;
    }
    AmdGpu::Image image;
    std::memcpy(&image, reinterpret_cast<const void*>(addr), sizeof(image));
    if (!PlausibleTexture(image)) {
        return std::nullopt;
    }
    return image;
}

void HexDump(u32 call, u32 arg, u64 addr, u64 size) {
    const auto* bytes = reinterpret_cast<const u8*>(addr);
    for (u64 line = 0; line < size; line += 0x20) {
        std::string text;
        for (u64 i = line; i < std::min(size, line + 0x20); ++i) {
            text += fmt::format("{:02x}{}", bytes[i], (i & 7) == 7 ? " " : "");
        }
        LOG_INFO(Lib_Hmd, "2dVr call {} arg{} +{:#04x}: {}", call, arg, line, text);
    }
}

} // namespace

// Undocumented. Older SDK titles hand the headset a flat picture with it (loading screens, 2D
// content shown in VR), which the console's reprojection puts on a virtual screen. Its arguments
// are not known: the first calls are logged, and a texture descriptor is looked for through the
// pointer arguments (in them, or behind the pointers they hold).
s32 PS4_SYSV_ABI sceHmdReprojectionStart2dVr(u64 a0, u64 a1, u64 a2, u64 a3, u64 a4, u64 a5) {
    static std::atomic<u32> calls{};
    const u32 call = calls.fetch_add(1, std::memory_order_relaxed);
    const std::array<u64, 6> args{a0, a1, a2, a3, a4, a5};
    constexpr u32 LoggedCalls = 3;
    if (call < LoggedCalls) {
        LOG_INFO(Lib_Hmd, "2dVr call {}: args {:#x} {:#x} {:#x} {:#x} {:#x} {:#x}", call, a0, a1,
                 a2, a3, a4, a5);
        for (u32 i = 0; i < args.size(); ++i) {
            if (const u64 readable = GuestReadable(args[i], 0x80); readable != 0) {
                HexDump(call, i, args[i], readable);
            }
        }
    }

    // Each argument that points at readable memory: the texture right there, or behind one of
    // the first 16 pointers it holds. Pointers to writable GPU-visible memory holding a
    // counter-sized value may be a frame label (sceHmdReprojectionStart's param has one); they
    // are only logged: a wrong guess would have the GPU's waits next to it released.
    std::optional<AmdGpu::Image> texture;
    std::string found_at;
    for (u32 i = 0; i < args.size() && !texture; ++i) {
        const u64 readable = GuestReadable(args[i], 0x80);
        if (readable < sizeof(u64)) {
            continue;
        }
        if ((texture = TextureAt(args[i]))) {
            found_at = fmt::format("arg{}", i);
            break;
        }
        const auto* slots = reinterpret_cast<const u64*>(args[i]);
        const u32 slot_count = static_cast<u32>(readable / sizeof(u64));
        u32 texture_slot = slot_count;
        for (u32 slot = 0; slot < slot_count; ++slot) {
            if ((texture = TextureAt(slots[slot]))) {
                texture_slot = slot;
                found_at = fmt::format("*(arg{} + {:#x})", i, slot * 8);
                break;
            }
        }
        if (call >= LoggedCalls) {
            continue;
        }
        for (u32 slot = 0; slot < slot_count; ++slot) {
            const u64 candidate = slots[slot];
            u32 prot = 0;
            if (slot == texture_slot || (candidate & 7) != 0 ||
                GuestReadable(candidate, sizeof(u64), &prot) < sizeof(u64)) {
                continue;
            }
            const u32 wanted = static_cast<u32>(Core::MemoryProt::CpuWrite) |
                               static_cast<u32>(Core::MemoryProt::GpuRead);
            const u64 value = *reinterpret_cast<const u64*>(candidate);
            if ((prot & wanted) == wanted && value <= 0xFFFFFFFFull) {
                LOG_INFO(Lib_Hmd,
                         "2dVr call {}: possible frame label *(arg{} + {:#x}) = {:#x}, holding "
                         "{:#x} (prot {:#x}); not used",
                         call, i, slot * 8, candidate, value, prot);
            }
        }
    }

    if (!texture) {
        static std::atomic<bool> told{};
        if (!told.exchange(true)) {
            LOG_WARNING(Lib_Hmd, "2dVr: no texture descriptor found in the arguments ({:#x} {:#x} "
                                 "{:#x}): nothing shown",
                        a0, a1, a2);
        }
        return ORBIS_OK;
    }

    Libraries::VideoOut::HmdFrame frame{};
    frame.eye_textures[0] = *texture;
    frame.eye_textures[1] = *texture;
    frame.is_screen = true;
    s32 video_out_handle;
    {
        std::scoped_lock lock{g_reprojection.mutex};
        if (!g_reprojection.initialized || g_reprojection.video_out_handle < 0) {
            static std::atomic<bool> told{};
            if (!told.exchange(true)) {
                LOG_WARNING(Lib_Hmd, "2dVr: the reprojection has no display buffers: nothing "
                                     "shown");
            }
            return ORBIS_OK;
        }
        video_out_handle = g_reprojection.video_out_handle;
        const u32 frame_number = g_reprojection.submitted_frames++;
        frame.display_index = g_reprojection.display_index[frame_number & 1];
    }
    if (call < LoggedCalls) {
        LOG_INFO(Lib_Hmd,
                 "2dVr call {}: texture at {} ({}x{} at {:#x}, dfmt {} nfmt {}, dst_sel "
                 "{}{}{}{}, tile mode {})",
                 call, found_at, texture->width + 1, texture->height + 1, texture->Address(),
                 static_cast<u32>(texture->data_format), static_cast<u32>(texture->num_format),
                 static_cast<u32>(texture->dst_sel_x), static_cast<u32>(texture->dst_sel_y),
                 static_cast<u32>(texture->dst_sel_z), static_cast<u32>(texture->dst_sel_w),
                 static_cast<u32>(texture->tiling_index));
    }

    Core::GuestCpu::NoteGuestProgress();
    const s32 result = Libraries::VideoOut::SubmitHmdFrame(video_out_handle, frame);
    if (result != ORBIS_OK) {
        static std::atomic<u32> failed{};
        if (failed.fetch_add(1, std::memory_order_relaxed) < 8) {
            LOG_ERROR(Lib_Hmd, "2dVr: could not queue the picture: {:#x}",
                      static_cast<u32>(result));
        }
    }
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionStartCapture() {
    LOG_ERROR(Lib_Hmd, "(STUBBED) called");
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionStartLiveCapture() {
    LOG_ERROR(Lib_Hmd, "(STUBBED) called");
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionStartMultilayer2() {
    LOG_ERROR(Lib_Hmd, "(STUBBED) called");
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionStartWideNear() {
    LOG_ERROR(Lib_Hmd, "(STUBBED) called");
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionStartWideNearWithOverlay() {
    LOG_ERROR(Lib_Hmd, "(STUBBED) called");
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionStartWithOverlay() {
    LOG_ERROR(Lib_Hmd, "(STUBBED) called");
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionStop() {
    LOG_INFO(Lib_Hmd, "called");
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionStopCapture() {
    LOG_ERROR(Lib_Hmd, "(STUBBED) called");
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionStopLiveCapture() {
    LOG_ERROR(Lib_Hmd, "(STUBBED) called");
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionUnsetCallback() {
    LOG_ERROR(Lib_Hmd, "(STUBBED) called");
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdReprojectionUnsetDisplayBuffers() {
    LOG_INFO(Lib_Hmd, "called");
    std::scoped_lock lock{g_reprojection.mutex};
    g_reprojection.video_out_handle = -1;
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI Func_A31A0320D80EAD99() {
    LOG_ERROR(Lib_Hmd, "(STUBBED) called");
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI Func_B9A6FA0735EC7E49() {
    LOG_ERROR(Lib_Hmd, "(STUBBED) called");
    return ORBIS_OK;
}

void RegisterReprojection(Core::Loader::SymbolsResolver* sym) {
    LIB_FUNCTION("8gH1aLgty5I", "libsceHmdReprojectionMultilayer", 1, "libSceHmd",
                 sceHmdReprojectionStartMultilayer);
    LIB_FUNCTION("NTIbBpSH9ik", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionAddDisplayBuffer);
    LIB_FUNCTION("94+Ggm38KCg", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionClearUserEventEnd);
    LIB_FUNCTION("mdyFbaJj66M", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionClearUserEventStart);
    LIB_FUNCTION("MdV0akauNow", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionDebugGetLastInfo);
    LIB_FUNCTION("ymiwVjPB5+k", "libSceHmd", 1, "libSceHmd",
                 sceHmdReprojectionDebugGetLastInfoMultilayer);
    LIB_FUNCTION("ZrV5YIqD09I", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionFinalize);
    LIB_FUNCTION("utHD2Ab-Ixo", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionFinalizeCapture);
    LIB_FUNCTION("OuygGEWkins", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionInitialize);
    LIB_FUNCTION("BTrQnC6fcAk", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionInitializeCapture);
    LIB_FUNCTION("TkcANcGM0s8", "libSceHmd", 1, "libSceHmd",
                 sceHmdReprojectionQueryGarlicBuffAlign);
    LIB_FUNCTION("z0KtN1vqF2E", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionQueryGarlicBuffSize);
    LIB_FUNCTION("IWybWbR-xvA", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionQueryOnionBuffAlign);
    LIB_FUNCTION("kLUAkN6a1e8", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionQueryOnionBuffSize);
    LIB_FUNCTION("6CRWGc-evO4", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionSetCallback);
    LIB_FUNCTION("E+dPfjeQLHI", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionSetDisplayBuffers);
    LIB_FUNCTION("LjdLRysHU6Y", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionSetOutputMinColor);
    LIB_FUNCTION("knyIhlkpLgE", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionSetUserEventEnd);
    LIB_FUNCTION("7as0CjXW1B8", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionSetUserEventStart);
    LIB_FUNCTION("dntZTJ7meIU", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionStart);
    LIB_FUNCTION("q3e8+nEguyE", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionStart2dVr);
    LIB_FUNCTION("RrvyU1pjb9A", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionStartCapture);
    LIB_FUNCTION("XZ5QUzb4ae0", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionStartLiveCapture);
    LIB_FUNCTION("8gH1aLgty5I", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionStartMultilayer);
    LIB_FUNCTION("gqAG7JYeE7A", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionStartMultilayer2);
    LIB_FUNCTION("3JyuejcNhC0", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionStartWideNear);
    LIB_FUNCTION("mKa8scOc4-k", "libSceHmd", 1, "libSceHmd",
                 sceHmdReprojectionStartWideNearWithOverlay);
    LIB_FUNCTION("kcldQ7zLYQQ", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionStartWithOverlay);
    LIB_FUNCTION("vzMEkwBQciM", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionStop);
    LIB_FUNCTION("F7Sndm5teWw", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionStopCapture);
    LIB_FUNCTION("PAa6cUL5bR4", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionStopLiveCapture);
    LIB_FUNCTION("0wnZViigP9o", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionUnsetCallback);
    LIB_FUNCTION("iGNNpDDjcwo", "libSceHmd", 1, "libSceHmd", sceHmdReprojectionUnsetDisplayBuffers);
    LIB_FUNCTION("oxoDINgOrZk", "libSceHmd", 1, "libSceHmd", Func_A31A0320D80EAD99);
    LIB_FUNCTION("uab6BzXsfkk", "libSceHmd", 1, "libSceHmd", Func_B9A6FA0735EC7E49);
}
} // namespace Libraries::Hmd
