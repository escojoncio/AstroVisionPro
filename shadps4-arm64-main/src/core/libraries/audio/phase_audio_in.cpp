// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

// The title's microphone ports on the headset, read from the microphone the headset's 3D audio
// takes on its own session when the title first opens one (spatial_audio.h): SDL would take the
// session down and set it up again, which silences the sound for a moment.

#include <algorithm>
#include <chrono>
#include <cmath>
#include <thread>
#include <vector>

#include "common/logging/log.h"
#include "core/libraries/audio/audioin.h"
#include "core/libraries/audio/audioin_backend.h"
#include "core/libraries/audio/spatial_audio.h"

namespace Libraries::AudioIn {

namespace {

constexpr u32 MicrophoneRate = 48000;

class PhasePortInBackend final : public PortInBackend {
public:
    explicit PhasePortInBackend(const PortIn& port_) : port{port_} {
        // The title asks for 48 or 16 kHz: a sample of its for every `ratio` of the microphone's
        // (the mean of them, which also keeps out what 16 kHz cannot hold).
        ratio = port.freq > 0 && port.freq < MicrophoneRate ? MicrophoneRate / port.freq : 1;
        mono.resize(size_t{port.samples_num} * ratio);
        // What waited before the port was opened is not what the title is to hear.
        SpatialAudio::MicrophoneClear();
        LOG_INFO(Lib_AudioIn, "MICROPHONE: port of {} frames, {} channels, {} Hz",
                 port.samples_num, port.channels_num, port.freq);
    }

    int Read(void* out_buffer) override {
        const u32 frames = port.samples_num;
        const u32 wanted = frames * ratio;
        // Waits for a block as a device would (at most a quarter of a second).
        for (int waited = 0; SpatialAudio::MicrophoneQueued() < wanted && waited < 250;
             ++waited) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        SpatialAudio::MicrophoneRead(mono.data(), wanted);
        auto* out = static_cast<s16*>(out_buffer);
        const u32 channels = std::max<u32>(port.channels_num, 1);
        for (u32 i = 0; i < frames; ++i) {
            float sum = 0.0f;
            for (u32 k = 0; k < ratio; ++k) {
                sum += mono[size_t{i} * ratio + k];
            }
            const float v = std::clamp(sum / static_cast<float>(ratio), -1.0f, 1.0f);
            const s16 sample = static_cast<s16>(std::lround(v * 32767.0f));
            for (u32 c = 0; c < channels; ++c) {
                out[size_t{i} * channels + c] = sample;
            }
        }
        return static_cast<int>(frames);
    }

    void Clear() override {
        SpatialAudio::MicrophoneClear();
    }

    bool IsAvailable() override {
        return true;
    }

private:
    const PortIn& port;
    u32 ratio{1};
    std::vector<float> mono;
};

} // namespace

std::unique_ptr<PortInBackend> PhaseAudioIn::Open(PortIn& port) {
    return std::make_unique<PhasePortInBackend>(port);
}

} // namespace Libraries::AudioIn
