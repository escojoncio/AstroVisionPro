// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

// The emulator's side of platform/visionos/astro_core.h, apart from the frames
// (core/vr/openxr_host_visionos.mm) and the executable memory (jit_arena.c).

#import <Foundation/Foundation.h>

#include <array>
#include <memory>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// The app has its own main (SwiftUI): SDL must not supply one.
#define SDL_MAIN_HANDLED
#include <SDL3/SDL_main.h>

#include "common/logging/log.h"
#include "common/path_util.h"
#include "common/singleton.h"
#include "core/vr/vr_runtime.h"
#include "input/controller.h"
#include "platform/visionos/astro_core.h"

#include <pthread.h>

// main.cpp, compiled under this name for the app (see CMakeLists.txt).
int shadps4_main(int argc, char* argv[]);

namespace {

std::atomic<AstroCoreState> g_state{AstroCoreStateIdle};
std::atomic<int> g_exit_code{0};
std::string g_log_path;

std::mutex g_feedback_mutex;
AstroPadFeedback g_feedback{};
bool g_feedback_changed{};

std::atomic<bool> g_motion_seen{};

Input::GameController* FirstController() {
    return (*Common::Singleton<Input::GameControllers>::Instance())[0];
}

} // namespace

extern "C" {

int astro_core_start(const char* game_path, const char* const* environment, int count) {
    AstroCoreState expected = AstroCoreStateIdle;
    if (game_path == nullptr || !g_state.compare_exchange_strong(expected, AstroCoreStateStarting)) {
        return EBUSY;
    }
    for (int i = 0; i < count; ++i) {
        const std::string pair = environment[i] != nullptr ? environment[i] : "";
        const auto equals = pair.find('=');
        if (equals != std::string::npos && equals != 0) {
            setenv(pair.substr(0, equals).c_str(), pair.substr(equals + 1).c_str(), 1);
        }
    }
    // No window and no display of its own: SDL is there for events and sound only, and the
    // frames go to the app (core/vr/openxr_host_visionos.mm).
    setenv("SHADPS4_HEADLESS", "1", 1);
    // SDL must not reach for what the app already does or a visionOS app may not use: the
    // controller is read by the app (GameController) and handed over, so SDL leaves controllers
    // alone (its HIDAPI driver would also reach for Bluetooth); the PlayStation Camera is the
    // emulator's virtual one, so SDL opens no camera.
    setenv("SDL_JOYSTICK_MFI", "0", 1);
    setenv("SDL_JOYSTICK_HIDAPI", "0", 1);
    setenv("SDL_CAMERA_DRIVER", "dummy", 1);
    // (The app is SwiftUI's; SDL's own main is not used. This is the main thread.)
    SDL_SetMainReady();

    g_log_path = (Common::FS::GetUserPath(Common::FS::PathType::LogDir) / "shad_log.txt").string();

    // What the game wants of the controller, for the app to pass on.
    Core::Vr::Runtime::Instance().SetPadFeedbackListener([](const Core::Vr::PadFeedback& wanted) {
        std::scoped_lock lock{g_feedback_mutex};
        g_feedback = {
            .small_motor = wanted.small_motor,
            .large_motor = wanted.large_motor,
            .red = wanted.red,
            .green = wanted.green,
            .blue = wanted.blue,
        };
        g_feedback_changed = true;
    });

    // The emulator's main thread, with the stack a process's main thread would have (a thread
    // of an app gets half a megabyte).
    auto* game = new std::string{game_path};
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setstacksize(&attributes, 64u << 20);
    pthread_t thread;
    const int created = pthread_create(
        &thread, &attributes,
        [](void* argument) -> void* {
            std::unique_ptr<std::string> path{static_cast<std::string*>(argument)};
            pthread_setname_np("shadPS4:Main");
            std::vector<std::string> arguments{"shadps4", "-g", *path};
            std::vector<char*> argv;
            for (auto& value : arguments) {
                argv.push_back(value.data());
            }
            argv.push_back(nullptr);
            g_state = AstroCoreStateRunning;
            const int code = shadps4_main(static_cast<int>(arguments.size()), argv.data());
            g_exit_code = code;
            g_state = AstroCoreStateStopped;
            return nullptr;
        },
        game);
    pthread_attr_destroy(&attributes);
    if (created != 0) {
        delete game;
        g_state = AstroCoreStateIdle;
        return created;
    }
    pthread_detach(thread);
    return 0;
}

AstroCoreState astro_core_state(void) {
    return g_state.load();
}

int astro_core_exit_code(void) {
    return g_exit_code.load();
}

const char* astro_core_log_path(void) {
    return g_log_path.c_str();
}

// --- the headset -----------------------------------------------------------------------------

void astro_core_display_refresh(float rate) {
    if (!(rate > 30.0f && rate < 400.0f)) {
        return;
    }
    const auto now = std::chrono::steady_clock::now().time_since_epoch();
    auto& runtime = Core::Vr::Runtime::Instance();
    runtime.NoteDisplayRefresh(
        rate, static_cast<u64>(std::chrono::duration_cast<std::chrono::nanoseconds>(now).count()));
    // Holding OPTIONS takes time; without motion sensors nothing else looks often enough.
    if (!g_motion_seen.load(std::memory_order_relaxed)) {
        runtime.PollViewGestures();
    }
}

void astro_core_update_head(const AstroPose* pose, bool tracked) {
    if (pose == nullptr || !tracked) {
        return;
    }
    Core::Vr::DeviceState state;
    state.pose.position = {pose->position[0], pose->position[1], pose->position[2]};
    state.pose.orientation = Core::Vr::Normalize({pose->orientation[0], pose->orientation[1],
                                                   pose->orientation[2], pose->orientation[3]});
    state.linear_velocity = {pose->linear_velocity[0], pose->linear_velocity[1],
                             pose->linear_velocity[2]};
    state.angular_velocity = {pose->angular_velocity[0], pose->angular_velocity[1],
                              pose->angular_velocity[2]};
    state.tracked = true;
    Core::Vr::Runtime::Instance().UpdateHead(state);
}

void astro_core_note_headset_fov(float tan_out, float tan_in, float tan_up, float tan_down) {
    const auto plausible = [](float tangent) { return tangent > 0.1f && tangent < 10.0f; };
    if (plausible(tan_out) && plausible(tan_in) && plausible(tan_up) && plausible(tan_down)) {
        Core::Vr::Runtime::Instance().NoteHeadsetFov({tan_out, tan_in, tan_up, tan_down});
    }
}

void astro_core_request_recenter(void) {
    LOG_INFO(Core_Vr, "View reset in the headset's own system");
    auto& runtime = Core::Vr::Runtime::Instance();
    runtime.RequestRecenter();
    runtime.ResetPadYaw();
}

// --- the controller --------------------------------------------------------------------------

void astro_core_pad_connected(bool connected, const char* name) {
    LOG_INFO(Input, "Controller {}: {}", connected ? "connected" : "disconnected",
             name != nullptr ? name : "");
    if (!connected) {
        FirstController()->ApplyRemoteState(Libraries::Pad::OrbisPadButtonDataOffset::None,
                                            {128, 128, 128, 128, 0, 0}, false, 0.5f, 0.5f);
    }
}

void astro_core_pad_state(const AstroPadState* state) {
    if (state == nullptr) {
        return;
    }
    static std::atomic<bool> home_down{};
    const std::array<int, 6> axes{state->left_x,       state->left_y,
                                  state->right_x,      state->right_y,
                                  state->left_trigger, state->right_trigger};
    FirstController()->ApplyRemoteState(
        static_cast<Libraries::Pad::OrbisPadButtonDataOffset>(state->buttons), axes,
        state->touch_down, state->touch_x, state->touch_y);
    // The PS button is no button of the game's: it resets the view (as on the PC).
    if (home_down.exchange(state->home) != state->home) {
        Core::Vr::Runtime::Instance().NotePadButton(Core::Vr::Runtime::PadButton::Home,
                                                    state->home);
    }
}

void astro_core_pad_motion(const float gyro[3], const float accel[3]) {
    if (gyro == nullptr || accel == nullptr) {
        return;
    }
    g_motion_seen.store(true, std::memory_order_relaxed);
    auto* controller = FirstController();
    // As the Quest build does (main.cpp, the Bachata input reader): into the sensor buffers,
    // then into the pad state the title reads.
    controller->UpdateGyro(gyro);
    controller->UpdateAcceleration(accel);
    auto& vr = Core::Vr::Runtime::Instance();
    vr.UpdatePadAcceleration({accel[0], accel[1], accel[2]});
    vr.UpdatePadGyro({gyro[0], gyro[1], gyro[2]});
    controller->Gyro(0);
    controller->Acceleration(0);
    // Without a rate the pad library never works out how the controller is turned.
    if (controller->accel_poll_rate == 0.0f) {
        controller->accel_poll_rate = 60.0f;
    }
    if (controller->gyro_poll_rate == 0.0f) {
        controller->gyro_poll_rate = 60.0f;
    }
}

void astro_core_pad_position(const float position[3], const float velocity[3]) {
    if (position == nullptr || velocity == nullptr) {
        return;
    }
    Core::Vr::Runtime::Instance().UpdatePadPosition({position[0], position[1], position[2]},
                                                    {velocity[0], velocity[1], velocity[2]});
}

void astro_core_pad_yaw_reference(float yaw) {
    Core::Vr::Runtime::Instance().UpdatePadYawReference(yaw);
}

void astro_core_pad_lost(void) {
    Core::Vr::Runtime::Instance().ClearPadPosition();
}

bool astro_core_pad_feedback(AstroPadFeedback* feedback) {
    std::scoped_lock lock{g_feedback_mutex};
    if (feedback != nullptr) {
        *feedback = g_feedback;
    }
    return std::exchange(g_feedback_changed, false);
}

} // extern "C"
