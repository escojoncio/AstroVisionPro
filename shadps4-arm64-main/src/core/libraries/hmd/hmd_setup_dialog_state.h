// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <mutex>

#include "core/libraries/system/commondialog.h"

namespace Libraries::HmdSetupDialog {

/// The state a title sees of the headset setup dialog: NONE until Initialize, INITIALIZED until
/// Open, RUNNING until the first look at the status after Open (the dialog has nothing to show
/// and finishes at once), then FINISHED until Terminate.
class SetupDialogState {
public:
    using Status = Libraries::CommonDialog::Status;

    Status Initialize() {
        std::scoped_lock lock{m_mutex};
        if (m_status == Status::NONE) {
            m_status = Status::INITIALIZED;
        }
        return m_status;
    }

    Status Open() {
        std::scoped_lock lock{m_mutex};
        if (m_status == Status::NONE || m_status == Status::INITIALIZED) {
            m_status = Status::RUNNING;
        }
        return m_status;
    }

    /// UpdateStatus and GetStatus: what the title is told. A dialog that was not opened is not
    /// finished.
    Status Poll() {
        std::scoped_lock lock{m_mutex};
        if (m_status == Status::RUNNING) {
            m_status = Status::FINISHED;
        }
        return m_status;
    }

    Status Current() const {
        std::scoped_lock lock{m_mutex};
        return m_status;
    }

    void Terminate() {
        std::scoped_lock lock{m_mutex};
        m_status = Status::NONE;
    }

private:
    mutable std::mutex m_mutex;
    Status m_status = Status::NONE;
};

} // namespace Libraries::HmdSetupDialog
