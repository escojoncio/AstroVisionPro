// A second virtual mapping ("mirror") of the guest's memory, for VPKEngine's no-copy GPU buffers.
//
// The renderer's buffers alias guest memory in place (unified memory: no staging copy). Detecting
// CPU writes by page protection would clash with that: a Metal buffer cannot be created over (and
// may fault on) pages protected for the CPU. The mirror breaks the clash: the GPU buffers alias the
// mirror, which is always read/write, while the guest addresses themselves may be protected
// (read-only to catch CPU writes to texture sources, inaccessible to catch CPU reads of memory an
// image on the GPU is ahead of). Both mappings are the same pages: no copy, always coherent.
#pragma once

#include <cstdint>

namespace VpkengineRenderer {

// The mirror of the guest mapping [begin, end) (page aligned, mapped throughout), or null when the
// host cannot make one (the caller then aliases the guest addresses directly and does not protect
// them). The same pointer is returned while the pages behind the range are the same ones; a mapping
// that was replaced (munmap + mmap over it) gets a new mirror, and the old one stays mapped for a
// while longer because the GPU may still be reading it.
void* GuestMirror(uint64_t begin, uint64_t end);

// Calls made since the last take: GuestMirror lookups and the vm_region_recurse_64 syscalls of their
// signatures (diagnostics).
struct GuestMirrorStats {
    uint64_t lookups = 0, regionCalls = 0;
};
GuestMirrorStats TakeGuestMirrorStats();

} // namespace VpkengineRenderer
