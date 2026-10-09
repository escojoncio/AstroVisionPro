// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

// The audio output ports played through the headset's 3D audio (spatial_audio.h).

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <memory>
#include <thread>
#include <vector>

#include "common/logging/log.h"
#include "core/emulator_settings.h"
#include "core/libraries/audio/audioout.h"
#include "core/libraries/audio/audioout_backend.h"
#include "core/libraries/audio/spatial_audio.h"

namespace Libraries::AudioOut {

namespace {

/// Where the speakers of a 7.1 room stand, as degrees to the right of straight ahead, by the
/// slot of the port's layout (front left, right, centre, -, the surround pair, the back pair);
/// the same reading of the layout as surround_virtualizer.cpp.
constexpr std::array<int, 7> SpeakerSlot = {0, 1, 2, 4, 5, 6, 7};
constexpr std::array<float, 7> SpeakerAngle = {-30.0f, 30.0f, 0.0f, -110.0f, 110.0f, -150.0f,
                                               150.0f};
constexpr float SpeakerDistance = 2.0f;
constexpr float LfeLevel = 0.5f;
constexpr float Volume0dB = 32768.0f;

/// An output port played through PHASE: a surround port from speakers around the head, any
/// other in both ears. The port waits for PHASE to take its sound, so PHASE's clock paces it.
class PhasePortBackend final : public PortBackend {
public:
    explicit PhasePortBackend(PortOut& port)
        : format{port.format_info}, frames{port.buffer_frames}, type{port.type} {
        if (format.num_channels == 8) {
            for (u32 s = 0; s < SpeakerSlot.size(); ++s) {
                const float angle = SpeakerAngle[s] * 3.14159265f / 180.0f;
                voices.push_back(SpatialAudio::OpenFixedSpatial(
                    std::sin(angle) * SpeakerDistance, 0.0f, -std::cos(angle) * SpeakerDistance));
            }
            mono.resize(frames);
        } else {
            voices.push_back(SpatialAudio::OpenStereo());
            stereo.resize(size_t{frames} * 2);
        }
        input.resize(size_t{frames} * format.num_channels);
        gain.store(EmulatorSettings.GetVolumeSlider() * 0.01f, std::memory_order_relaxed);
        LOG_INFO(Lib_AudioOut, "SPATIAL_AUDIO: port {} ({} channels, {} frames) {}",
                 static_cast<int>(type), format.num_channels, frames,
                 format.num_channels == 8 ? "from 7 speakers around the head" : "in both ears");
    }

    ~PhasePortBackend() override {
        for (const int voice : voices) {
            SpatialAudio::Close(voice);
        }
    }

    void Output(void* ptr) override {
        if (ptr == nullptr || voices.empty() || voices[0] < 0) {
            return;
        }
        const float g = gain.load(std::memory_order_relaxed);
        const u32 channels = format.num_channels;
        for (size_t i = 0; i < input.size(); ++i) {
            const float s = format.is_float ? static_cast<const float*>(ptr)[i]
                                            : static_cast<const s16*>(ptr)[i] / 32768.0f;
            input[i] = s * g;
        }

        Pace();
        if (channels == 8) {
            const int lfe = std::clamp(format.channel_layout[3], 0, 7);
            for (u32 s = 0; s < SpeakerSlot.size(); ++s) {
                const int slot = std::clamp(format.channel_layout[SpeakerSlot[s]], 0, 7);
                for (u32 i = 0; i < frames; ++i) {
                    float sample = input[size_t{i} * 8 + slot];
                    // The subwoofer has no direction: it goes to the front pair.
                    if (s < 2) {
                        sample += input[size_t{i} * 8 + lfe] * LfeLevel;
                    }
                    mono[i] = sample;
                }
                SpatialAudio::Write(voices[s], mono.data(), frames);
            }
        } else {
            for (u32 i = 0; i < frames; ++i) {
                stereo[size_t{i} * 2] = input[size_t{i} * channels];
                stereo[size_t{i} * 2 + 1] = input[size_t{i} * channels + (channels > 1 ? 1 : 0)];
            }
            SpatialAudio::Write(voices[0], stereo.data(), frames);
        }
    }

    void SetVolume(const std::array<int, 8>& ch_volumes) override {
        float loudest = 0.0f;
        for (u32 i = 0; i < std::min<u32>(format.num_channels, 8); ++i) {
            loudest = std::max(loudest, static_cast<float>(ch_volumes[i]) / Volume0dB);
        }
        gain.store(loudest * EmulatorSettings.GetVolumeSlider() * 0.01f,
                   std::memory_order_relaxed);
    }

    bool IsDevicePaced() const override {
        return true;
    }

private:
    /// Keeps two of the device's buffers and one of the port's waiting: a start (or a restart
    /// after a pause) gets silence up to that, and the port waits while there is more.
    void Pace() {
        const u32 device = std::max<u32>(SpatialAudio::DeviceFrames(), 256);
        const u32 target = 2 * device + frames;
        u32 queued = SpatialAudio::Queued(voices[0]);
        if (queued < device) {
            if (primed) {
                ++underruns;
            }
            const std::vector<float> silence(size_t{2 * device} * 2, 0.0f);
            for (const int voice : voices) {
                const u32 have = SpatialAudio::Queued(voice);
                if (have < 2 * device) {
                    SpatialAudio::Write(voice, silence.data(), 2 * device - have);
                }
            }
            primed = true;
            queued = SpatialAudio::Queued(voices[0]);
        }
        for (int waited = 0; queued > target && waited < 50; ++waited) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            queued = SpatialAudio::Queued(voices[0]);
        }
        const auto now = std::chrono::steady_clock::now();
        if (now - report_time >= std::chrono::seconds(10)) {
            if (report_time.time_since_epoch().count() != 0) {
                LOG_INFO(Lib_AudioOut,
                         "AUDIO_PACE port {}: {} times nearly empty in 10 s; device buffer {} "
                         "frames, {} frames queued",
                         static_cast<int>(type), underruns, device, queued);
            }
            underruns = 0;
            report_time = now;
        }
    }

    const AudioFormatInfo format;
    const u32 frames;
    const OrbisAudioOutPort type;
    std::vector<int> voices;
    std::vector<float> input;
    std::vector<float> mono;
    std::vector<float> stereo;
    std::atomic<float> gain{1.0f};
    bool primed{};
    u32 underruns{};
    std::chrono::steady_clock::time_point report_time{};
};

} // namespace

std::unique_ptr<PortBackend> PhaseAudioOut::Open(PortOut& port) {
    return std::make_unique<PhasePortBackend>(port);
}

} // namespace Libraries::AudioOut
