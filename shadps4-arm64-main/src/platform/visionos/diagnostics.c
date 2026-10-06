// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

// What the launcher's check reports: the entitlements this copy of the app was signed with, how
// much memory the system lets it use, and how much address space it can reserve. Nothing here
// changes anything; the emulator does not have to be running.

#include <mach/mach.h>
#include <os/proc.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "astro_core.h"

extern int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);
#define ASTRO_CS_OPS_ENTITLEMENTS_BLOB 7

int astro_diag_entitlements(void* buffer, uint32_t capacity) {
    // A code signature blob: magic (0xfade7171) and length, big-endian, then the XML.
    if (buffer == NULL || capacity < 8) {
        return -1;
    }
    memset(buffer, 0, capacity);
    if (csops(getpid(), ASTRO_CS_OPS_ENTITLEMENTS_BLOB, buffer, capacity) != 0) {
        return -1;
    }
    const uint8_t* bytes = (const uint8_t*)buffer;
    const uint32_t length = ((uint32_t)bytes[4] << 24) | ((uint32_t)bytes[5] << 16) |
                            ((uint32_t)bytes[6] << 8) | (uint32_t)bytes[7];
    if (length < 8 || length > capacity) {
        return -1;
    }
    memmove(buffer, bytes + 8, length - 8);
    return (int)(length - 8);
}

uint64_t astro_diag_available_memory(void) {
    return (uint64_t)os_proc_available_memory();
}

uint32_t astro_diag_address_space_gb(void) {
    // The range of addresses the system gives this process (min_address to max_address).
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS ||
        info.max_address <= info.min_address) {
        return 0;
    }
    return (uint32_t)((info.max_address - info.min_address) >> 30);
}

bool astro_diag_can_reserve_gb(uint32_t gb) {
    // One reservation of that size, given back at once. Only the size the emulator needs is
    // tried: holding most of the address space even for a moment makes the app's other threads
    // fail to get memory (the first version of this check, which went down from 64 GB, left
    // letters missing in the launcher's text that way).
    const size_t size = (size_t)gb << 30;
    void* address = mmap(NULL, size, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (address == MAP_FAILED) {
        return false;
    }
    munmap(address, size);
    return true;
}
