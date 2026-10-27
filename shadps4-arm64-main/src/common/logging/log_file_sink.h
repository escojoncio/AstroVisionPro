// SPDX-FileCopyrightText: Copyright 2025-2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <atomic>
#include <cstdio>
#include <memory>
#include <string_view>
#include <spdlog/common.h>
#include <spdlog/details/log_msg.h>
#include <spdlog/formatter.h>
#include <spdlog/sinks/base_sink.h>
#ifdef _WIN32
#include <io.h>
#else
#include <unistd.h>
#endif

namespace Common::Log {
static constexpr unsigned long long UNLIMITED_SIZE = 0;

/*
 * Trivial file sink with two files as target : main and session
 */
class LogFileSink final : public spdlog::sinks::base_sink<std::mutex> {
public:
    explicit LogFileSink(const spdlog::filename_t& main_filename, bool truncate = false,
                         unsigned long long size_limit = UNLIMITED_SIZE)
        : main_file_helper_{TrackDescriptor(main_fd_)},
          session_file_helper_{TrackDescriptor(session_fd_)}, _size_limit{size_limit} {
        main_file_helper_.open(main_filename, truncate);
    }

    /// Appends text to the file that sink_it_ writes to, with write() alone: no lock, no
    /// allocation, so that a signal handler can use it. What the stdio buffer of that file still
    /// holds is written after it.
    void WriteRaw(const char* data, size_t size) const noexcept {
        int fd = session_fd_.load(std::memory_order_relaxed);
        if (fd < 0) {
            fd = main_fd_.load(std::memory_order_relaxed);
        }
        if (fd < 0) {
            return;
        }
#ifdef _WIN32
        static_cast<void>(_write(fd, data, static_cast<unsigned>(size)));
#else
        static_cast<void>(::write(fd, data, size));
#endif
    }

    std::atomic<int> main_fd_{-1};
    std::atomic<int> session_fd_{-1};
    spdlog::details::file_helper main_file_helper_;
    spdlog::details::file_helper session_file_helper_;

    unsigned long long _size_limit;

protected:
    /// The handlers that keep `fd` at the descriptor of the file a helper has open (-1 if none).
    static spdlog::file_event_handlers TrackDescriptor(std::atomic<int>& fd) {
        spdlog::file_event_handlers handlers;
        handlers.after_open = [&fd](const spdlog::filename_t&, std::FILE* file) {
#ifdef _WIN32
            fd.store(_fileno(file), std::memory_order_relaxed);
#else
            fd.store(fileno(file), std::memory_order_relaxed);
#endif
        };
        handlers.before_close = [&fd](const spdlog::filename_t&, std::FILE*) {
            fd.store(-1, std::memory_order_relaxed);
        };
        return handlers;
    }

    void sink_it_(const spdlog::details::log_msg& msg) override {
        spdlog::memory_buf_t formatted;
        this->formatter_->format(msg, formatted);

        if (session_file_helper_.filename().empty()) {
            // always log in the main file, it shouldnt be too big
            main_file_helper_.write(formatted);
        } else if (_current_size < _size_limit || msg.log_level == spdlog::level::critical) {
            session_file_helper_.write(formatted);
            _current_size += formatted.size();
        }
    }

    void flush_() override {
        main_file_helper_.flush();
        session_file_helper_.flush();
    }

    unsigned long long _current_size = 0;
};
} // namespace Common::Log
