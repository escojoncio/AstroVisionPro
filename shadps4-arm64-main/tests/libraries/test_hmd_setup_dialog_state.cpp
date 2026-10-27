// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <gtest/gtest.h>

#include "core/libraries/hmd/hmd_setup_dialog_state.h"

namespace {

using Libraries::CommonDialog::Status;
using Libraries::HmdSetupDialog::SetupDialogState;

TEST(HmdSetupDialogState, AsTheAstroBotUsesIt) {
    SetupDialogState state;
    EXPECT_EQ(state.Initialize(), Status::INITIALIZED);
    EXPECT_EQ(state.Open(), Status::RUNNING);
    EXPECT_EQ(state.Poll(), Status::FINISHED);
    EXPECT_EQ(state.Poll(), Status::FINISHED);
    state.Terminate();
    EXPECT_EQ(state.Current(), Status::NONE);
}

TEST(HmdSetupDialogState, WithoutOpenItIsNeverFinished) {
    SetupDialogState state;
    // KITCHEN asks for the status in every frame without having initialized or opened it.
    for (int i = 0; i < 100; ++i) {
        EXPECT_EQ(state.Poll(), Status::NONE);
    }
    state.Initialize();
    for (int i = 0; i < 100; ++i) {
        EXPECT_EQ(state.Poll(), Status::INITIALIZED);
    }
}

TEST(HmdSetupDialogState, TerminateStartsOver) {
    SetupDialogState state;
    state.Initialize();
    state.Open();
    state.Poll();
    state.Terminate();
    EXPECT_EQ(state.Poll(), Status::NONE);
    EXPECT_EQ(state.Initialize(), Status::INITIALIZED);
    EXPECT_EQ(state.Open(), Status::RUNNING);
}

TEST(HmdSetupDialogState, InitializeAgainChangesNothing) {
    SetupDialogState state;
    state.Initialize();
    state.Open();
    EXPECT_EQ(state.Initialize(), Status::RUNNING);
    EXPECT_EQ(state.Poll(), Status::FINISHED);
    EXPECT_EQ(state.Initialize(), Status::FINISHED);
}

} // namespace
