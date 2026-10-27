// SPDX-FileCopyrightText: Copyright 2025 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <atomic>

#include "common/assert.h"
#include "common/logging/log.h"
#include "core/libraries/error_codes.h"
#include "core/libraries/hmd/hmd_setup_dialog.h"
#include "core/libraries/hmd/hmd_setup_dialog_state.h"
#include "core/libraries/libs.h"
#include "core/vr/vr_runtime.h"

namespace Libraries::HmdSetupDialog {

namespace {
SetupDialogState g_state;

/// How many calls of the two dialogs are logged in a session: enough to see how a title uses
/// them, not a line for every frame of a title that asks for the status in each.
constexpr u32 MaxLoggedCalls = 64;
std::atomic<u32> g_logged_calls{0};

bool ShouldLogCall() {
    return g_logged_calls.load(std::memory_order_relaxed) < MaxLoggedCalls &&
           g_logged_calls.fetch_add(1, std::memory_order_relaxed) < MaxLoggedCalls;
}
} // namespace

#define LOG_DIALOG_CALL(...)                                                                       \
    do {                                                                                           \
        if (ShouldLogCall()) {                                                                     \
            LOG_INFO(Lib_HmdSetupDialog, __VA_ARGS__);                                             \
        }                                                                                          \
    } while (false)

s32 PS4_SYSV_ABI sceHmdSetupDialogInitialize() {
    const auto status = g_state.Initialize();
    LOG_DIALOG_CALL("sceHmdSetupDialogInitialize() = {}, status {}", ORBIS_OK,
                    static_cast<u32>(status));
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdSetupDialogClose() {
    LOG_DIALOG_CALL("sceHmdSetupDialogClose() = {}, status {}", ORBIS_OK,
                    static_cast<u32>(g_state.Current()));
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdSetupDialogOpen(const OrbisHmdSetupDialogParam* param) {
    const auto before = g_state.Current();
    const auto status = g_state.Open();
    // On real hardware, a dialog would show up telling the user to connect a PSVR headset.
    if (param != nullptr) {
        LOG_DIALOG_CALL(
            "sceHmdSetupDialogOpen(param={}, size={}, user_id={}, disable_handover_screen={}) = "
            "{}, status {} -> {}",
            fmt::ptr(param), param->size, param->user_id, param->disable_handover_screen, ORBIS_OK,
            static_cast<u32>(before), static_cast<u32>(status));
    } else {
        LOG_DIALOG_CALL("sceHmdSetupDialogOpen(param=null) = {}, status {} -> {}", ORBIS_OK,
                        static_cast<u32>(before), static_cast<u32>(status));
    }
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdSetupDialogGetResult(OrbisHmdSetupDialogResult* result) {
    const auto status = g_state.Current();
    if (status != Libraries::CommonDialog::Status::FINISHED) {
        LOG_DIALOG_CALL("sceHmdSetupDialogGetResult(result={}) = {:#x}: not finished, status {}",
                        fmt::ptr(result), static_cast<u32>(CommonDialog::Error::NOT_FINISHED),
                        static_cast<u32>(status));
        return static_cast<s32>(CommonDialog::Error::NOT_FINISHED);
    }
    // Result::OK means a headset was connected. Without one, simulate the user pressing circle
    // to cancel the dialog.
    result->result = Core::Vr::Runtime::Instance().IsHeadsetConnected()
                         ? Libraries::CommonDialog::Result::OK
                         : Libraries::CommonDialog::Result::USER_CANCELED;
    LOG_DIALOG_CALL("sceHmdSetupDialogGetResult(result={}) = {}, result {}", fmt::ptr(result),
                    ORBIS_OK, static_cast<u32>(result->result));
    return ORBIS_OK;
}

Libraries::CommonDialog::Status PS4_SYSV_ABI sceHmdSetupDialogUpdateStatus() {
    const auto status = g_state.Poll();
    LOG_DIALOG_CALL("sceHmdSetupDialogUpdateStatus() = {}", static_cast<u32>(status));
    return status;
}

Libraries::CommonDialog::Status PS4_SYSV_ABI sceHmdSetupDialogGetStatus() {
    const auto status = g_state.Poll();
    LOG_DIALOG_CALL("sceHmdSetupDialogGetStatus() = {}", static_cast<u32>(status));
    return status;
}

s32 PS4_SYSV_ABI sceHmdSetupDialogTerminate() {
    g_state.Terminate();
    LOG_DIALOG_CALL("sceHmdSetupDialogTerminate() = {}", ORBIS_OK);
    return ORBIS_OK;
}

// libSceVrServiceDialog: the system's PlayStation VR service dialog (put on the headset,
// adjust it, ...). Titles open it and wait for it to finish; with the headset already on, it
// finishes at once with OK. Without these, an unresolved UpdateStatus returned 0 (NONE): a
// title waiting for FINISHED never went on (CUSA06799, KITCHEN).
namespace VrServiceDialog {
struct Result {
    Libraries::CommonDialog::Result result;
    u8 reserved[32];
};

s32 PS4_SYSV_ABI Initialize() {
    LOG_DIALOG_CALL("sceVrServiceDialogInitialize() = {}", ORBIS_OK);
    return ORBIS_OK;
}
s32 PS4_SYSV_ABI Open(const void* param) {
    LOG_DIALOG_CALL("sceVrServiceDialogOpen(param={}) = {}: finished at once (headset on)",
                    fmt::ptr(param), ORBIS_OK);
    return ORBIS_OK;
}
Libraries::CommonDialog::Status PS4_SYSV_ABI UpdateStatus() {
    const auto status = Libraries::CommonDialog::Status::FINISHED;
    LOG_DIALOG_CALL("sceVrServiceDialogUpdateStatus() = {}", static_cast<u32>(status));
    return status;
}
Libraries::CommonDialog::Status PS4_SYSV_ABI GetStatus() {
    const auto status = Libraries::CommonDialog::Status::FINISHED;
    LOG_DIALOG_CALL("sceVrServiceDialogGetStatus() = {}", static_cast<u32>(status));
    return status;
}
s32 PS4_SYSV_ABI GetResult(Result* result) {
    if (result != nullptr) {
        result->result = Libraries::CommonDialog::Result::OK;
    }
    LOG_DIALOG_CALL("sceVrServiceDialogGetResult(result={}) = {}, result {}", fmt::ptr(result),
                    ORBIS_OK, static_cast<u32>(Libraries::CommonDialog::Result::OK));
    return ORBIS_OK;
}
s32 PS4_SYSV_ABI Close() {
    LOG_DIALOG_CALL("sceVrServiceDialogClose() = {}", ORBIS_OK);
    return ORBIS_OK;
}
s32 PS4_SYSV_ABI Terminate() {
    LOG_DIALOG_CALL("sceVrServiceDialogTerminate() = {}", ORBIS_OK);
    return ORBIS_OK;
}
} // namespace VrServiceDialog

void RegisterLib(Core::Loader::SymbolsResolver* sym) {
    LIB_FUNCTION("hYFXG8FWThI", "libSceVrServiceDialog", 1, "libSceVrServiceDialog",
                 VrServiceDialog::Initialize);
    LIB_FUNCTION("60-cjn5Dn0Q", "libSceVrServiceDialog", 1, "libSceVrServiceDialog",
                 VrServiceDialog::Open);
    LIB_FUNCTION("RmRtBJpoHlA", "libSceVrServiceDialog", 1, "libSceVrServiceDialog",
                 VrServiceDialog::UpdateStatus);
    LIB_FUNCTION("kUavKmsczkY", "libSceVrServiceDialog", 1, "libSceVrServiceDialog",
                 VrServiceDialog::GetStatus);
    LIB_FUNCTION("cYnBkgm8I0c", "libSceVrServiceDialog", 1, "libSceVrServiceDialog",
                 VrServiceDialog::GetResult);
    LIB_FUNCTION("hBH2ABP7IeY", "libSceVrServiceDialog", 1, "libSceVrServiceDialog",
                 VrServiceDialog::Close);
    LIB_FUNCTION("M4xKWUytNMo", "libSceVrServiceDialog", 1, "libSceVrServiceDialog",
                 VrServiceDialog::Terminate);
    LIB_FUNCTION("nmHzU4Gh0xs", "libSceHmdSetupDialog", 1, "libSceHmdSetupDialog",
                 sceHmdSetupDialogClose);
    LIB_FUNCTION("6lVRHMV5LY0", "libSceHmdSetupDialog", 1, "libSceHmdSetupDialog",
                 sceHmdSetupDialogGetResult);
    LIB_FUNCTION("J9eBpW1udl4", "libSceHmdSetupDialog", 1, "libSceHmdSetupDialog",
                 sceHmdSetupDialogGetStatus);
    LIB_FUNCTION("NB1Y2kA2jCY", "libSceHmdSetupDialog", 1, "libSceHmdSetupDialog",
                 sceHmdSetupDialogInitialize);
    LIB_FUNCTION("NNgiV4T+akU", "libSceHmdSetupDialog", 1, "libSceHmdSetupDialog",
                 sceHmdSetupDialogOpen);
    LIB_FUNCTION("+z4OJmFreZc", "libSceHmdSetupDialog", 1, "libSceHmdSetupDialog",
                 sceHmdSetupDialogTerminate);
    LIB_FUNCTION("Ud7j3+RDIBg", "libSceHmdSetupDialog", 1, "libSceHmdSetupDialog",
                 sceHmdSetupDialogUpdateStatus);
};

} // namespace Libraries::HmdSetupDialog