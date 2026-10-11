// SPDX-FileCopyrightText: Copyright 2025 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "common/assert.h"
#include "common/logging/log.h"
#include "core/libraries/error_codes.h"
#include "core/libraries/hmd/hmd_setup_dialog.h"
#include "core/libraries/libs.h"
#include "core/vr/vr_runtime.h"

namespace Libraries::HmdSetupDialog {

s32 PS4_SYSV_ABI sceHmdSetupDialogInitialize() {
    LOG_ERROR(Lib_HmdSetupDialog, "(STUBBED) called");
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdSetupDialogClose() {
    LOG_ERROR(Lib_HmdSetupDialog, "(STUBBED) called");
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdSetupDialogOpen(const OrbisHmdSetupDialogParam* param) {
    LOG_ERROR(Lib_HmdSetupDialog, "(STUBBED) called");
    // On real hardware, a dialog would show up telling the user to connect a PSVR headset.
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceHmdSetupDialogGetResult(OrbisHmdSetupDialogResult* result) {
    LOG_DEBUG(Lib_HmdSetupDialog, "called");
    // Result::OK means a headset was connected. Without one, simulate the user pressing circle
    // to cancel the dialog.
    result->result = Core::Vr::Runtime::Instance().IsHeadsetConnected()
                         ? Libraries::CommonDialog::Result::OK
                         : Libraries::CommonDialog::Result::USER_CANCELED;
    return ORBIS_OK;
}

Libraries::CommonDialog::Status PS4_SYSV_ABI sceHmdSetupDialogUpdateStatus() {
    LOG_ERROR(Lib_HmdSetupDialog, "(STUBBED) called");
    return Libraries::CommonDialog::Status::FINISHED;
}

Libraries::CommonDialog::Status PS4_SYSV_ABI sceHmdSetupDialogGetStatus() {
    LOG_ERROR(Lib_HmdSetupDialog, "(STUBBED) called");
    return Libraries::CommonDialog::Status::FINISHED;
}

s32 PS4_SYSV_ABI sceHmdSetupDialogTerminate() {
    LOG_ERROR(Lib_HmdSetupDialog, "(STUBBED) called");
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
    LOG_INFO(Lib_HmdSetupDialog, "sceVrServiceDialogInitialize");
    return ORBIS_OK;
}
s32 PS4_SYSV_ABI Open(const void*) {
    LOG_INFO(Lib_HmdSetupDialog, "sceVrServiceDialogOpen: finished at once (headset on)");
    return ORBIS_OK;
}
Libraries::CommonDialog::Status PS4_SYSV_ABI UpdateStatus() {
    return Libraries::CommonDialog::Status::FINISHED;
}
Libraries::CommonDialog::Status PS4_SYSV_ABI GetStatus() {
    return Libraries::CommonDialog::Status::FINISHED;
}
s32 PS4_SYSV_ABI GetResult(Result* result) {
    if (result != nullptr) {
        result->result = Libraries::CommonDialog::Result::OK;
    }
    return ORBIS_OK;
}
s32 PS4_SYSV_ABI Close() {
    return ORBIS_OK;
}
s32 PS4_SYSV_ABI Terminate() {
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