// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

// The ARM64 registers of a signal's context (ucontext_t), on Linux and on Apple systems, where
// uc_mcontext is a pointer and the registers have other names. HOST_CONTEXT_REGS gives x0..x30
// as one array on both (Darwin's __x[29], __fp and __lr follow each other).

#include <cstdint>
#include <unistd.h>
#if defined(__APPLE__)
#include <pthread.h>
#include <sys/ucontext.h>
#else
#include <ucontext.h>
#endif

#if defined(__aarch64__)
#if defined(__APPLE__)
#define HOST_CONTEXT_PC(context) ((context)->uc_mcontext->__ss.__pc)
#define HOST_CONTEXT_SP(context) ((context)->uc_mcontext->__ss.__sp)
#define HOST_CONTEXT_REGS(context)                                                                 \
    (reinterpret_cast<std::uint64_t*>(&(context)->uc_mcontext->__ss.__x[0]))
#else
#define HOST_CONTEXT_PC(context) ((context)->uc_mcontext.pc)
#define HOST_CONTEXT_SP(context) ((context)->uc_mcontext.sp)
#define HOST_CONTEXT_REGS(context) (reinterpret_cast<std::uint64_t*>((context)->uc_mcontext.regs))
#endif
#endif

namespace Common {

/// The calling thread's id as the system numbers threads (gettid on Linux).
inline int HostThreadId() {
#if defined(__APPLE__)
    std::uint64_t id = 0;
    pthread_threadid_np(nullptr, &id);
    return static_cast<int>(id);
#else
    return static_cast<int>(gettid());
#endif
}

} // namespace Common
