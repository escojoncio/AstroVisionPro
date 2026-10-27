// SPDX-FileCopyrightText: Copyright 2024-2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include "common/arch.h"
#include "common/assert.h"
#include "common/crash_reporter.h"
#include "common/decoder.h"
#include "common/logging/log.h"
#include "common/signal_context.h"
#include "core/libraries/kernel/threads/exception.h"
#include "core/signals.h"
#ifdef SHADPS4_ENABLE_FEX_GUEST_CPU
#include "common/singleton.h"
#include "core/fex/fex_guest_engine.h"
#include "core/guest_cpu/guest_watchdog.h"
#include "core/linker.h"
#include "core/module.h"
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

#if defined(SHADPS4_VISIONOS) || defined(SHADPS4_ENABLE_FEX_GUEST_CPU)
/// Writes text to stderr and to the emulator's log file with write() alone. The logger takes locks
/// and allocates, which a signal handler must not do, and its queue may not be written out before
/// the process dies; this is how the crash dump gets into the log.
static void CrashWrite(const char* text, size_t length) {
    static_cast<void>(write(STDERR_FILENO, text, length));
    Common::Log::WriteRaw(text, length);
}

/// Held while this thread writes a dump. A fault inside the dump (a stack that is not readable,
/// say) comes back to the handler on the same thread: it must not start a second dump, which would
/// hide the crash that was being described behind its own.
class DumpGuard final {
public:
    DumpGuard() : entered{!active} {
        active = true;
    }
    ~DumpGuard() {
        if (entered) {
            active = false;
        }
    }
    DumpGuard(const DumpGuard&) = delete;
    DumpGuard& operator=(const DumpGuard&) = delete;

    /// False when this thread was already writing a dump.
    bool Entered() const {
        return entered;
    }

private:
    static thread_local bool active;
    bool entered;
};
thread_local bool DumpGuard::active = false;

/// One line of the crash dump, as handed over by PrintRecentHleCalls.
static void CrashLine(const char* line) {
    CrashWrite(line, strlen(line));
}

static void CrashPrint(const char* format, ...) __attribute__((format(printf, 1, 2)));
static void CrashPrint(const char* format, ...) {
    char text[1024];
    va_list arguments;
    va_start(arguments, format);
    const int length = vsnprintf(text, sizeof(text), format, arguments);
    va_end(arguments);
    if (length > 0) {
        CrashWrite(text, std::min(static_cast<size_t>(length), sizeof(text) - 1));
    }
}
#endif

#ifdef SHADPS4_ENABLE_FEX_GUEST_CPU
/// Reads guest memory that may not be mapped. The kernel does the copy, so a bad address is an
/// error return rather than a second fault inside the fault handler. A range that ends in an
/// unmapped page is copied as far as it goes, and is an error all the same.
static bool ReadGuestBytes(u64 address, void* out, size_t size) {
    static int pipe_ends[2] = {-1, -1};
    if (pipe_ends[0] < 0 && pipe(pipe_ends) != 0) {
        return false;
    }
    const ssize_t written = write(pipe_ends[1], reinterpret_cast<const void*>(address), size);
    if (written <= 0) {
        return false;
    }
    // Whatever the kernel took has to be taken out again, or the next read finds it.
    return read(pipe_ends[0], out, static_cast<size_t>(written)) == written &&
           static_cast<size_t>(written) == size;
}

/// Reads a word of guest memory that may not be mapped.
static bool ReadGuestWord(u64 address, u64* value) {
    return ReadGuestBytes(address, value, sizeof(*value));
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

#ifdef SHADPS4_ENABLE_FEX_GUEST_CPU
/// A guest address as the module that holds it and the place in it (eboot+0x1acd37e).
static std::string GuestModuleOffset(u64 address) {
    const auto* module = Common::Singleton<Linker>::Instance()->FindByAddress(address);
    if (module == nullptr) {
        return "no module";
    }
    return fmt::format("{}+{:#x}", module->file.stem().string(), address - module->GetBaseAddress());
}

/// What the guest was doing: its registers (as they were at the last HLE call, which is where the
/// guest's state is last known), who called, the code around the place the last HLE call returns
/// to, and the last HLE calls of the thread. Every line starts with `tag`. `host_pc` is the host
/// program counter of a fault inside the JIT arena, or 0.
static void DescribeGuest(const char* tag, uint64_t host_pc) {
    uint64_t gprs[16]{};
    if (!::Core::Fex::BachataQueryGuestRegisters(gprs)) {
        CrashPrint("%s guest: no guest thread runs on this host thread\n", tag);
        return;
    }
    uint64_t rip = 0;
    uint64_t rax = 0;
    ::Core::Fex::BachataQueryGuestRipSyscall(&rip, &rax);
    // Not where the thread is: the rip and rax the thread had at its last HLE call, which is what
    // the guest state holds until the next one.
    CrashPrint("%s guest last HLE syscall: rip=%#llx (%s) rax=%#llx\n", tag,
               static_cast<unsigned long long>(rip), GuestModuleOffset(rip).c_str(),
               static_cast<unsigned long long>(rax));
    if (host_pc != 0) {
        uint64_t fault_rip = 0;
        uint64_t block = 0;
        if (::Core::Fex::BachataQueryGuestRipAtHostPc(host_pc, &fault_rip, &block)) {
            CrashPrint("%s guest rip at fault=%#llx (%s) in the block entered at %#llx (%s); "
                       "from FEX's per-block RIP table, so only as exact as that; the last "
                       "spilled rip if the host pc is not in that block\n",
                       tag, static_cast<unsigned long long>(fault_rip),
                       GuestModuleOffset(fault_rip).c_str(),
                       static_cast<unsigned long long>(block), GuestModuleOffset(block).c_str());
        } else {
            CrashPrint("%s guest rip at fault: unknown, this engine cannot map host code to guest "
                       "code\n",
                       tag);
        }
    }
    static constexpr const char* names[16] = {"rax", "rcx", "rdx", "rbx", "rsp", "rbp",
                                              "rsi", "rdi", "r8",  "r9",  "r10", "r11",
                                              "r12", "r13", "r14", "r15"};
    for (int i = 0; i < 16; i += 4) {
        CrashPrint("%s guest %s=%#llx %s=%#llx %s=%#llx %s=%#llx\n", tag, names[i],
                   static_cast<unsigned long long>(gprs[i]), names[i + 1],
                   static_cast<unsigned long long>(gprs[i + 1]), names[i + 2],
                   static_cast<unsigned long long>(gprs[i + 2]), names[i + 3],
                   static_cast<unsigned long long>(gprs[i + 3]));
    }
    CrashPrint("%s guest callers (rbp chain):%s\n", tag, GuestCallers(gprs[5]).c_str());
    // In an HLE call the guest stack pointer is at the address the call returns to.
    uint64_t return_address = 0;
    if ((gprs[4] & 7) != 0 || !ReadGuestWord(gprs[4], &return_address)) {
        CrashPrint("%s guest return address: unreadable at rsp=%#llx\n", tag,
                   static_cast<unsigned long long>(gprs[4]));
    } else {
        CrashPrint("%s guest return address=%#llx (%s), code from -0x40:\n", tag,
                   static_cast<unsigned long long>(return_address),
                   GuestModuleOffset(return_address).c_str());
        for (uint64_t offset = 0; offset < 96; offset += 16) {
            const uint64_t address = return_address - 0x40 + offset;
            uint8_t bytes[16];
            const bool readable = ReadGuestBytes(address, bytes, sizeof(bytes));
            char text[16 * 3 + 1];
            for (int i = 0; i < 16; ++i) {
                if (readable) {
                    snprintf(text + i * 3, 4, "%02x ", bytes[i]);
                } else {
                    snprintf(text + i * 3, 4, "?? ");
                }
            }
            CrashPrint("%s guest code %s: %s\n", tag, GuestModuleOffset(address).c_str(), text);
        }
    }
    char prefix[64];
    snprintf(prefix, sizeof(prefix), "%s guest", tag);
    ::Core::GuestCpu::PrintRecentHleCalls(CrashLine, prefix);
}
#endif

#if defined(SHADPS4_VISIONOS)
// Where a crash happened, for the console log: the registers, which image (or the JIT arena) the
// code belongs to, and the instructions there. visionOS keeps none of this for us.
static void DescribeAddress(const char* what, uint64_t address) {
    const auto [arena_begin, arena_end] = Common::JitArena::Range();
    if (address >= arena_begin && address < arena_end) {
        CrashPrint("ASTRO_CRASH %s=%#llx in JIT arena +%#llx\n", what,
                   static_cast<unsigned long long>(address),
                   static_cast<unsigned long long>(address - arena_begin));
        return;
    }
    // Host code: the image, the offset in it (for atos against the build's symbols) and the
    // nearest symbol dladdr knows, which for a stripped image is the nearest exported one.
    Dl_info image{};
    if (dladdr(reinterpret_cast<void*>(address), &image) != 0 && image.dli_fname != nullptr) {
        const char* slash = strrchr(image.dli_fname, '/');
        const auto image_offset = address - reinterpret_cast<uint64_t>(image.dli_fbase);
        if (image.dli_sname != nullptr) {
            CrashPrint("ASTRO_CRASH %s=%#llx in %s +%#llx (%s+%#llx)\n", what,
                       static_cast<unsigned long long>(address),
                       slash ? slash + 1 : image.dli_fname,
                       static_cast<unsigned long long>(image_offset), image.dli_sname,
                       static_cast<unsigned long long>(address -
                                                       reinterpret_cast<uint64_t>(image.dli_saddr)));
        } else {
            CrashPrint("ASTRO_CRASH %s=%#llx in %s +%#llx (no symbol)\n", what,
                       static_cast<unsigned long long>(address),
                       slash ? slash + 1 : image.dli_fname,
                       static_cast<unsigned long long>(image_offset));
        }
        return;
    }
    CrashPrint("ASTRO_CRASH %s=%#llx (no image)\n", what, static_cast<unsigned long long>(address));
}

static void DescribeCrash(int sig, siginfo_t* info, void* raw_context) {
    const DumpGuard guard;
    if (!guard.Entered()) {
        CrashPrint("ASTRO_CRASH signal=%d: a fault while describing a crash; the first dump stands\n",
                   sig);
        return;
    }
    const auto* context = static_cast<ucontext_t*>(raw_context);
    const auto& state = context->uc_mcontext->__ss;
    const auto& exception = context->uc_mcontext->__es;
    const auto [arena_begin, arena_end] = Common::JitArena::Range();
    CrashPrint("ASTRO_CRASH signal=%d code=%d addr=%p esr=%#x far=%#llx arena=%#llx-%#llx\n", sig,
               info->si_code, info->si_addr, exception.__esr,
               static_cast<unsigned long long>(exception.__far),
               static_cast<unsigned long long>(arena_begin),
               static_cast<unsigned long long>(arena_end));
    DescribeAddress("pc", state.__pc);
    DescribeAddress("lr", state.__lr);
    for (int i = 0; i < 29; i += 4) {
        char registers[160];
        int length = snprintf(registers, sizeof(registers), "ASTRO_CRASH");
        for (int j = i; j < i + 4 && j < 29; ++j) {
            length += snprintf(registers + length, sizeof(registers) - length, " x%d=%#llx", j,
                               static_cast<unsigned long long>(state.__x[j]));
        }
        CrashPrint("%s\n", registers);
    }
    CrashPrint("ASTRO_CRASH fp=%#llx sp=%#llx\n", static_cast<unsigned long long>(state.__fp),
               static_cast<unsigned long long>(state.__sp));
    const auto* code = reinterpret_cast<const uint32_t*>(state.__pc & ~uint64_t{3});
    CrashPrint("ASTRO_CRASH code at pc-16..pc+12: %08x %08x %08x %08x [%08x] %08x %08x %08x\n",
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
    const bool pc_in_arena = state.__pc >= arena_begin && state.__pc < arena_end;
    if (!pc_in_arena) {
        CrashPrint("ASTRO_CRASH guest rip at fault: none, the fault is in host code (pc above)\n");
    }
#ifdef SHADPS4_ENABLE_FEX_GUEST_CPU
    DescribeGuest("ASTRO_CRASH", pc_in_arena ? state.__pc : 0);
#endif
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

#if !defined(_WIN32) && defined(SHADPS4_ENABLE_FEX_GUEST_CPU)
void DumpGuestState(const char* tag) {
    const DumpGuard guard;
    if (guard.Entered()) {
        DescribeGuest(tag, 0);
    }
}
#else
void DumpGuestState(const char*) {}
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
