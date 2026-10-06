// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

// The emulator as the Apple Vision Pro app sees it: a C interface, so that the Swift app (which
// owns the headset through Compositor Services and ARKit, and the controller through
// GameController) can drive the core the way the Quest app drives its child process
// (quest-host) and the PC build drives itself through OpenXR (core/vr/openxr_host.cpp).
//
// Everything here may be called from any thread unless said otherwise. Spaces and units are
// those of core/vr/vr_protocol.h: metres, +X right, +Y up, -Z forward, in the space ARKit's world
// tracking reports the device in.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// --- executable memory -----------------------------------------------------------------------

/// Whether a debugger is (or was) attached to this process, which is what lets it have memory it
/// can execute code from (CS_DEBUGGED).
bool astro_jit_process_is_debugged(void);

/// Asks the attached debugger (StikDebug, running its universal.js script) for `size` bytes of
/// memory that can be executed, maps the same pages a second time for writing, and lets the
/// debugger go. Only to be called once the process is debugged. Returns 0, or an errno value.
int astro_jit_prepare_arena(size_t size);

typedef struct AstroJitArena {
    uintptr_t rx;   ///< Where the code runs from.
    uintptr_t rw;   ///< The same pages, for writing the code.
    size_t size;
} AstroJitArena;

/// The memory astro_jit_prepare_arena obtained; false while there is none.
bool astro_jit_get_arena(AstroJitArena* arena);

/// Writes a function that returns 42 into the arena and calls it. Returns 0 when the call came
/// back with 42, otherwise an errno value. (A process whose memory is not executable after all is
/// killed by the system here, so the app notes that it is about to try first.)
int astro_jit_self_test(void);

// --- the launcher's check --------------------------------------------------------------------

/// The entitlements this copy of the app is signed with (an XML property list) into `buffer`.
/// Returns its length, or -1.
int astro_diag_entitlements(void* buffer, uint32_t capacity);

/// How many more bytes the system lets this process use before it ends it (the memory limit
/// that com.apple.developer.kernel.increased-memory-limit raises).
uint64_t astro_diag_available_memory(void);

/// The largest single stretch of address space this process can reserve, in GB, trying from
/// `up_to_gb` down (com.apple.developer.kernel.extended-virtual-addressing raises it).
uint32_t astro_diag_largest_reservation_gb(uint32_t up_to_gb);

// --- the emulator ----------------------------------------------------------------------------

typedef enum AstroCoreState {
    AstroCoreStateIdle = 0,
    AstroCoreStateStarting = 1,
    AstroCoreStateRunning = 2,
    AstroCoreStateStopped = 3,
} AstroCoreState;

/// Starts the emulator on a thread of its own with the game at `game_path` (the folder with
/// eboot.bin in it, or eboot.bin itself). `environment` holds `count` "NAME=value" strings set
/// before it starts: the settings the PC launcher passes (pc-vr/launch.ps1). The emulator keeps
/// its data (saves, logs, shader cache) in Library/Application Support/shadPS4 of the app.
/// To be called on the main thread. Returns 0, or an errno value.
int astro_core_start(const char* game_path, const char* const* environment, int count);
AstroCoreState astro_core_state(void);
/// The emulator's exit code once it has stopped.
int astro_core_exit_code(void);

// --- the headset -----------------------------------------------------------------------------

typedef struct AstroPose {
    float position[3];
    float orientation[4]; ///< x, y, z, w
    float linear_velocity[3];
    float angular_velocity[3];
} AstroPose;

/// The immersive space is open and frames are wanted (or not any more).
void astro_core_set_session_running(bool running);
/// Somebody looks at the game: the space is in front of everything else on the headset. The
/// game waits while nobody does (SHADPS4_XR_PAUSE=0 keeps it going regardless).
void astro_core_set_showing(bool showing);
/// The host is about to make the picture for the next refresh of the display, which refreshes
/// `rate` times a second. The emulated headset refreshes in step with these.
void astro_core_display_refresh(float rate);
/// Where the head will be when the next frame is shown (`tracked` false: not known now).
void astro_core_update_head(const AstroPose* pose, bool tracked);
/// The distance between the eyes in metres, as the headset measures it.
void astro_core_update_ipd(float ipd);
/// What the headset shows of the world, both eyes together: tangents of the half angles to the
/// temple, to the nose, up and down.
void astro_core_note_headset_fov(float tan_out, float tan_in, float tan_up, float tan_down);
/// The player asks for the view to be reset (the headset's own recentre).
void astro_core_request_recenter(void);

// --- the frames ------------------------------------------------------------------------------

typedef struct AstroFrame {
    uint32_t slot;          ///< To hand back with astro_core_release_frame.
    uint32_t frame_id;
    void* texture;          ///< id<MTLTexture>, both eyes side by side, not retained.
    uint32_t width;         ///< Of the whole texture.
    uint32_t height;
    uint32_t eye_width;     ///< What the game drew each eye at, before it was scaled into it.
    uint32_t eye_height;
    float position[3];      ///< The head pose the game drew the frame for.
    float orientation[4];
    float tan_out;          ///< The field of view it drew each eye with.
    float tan_in;
    float tan_up;
    float tan_down;
    float ipd;
} AstroFrame;

/// The newest frame the game finished that has not been taken yet. It stays the host's until
/// astro_core_release_frame. Returns false when there is none.
bool astro_core_take_frame(AstroFrame* frame);
/// The GPU is done reading the frame in `slot`.
void astro_core_release_frame(uint32_t slot);
/// How many frames the game delivered so far.
uint32_t astro_core_frames_delivered(void);

// --- the controller --------------------------------------------------------------------------

/// The buttons, in the bits of the PlayStation 4's pad library (OrbisPadButtonDataOffset).
typedef enum AstroPadButton : uint32_t {
    AstroPadL3 = 0x2,
    AstroPadR3 = 0x4,
    AstroPadOptions = 0x8,
    AstroPadUp = 0x10,
    AstroPadRight = 0x20,
    AstroPadDown = 0x40,
    AstroPadLeft = 0x80,
    AstroPadL2 = 0x100,
    AstroPadR2 = 0x200,
    AstroPadL1 = 0x400,
    AstroPadR1 = 0x800,
    AstroPadTriangle = 0x1000,
    AstroPadCircle = 0x2000,
    AstroPadCross = 0x4000,
    AstroPadSquare = 0x8000,
    AstroPadTouchPad = 0x100000,
} AstroPadButton;

typedef struct AstroPadState {
    uint32_t buttons;
    /// Sticks 0 to 255, 128 in the middle, 0 left and up as on the PlayStation 4.
    uint8_t left_x, left_y, right_x, right_y;
    /// Triggers 0 to 255.
    uint8_t left_trigger, right_trigger;
    bool touch_down;
    /// Where the finger is on the touchpad, 0 to 1 from the left and from the top.
    float touch_x, touch_y;
    /// Whether the PS button is down (it is not one of the game's buttons: it resets the view).
    bool home;
} AstroPadState;

/// A controller is connected (true) or the last one went away (false). `name` is shown in the log.
void astro_core_pad_connected(bool connected, const char* name);
void astro_core_pad_state(const AstroPadState* state);
/// The controller's motion sensors in its own frame (+X right, +Y out of the face buttons, +Z
/// towards the player): rad/s and m/s² with gravity included, as SDL reports them.
void astro_core_pad_motion(const float gyro[3], const float accel[3]);
/// Where the hands holding the controller put it, in head-tracking space, and how fast it moves.
void astro_core_pad_position(const float position[3], const float velocity[3]);
/// The controller's heading as the hands give it away: 0 straight ahead, positive to the left.
void astro_core_pad_yaw_reference(float yaw);
/// Nothing sees the controller any more.
void astro_core_pad_lost(void);

typedef struct AstroPadFeedback {
    uint8_t small_motor; ///< 0 to 255
    uint8_t large_motor;
    uint8_t red, green, blue;
} AstroPadFeedback;

/// What the game last asked of the controller's motors and light. Returns true when that changed
/// since the last call.
bool astro_core_pad_feedback(AstroPadFeedback* feedback);

// --- settings shown to the player ---------------------------------------------------------------

/// The core's log file, for the app to show where it is.
const char* astro_core_log_path(void);

#ifdef __cplusplus
}
#endif
