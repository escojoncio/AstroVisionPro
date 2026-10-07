// SPDX-FileCopyrightText: Copyright 2024-2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <cstring>
#include "common/arch.h"
#include "common/assert.h"
#include "common/crash_reporter.h"
#include "common/decoder.h"
#include "common/signal_context.h"
#include "core/libraries/kernel/threads/exception.h"
#include "core/signals.h"
#ifdef SHADPS4_ENABLE_FEX_GUEST_CPU
#include "core/fex/fex_guest_engine.h"
#endif
#include "emulator.h"
#if defined(SHADPS4_VISIONOS)
#include <atomic>
#include <cstdio>
#include <dlfcn.h>
#include <mach/mach.h>
#include <sys/mman.h>
#include <sys/ucontext.h>
#include "common/jit_arena.h"
#endif

#ifdef _WIN32
#include <windows.h>
static constexpr DWORD MS_VC_EXCEPTION = 0x406D1388;
#else
#include <csignal>
#include <pthread.h>
#include <unistd.h>
#ifdef ARCH_X86_64
#include <Zydis/Formatter.h>
#endif
#endif

#ifndef _WIN32
namespace Libraries::Kernel {
void SigactionHandler(int native_signum, siginfo_t* inf, ucontext_t* raw_context);
extern std::array<OrbisKernelExceptionHandler, 32> Handlers;
} // namespace Libraries::Kernel
#endif

namespace Core {

#if defined(_WIN32)

static LONG WINAPI SignalHandler(EXCEPTION_POINTERS* pExp) noexcept {
    const auto* signals = Signals::Instance();
    DWORD code = 0;
    PVOID address = nullptr;

    if (pExp != nullptr && pExp->ExceptionRecord != nullptr) {
        code = pExp->ExceptionRecord->ExceptionCode;
        address = pExp->ExceptionRecord->ExceptionAddress;
    }

    bool handled = false;
    switch (code) {
    case EXCEPTION_ACCESS_VIOLATION:
        handled = signals->DispatchAccessViolation(
            pExp, reinterpret_cast<void*>(pExp->ExceptionRecord->ExceptionInformation[1]));
        break;
    case EXCEPTION_ILLEGAL_INSTRUCTION:
        handled = signals->DispatchIllegalInstruction(pExp);
        break;
    case DBG_PRINTEXCEPTION_C:
    case DBG_PRINTEXCEPTION_WIDE_C:
        // Used by OutputDebugString functions.
        return EXCEPTION_CONTINUE_EXECUTION;
    case MS_VC_EXCEPTION:
        LOG_DEBUG(Debug, "Pass MS_VC_EXCEPTION at {} to handler", address);
        return EXCEPTION_EXECUTE_HANDLER;
    default:
        break;
    }

    if (handled) {
        return EXCEPTION_CONTINUE_EXECUTION;
    }

    // Breakpoints almost certainly come from our asserts/unreachables, no need to log it again.
    if (code != EXCEPTION_BREAKPOINT) {
        LOG_CRITICAL(Debug, "Unhandled Exception code {:#x} at {}", code, address);
        // Where it came from: each caller as its module and the place in it.
        void* frames[32];
        const USHORT count = CaptureStackBackTrace(0, 32, frames, nullptr);
        for (USHORT i = 0; i < count; ++i) {
            HMODULE module = nullptr;
            char name[MAX_PATH] = "?";
            if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                                       GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                   static_cast<LPCSTR>(frames[i]), &module)) {
                GetModuleFileNameA(module, name, sizeof(name));
            }
            const char* file = std::strrchr(name, '\\');
            LOG_CRITICAL(Debug, "  {} + {:#x}", file ? file + 1 : name,
                         reinterpret_cast<uintptr_t>(frames[i]) -
                             reinterpret_cast<uintptr_t>(module));
        }
        Common::Singleton<Core::Emulator>::Instance()->Shutdown();
    }

    return EXCEPTION_CONTINUE_SEARCH;
}

#else

static std::string DisassembleInstruction(void* code_address) {
    char buffer[256] = "<unable to decode>";

#ifdef ARCH_X86_64
    ZydisDecodedInstruction instruction;
    ZydisDecodedOperand operands[ZYDIS_MAX_OPERAND_COUNT];
    const auto status =
        Common::Decoder::Instance()->decodeInstruction(instruction, operands, code_address);
    if (ZYAN_SUCCESS(status)) {
        ZydisFormatter formatter;
        ZydisFormatterInit(&formatter, ZYDIS_FORMATTER_STYLE_INTEL);
        ZydisFormatterFormatInstruction(&formatter, &instruction, operands,
                                        instruction.operand_count_visible, buffer, sizeof(buffer),
                                        reinterpret_cast<u64>(code_address), ZYAN_NULL);
    }
#endif

    return buffer;
}

#ifdef SHADPS4_ENABLE_FEX_GUEST_CPU
/// Reads a word of guest memory that may not be mapped. The kernel does the copy, so a bad
/// address is an error return rather than a second fault inside the fault handler.
static bool ReadGuestWord(u64 address, u64* value) {
    static int pipe_ends[2] = {-1, -1};
    if (pipe_ends[0] < 0 && pipe(pipe_ends) != 0) {
        return false;
    }
    if (write(pipe_ends[1], reinterpret_cast<const void*>(address), sizeof(*value)) !=
        static_cast<ssize_t>(sizeof(*value))) {
        return false;
    }
    return read(pipe_ends[0], value, sizeof(*value)) == static_cast<ssize_t>(sizeof(*value));
}

/// The return addresses up the guest's call stack, found through its frame pointers.
static std::string GuestCallers(u64 frame) {
    std::string callers;
    for (int depth = 0; depth < 24 && frame != 0 && (frame & 7) == 0; ++depth) {
        u64 next = 0;
        u64 return_address = 0;
        if (!ReadGuestWord(frame, &next) || !ReadGuestWord(frame + 8, &return_address)) {
            break;
        }
        callers += fmt::format(" {:#x}", return_address);
        if (next <= frame) {
            break;
        }
        frame = next;
    }
    return callers;
}
#endif

#if defined(SHADPS4_VISIONOS)
// Where a crash happened, for the console log: the registers, which image (or the JIT arena) the
// code belongs to, and the instructions there. visionOS keeps none of this for us.
static void DescribeAddress(const char* what, uint64_t address) {
    const auto [arena_begin, arena_end] = Common::JitArena::Range();
    if (address >= arena_begin && address < arena_end) {
        fprintf(stderr, "ASTRO_CRASH %s=%#llx in JIT arena +%#llx\n", what,
                static_cast<unsigned long long>(address),
                static_cast<unsigned long long>(address - arena_begin));
        return;
    }
    Dl_info image{};
    if (dladdr(reinterpret_cast<void*>(address), &image) != 0 && image.dli_fname != nullptr) {
        const char* slash = strrchr(image.dli_fname, '/');
        fprintf(stderr, "ASTRO_CRASH %s=%#llx in %s +%#llx (%s)\n", what,
                static_cast<unsigned long long>(address), slash ? slash + 1 : image.dli_fname,
                static_cast<unsigned long long>(address -
                                                reinterpret_cast<uint64_t>(image.dli_fbase)),
                image.dli_sname ? image.dli_sname : "?");
        return;
    }
    fprintf(stderr, "ASTRO_CRASH %s=%#llx (no image)\n", what,
            static_cast<unsigned long long>(address));
}

static void DescribeCrash(int sig, siginfo_t* info, void* raw_context) {
    const auto* context = static_cast<ucontext_t*>(raw_context);
    const auto& state = context->uc_mcontext->__ss;
    const auto& exception = context->uc_mcontext->__es;
    const auto [arena_begin, arena_end] = Common::JitArena::Range();
    fprintf(stderr, "ASTRO_CRASH signal=%d code=%d addr=%p esr=%#x far=%#llx arena=%#llx-%#llx\n",
            sig, info->si_code, info->si_addr, exception.__esr,
            static_cast<unsigned long long>(exception.__far),
            static_cast<unsigned long long>(arena_begin), static_cast<unsigned long long>(arena_end));
    DescribeAddress("pc", state.__pc);
    DescribeAddress("lr", state.__lr);
    for (int i = 0; i < 29; i += 4) {
        fprintf(stderr, "ASTRO_CRASH");
        for (int j = i; j < i + 4 && j < 29; ++j) {
            fprintf(stderr, " x%d=%#llx", j, static_cast<unsigned long long>(state.__x[j]));
        }
        fprintf(stderr, "\n");
    }
    fprintf(stderr, "ASTRO_CRASH fp=%#llx sp=%#llx\n", static_cast<unsigned long long>(state.__fp),
            static_cast<unsigned long long>(state.__sp));
    const auto* code = reinterpret_cast<const uint32_t*>(state.__pc & ~uint64_t{3});
    fprintf(stderr, "ASTRO_CRASH code at pc-16..pc+12: %08x %08x %08x %08x [%08x] %08x %08x %08x\n",
            code[-4], code[-3], code[-2], code[-1], code[0], code[1], code[2], code[3]);
    // A few return addresses up the frame chain.
    uint64_t frame = state.__fp;
    for (int depth = 0; depth < 8 && frame != 0 && (frame & 7) == 0; ++depth) {
        const auto* pair = reinterpret_cast<const uint64_t*>(frame);
        char what[16];
        snprintf(what, sizeof(what), "frame%d", depth);
        DescribeAddress(what, pair[1]);
        if (pair[0] <= frame) break;
        frame = pair[0];
    }
    fflush(stderr);
}
#endif

#if defined(SHADPS4_VISIONOS)
/// A fault that a handler "resolves" without changing anything comes straight back: the thread
/// then spends its time faulting on one address and the title hangs without a word. After many
/// faults in a row on the same address this says what the page looks like (the first few times)
/// and opens it up so the thread can go on.
static bool BreakFaultLoop(int sig, siginfo_t* info, void* raw_context) {
    constexpr uint32_t LoopFaults = 2000;
    thread_local uintptr_t last_address = 0;
    thread_local uint32_t repeats = 0;
    const auto address = reinterpret_cast<uintptr_t>(info->si_addr);
    if (address != last_address) {
        last_address = address;
        repeats = 0;
        return false;
    }
    if (++repeats < LoopFaults) {
        return false;
    }
    repeats = 0;
    static std::atomic<uint32_t> reports{0};
    const bool report = reports.fetch_add(1, std::memory_order_relaxed) < 16;

    constexpr uintptr_t HostPage = 0x4000;
    const uintptr_t page = address & ~(HostPage - 1);
    vm_address_t region = page;
    vm_size_t region_size = 0;
    vm_region_basic_info_data_64_t region_info{};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    const kern_return_t kr =
        vm_region_64(mach_task_self(), &region, &region_size, VM_REGION_BASIC_INFO_64,
                     reinterpret_cast<vm_region_info_t>(&region_info), &count, &object);
    const auto* context = static_cast<const ucontext_t*>(raw_context);
    if (report) {
    fprintf(stderr,
            "ASTRO_FAULT_LOOP signal=%d code=%d addr=%#lx write=%d esr=%#x pc=%#llx lr=%#llx "
            "region=%#lx+%#lx (kr %d) protection=%d max=%d\n",
            sig, info->si_code, static_cast<unsigned long>(address),
            Common::IsWriteError(raw_context) ? 1 : 0, context->uc_mcontext->__es.__esr,
            static_cast<unsigned long long>(context->uc_mcontext->__ss.__pc),
            static_cast<unsigned long long>(context->uc_mcontext->__ss.__lr),
            static_cast<unsigned long>(region), static_cast<unsigned long>(region_size), kr,
            region_info.protection, region_info.max_protection);
    DescribeAddress("pc", context->uc_mcontext->__ss.__pc);
    DescribeAddress("lr", context->uc_mcontext->__ss.__lr);
    fflush(stderr);
    }
    if (mprotect(reinterpret_cast<void*>(page), HostPage, PROT_READ | PROT_WRITE) != 0) {
        fprintf(stderr, "ASTRO_FAULT_LOOP could not open the page: %s\n", strerror(errno));
        fflush(stderr);
        return false;
    }
    return true;
}
#endif

void SignalHandler(int sig, siginfo_t* info, void* raw_context) {
    Common::ReportCrash(raw_context, sig, info);
    const auto* signals = Signals::Instance();

    auto* code_address = Common::GetRip(raw_context);

    switch (sig) {
    case SIGBUS:
    case SIGSEGV: {
#if defined(SHADPS4_VISIONOS)
        if (BreakFaultLoop(sig, info, raw_context)) {
            return;
        }
#endif
#ifdef SHADPS4_ENABLE_FEX_GUEST_CPU
        if (sig == SIGBUS && ::Core::Fex::HandleGuestSignal(sig, info, raw_context)) {
            return;
        }
#endif
        const bool is_write = Common::IsWriteError(raw_context);
        if (!signals->DispatchAccessViolation(raw_context, info->si_addr)) {
            // If the guest has installed a custom signal handler, and the access violation didn't
            // come from HLE memory tracking, pass the signal on
            if (Libraries::Kernel::Handlers[Libraries::Kernel::NativeToOrbisSignal(sig)]) {
                Libraries::Kernel::SigactionHandler(sig, info,
                                                    reinterpret_cast<ucontext_t*>(raw_context));
                return;
            }
#ifdef SHADPS4_ENABLE_FEX_GUEST_CPU
            uint64_t guest_rip = 0;
            uint64_t guest_rax = 0;
            if (::Core::Fex::BachataQueryGuestRipSyscall(&guest_rip, &guest_rax)) {
                LOG_CRITICAL(Debug, "FEX guest state at fault: rip={:#x} rax={:#x}", guest_rip,
                             guest_rax);
            }
            // When the fault is inside an HLE function this tells which call it was: the first
            // arguments, and who made it.
            uint64_t gprs[16]{};
            if (::Core::Fex::BachataQueryGuestRegisters(gprs)) {
                const uint64_t rsp = gprs[4];
                uint64_t return_address = 0;
                if ((rsp & 7) == 0) {
                    ReadGuestWord(rsp, &return_address);
                }
                LOG_CRITICAL(Debug,
                             "FEX guest registers: rdi={:#x} rsi={:#x} rdx={:#x} rcx={:#x} "
                             "rsp={:#x} return address={:#x}",
                             gprs[7], gprs[6], gprs[2], gprs[1], rsp, return_address);
                LOG_CRITICAL(Debug, "FEX guest callers:{}", GuestCallers(gprs[5]));
            }
#endif
#if defined(SHADPS4_VISIONOS)
            DescribeCrash(sig, info, raw_context);
#endif
            UNREACHABLE_MSG("Unhandled access violation at code address {}: {} address {}",
                            fmt::ptr(code_address), is_write ? "Write to" : "Read from",
                            fmt::ptr(info->si_addr));
        }
        break;
    }
    case SIGILL:
        if (!signals->DispatchIllegalInstruction(raw_context)) {
            if (Libraries::Kernel::Handlers[Libraries::Kernel::NativeToOrbisSignal(sig)]) {
                Libraries::Kernel::SigactionHandler(sig, info,
                                                    reinterpret_cast<ucontext_t*>(raw_context));
                return;
            }
            UNREACHABLE_MSG("Unhandled illegal instruction at code address {}: {}",
                            fmt::ptr(code_address), DisassembleInstruction(code_address));
        }
        break;
    default:
        if (sig == SIGSLEEP) {
            // Sleep thread until signal is received again
            sigset_t sigset;
            sigemptyset(&sigset);
            sigaddset(&sigset, SIGSLEEP);
            sigwait(&sigset, &sig);
        }
        break;
    }
}

#endif

SignalDispatch::SignalDispatch() {
    Common::InitCrashReporter();
#if defined(_WIN32)
    ASSERT_MSG(handle = AddVectoredExceptionHandler(0, SignalHandler),
               "Failed to register exception handler.");
#else
    struct sigaction action{};
    action.sa_sigaction = SignalHandler;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&action.sa_mask);

    ASSERT_MSG(sigaction(SIGSEGV, &action, nullptr) == 0 &&
                   sigaction(SIGBUS, &action, nullptr) == 0,
               "Failed to register access violation signal handler.");
    ASSERT_MSG(sigaction(SIGILL, &action, nullptr) == 0,
               "Failed to register illegal instruction signal handler.");
    ASSERT_MSG(sigaction(SIGSLEEP, &action, nullptr) == 0,
               "Failed to register sleep signal handler.");
#endif
}

SignalDispatch::~SignalDispatch() {
#if defined(_WIN32)
    ASSERT_MSG(RemoveVectoredExceptionHandler(handle), "Failed to remove exception handler.");
#else
    struct sigaction action{};
    action.sa_handler = SIG_DFL;
    action.sa_flags = 0;
    sigemptyset(&action.sa_mask);

    ASSERT_MSG(sigaction(SIGSEGV, &action, nullptr) == 0 &&
                   sigaction(SIGBUS, &action, nullptr) == 0,
               "Failed to remove access violation signal handler.");
    ASSERT_MSG(sigaction(SIGILL, &action, nullptr) == 0,
               "Failed to remove illegal instruction signal handler.");
#endif
}

bool SignalDispatch::DispatchAccessViolation(void* context, void* fault_address) const {
    for (const auto& [handler, _] : access_violation_handlers) {
        if (handler(context, fault_address)) {
            return true;
        }
    }
    return false;
}

bool SignalDispatch::DispatchIllegalInstruction(void* context) const {
    for (const auto& [handler, _] : illegal_instruction_handlers) {
        if (handler(context)) {
            return true;
        }
    }
    return false;
}

} // namespace Core
