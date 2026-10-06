// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Everything the app and the emulator write to their standard output and error (the app's
// messages, FEX's, the emulator's crash reporter with its registers) goes to a file the player
// can reach with the Files app and send: Documents/Registros/consola-<date>.txt. Written
// straight through, so what was written before a crash is in the file.

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "astro_core.h"

static char g_console_path[1024];

const char* astro_log_begin(const char* directory) {
    if (directory == NULL) {
        return NULL;
    }
    char stamp[32];
    const time_t now = time(NULL);
    struct tm local;
    localtime_r(&now, &local);
    strftime(stamp, sizeof(stamp), "%Y-%m-%d_%H-%M-%S", &local);
    snprintf(g_console_path, sizeof(g_console_path), "%s/consola-%s.txt", directory, stamp);
    const int fd = open(g_console_path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);
    if (fd < 0) {
        g_console_path[0] = '\0';
        return NULL;
    }
    fflush(stdout);
    fflush(stderr);
    dup2(fd, STDOUT_FILENO);
    dup2(fd, STDERR_FILENO);
    close(fd);
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    fprintf(stdout, "AstroQuest: console log started %s\n", stamp);
    return g_console_path;
}

void astro_log(const char* message) {
    if (message == NULL) {
        return;
    }
    char stamp[16];
    const time_t now = time(NULL);
    struct tm local;
    localtime_r(&now, &local);
    strftime(stamp, sizeof(stamp), "%H:%M:%S", &local);
    fprintf(stdout, "[%s] [App] %s\n", stamp, message);
    fflush(stdout);
}
