// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Memory the emulator can write code into and run it from, on an Apple Vision Pro.
//
// visionOS lets no app make memory executable by itself. A process with a debugger attached is
// the exception, and with the headset's code-signing monitor (TXM) even then only through the
// debugger: StikDebug (https://github.com/rebelancap/StikDebug-visionos) attaches to this
// process when it is asked to through stikjit://enable-jit, and runs its universal.js script,
// which waits for this process to stop on `brk #0xf00d` and then does what x16 asks:
//   x16 = 1  JIT26PrepareRegion(x0 = address or 0, x1 = size): allocate (if x0 is 0) and prepare
//            that many bytes of read-execute memory, and hand its address back in x0;
//   x16 = 0  JIT26Detach: let the process go.
// The pages it prepares can then be mapped a second time, readable and writable, and code
// written there runs at the first address. Neither mapping is ever both.

#include <errno.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "astro_core.h"

// Not in the SDK's headers, but in its libraries (every JIT-enabling tool for iOS uses it).
extern int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);
#define ASTRO_CS_OPS_STATUS 0
#define ASTRO_CS_DEBUGGED 0x10000000u

static pthread_mutex_t g_arena_mutex = PTHREAD_MUTEX_INITIALIZER;
static AstroJitArena g_arena;

bool astro_jit_process_is_debugged(void) {
    uint32_t flags = 0;
    if (csops(getpid(), ASTRO_CS_OPS_STATUS, &flags, sizeof(flags)) != 0) {
        return false;
    }
    return (flags & ASTRO_CS_DEBUGGED) != 0;
}

// The two "system calls" universal.js answers. They must stay functions of their own that do
// nothing but this: the script reads x0, x1 and x16 at the brk, and steps over it.
__attribute__((noinline, optnone, naked)) static void astro_jit26_detach(void) {
    __asm__("mov x16, #0\n"
            "brk #0xf00d\n"
            "ret\n");
}

__attribute__((noinline, optnone, naked)) static void* astro_jit26_prepare_region(void* address,
                                                                                size_t size) {
    __asm__("mov x16, #1\n"
            "brk #0xf00d\n"
            "ret\n");
}

int astro_jit_prepare_arena(size_t size) {
    if (!astro_jit_process_is_debugged()) {
        // A brk with nobody attached would end the process.
        return EPERM;
    }
    pthread_mutex_lock(&g_arena_mutex);
    if (g_arena.size != 0) {
        pthread_mutex_unlock(&g_arena_mutex);
        return 0;
    }
    const size_t page = (size_t)vm_page_size;
    size = (size + page - 1) & ~(page - 1);

    void* const rx = astro_jit26_prepare_region(NULL, size);
    if (rx == NULL || rx == (void*)-1 || ((uintptr_t)rx & (page - 1)) != 0) {
        astro_jit26_detach();
        pthread_mutex_unlock(&g_arena_mutex);
        return ENOMEM;
    }

    // The same pages once more, for writing.
    vm_address_t rw = 0;
    vm_prot_t current = VM_PROT_NONE;
    vm_prot_t maximum = VM_PROT_NONE;
    const kern_return_t remapped =
        vm_remap(mach_task_self(), &rw, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                 (vm_address_t)rx, FALSE, &current, &maximum, VM_INHERIT_NONE);
    if (remapped != KERN_SUCCESS) {
        astro_jit26_detach();
        pthread_mutex_unlock(&g_arena_mutex);
        return EFAULT;
    }
    if (mprotect((void*)rw, size, PROT_READ | PROT_WRITE) != 0) {
        const int error = errno;
        vm_deallocate(mach_task_self(), rw, size);
        astro_jit26_detach();
        pthread_mutex_unlock(&g_arena_mutex);
        return error != 0 ? error : EACCES;
    }

    astro_jit26_detach();
    g_arena.rx = (uintptr_t)rx;
    g_arena.rw = (uintptr_t)rw;
    g_arena.size = size;
    pthread_mutex_unlock(&g_arena_mutex);
    return 0;
}

bool astro_jit_get_arena(AstroJitArena* arena) {
    pthread_mutex_lock(&g_arena_mutex);
    const bool have = g_arena.size != 0;
    if (have && arena != NULL) {
        *arena = g_arena;
    }
    pthread_mutex_unlock(&g_arena_mutex);
    return have;
}

int astro_jit_self_test(void) {
    AstroJitArena arena;
    if (!astro_jit_get_arena(&arena)) {
        return ENOENT;
    }
    // The last page of the arena: the emulator hands out the arena from the front.
    const size_t page = (size_t)vm_page_size;
    const uintptr_t offset = arena.size - page;
    static const uint32_t code[] = {
        0xd2800540u, // mov x0, #42
        0xd65f03c0u, // ret
    };
    memcpy((void*)(arena.rw + offset), code, sizeof(code));
    sys_icache_invalidate((void*)(arena.rx + offset), sizeof(code));
    __builtin_arm_dsb(0xf);
    __builtin_arm_isb(0xf);
    typedef uint64_t (*Function)(void);
    const uint64_t result = ((Function)(arena.rx + offset))();
    memset((void*)(arena.rw + offset), 0, sizeof(code));
    return result == 42 ? 0 : EIO;
}
