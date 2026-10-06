// libusb's clocks on Apple systems come with its IOKit backend (darwin_usb.c), which visionOS
// apps cannot use; the null backend the emulator has there needs them from here.
#include <time.h>

void usbi_get_monotonic_time(struct timespec* tp) {
    clock_gettime(CLOCK_MONOTONIC, tp);
}

void usbi_get_real_time(struct timespec* tp) {
    clock_gettime(CLOCK_REALTIME, tp);
}
