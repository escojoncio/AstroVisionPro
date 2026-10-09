// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

// PlayStation VR's 3D audio on Apple Vision Pro, rendered by PHASE (see spatial_audio.h). The
// output ports that play through it are in phase_audio_out.cpp (the emulator's headers do not
// build as Objective-C with ARC).
//
// Every voice is a PHASE sound event that runs for good with a pull stream: PHASE asks for sound
// on its render thread, and the voice hands over what the emulator wrote into its ring (silence
// when there is none). Spatial voices have a source of their own, moved to where the title
// places the sound; stereo voices play in both ears as they are.

#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>
#import <PHASE/PHASE.h>
#include <simd/simd.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <vector>

#include "common/logging/log.h"
#include "core/libraries/audio/spatial_audio.h"

namespace Libraries::SpatialAudio {

namespace {

constexpr u32 SampleRate = 48000;
/// Voices for the title's 3D objects, made when the engine starts.
constexpr u32 ObjectVoices = 48;
/// Blocks of the 3D port an object may stay silent before its voice goes to another.
constexpr u64 ObjectIdleTicks = 48;

/// One writer (the emulator) and one reader (PHASE's render thread), no locks.
class Ring {
public:
    Ring(u32 channels_, u32 frames) : channels{channels_}, capacity{frames}, data(size_t{frames} * channels_) {}

    void Write(const float* in, u32 count) {
        const u64 w = write.load(std::memory_order_relaxed);
        const u64 r = std::max(read.load(std::memory_order_acquire),
                               skip_to.load(std::memory_order_relaxed));
        const u64 room = capacity - std::min<u64>(capacity, w - r);
        const u32 n = static_cast<u32>(std::min<u64>(count, room));
        for (u32 i = 0; i < n; ++i) {
            const size_t at = size_t((w + i) % capacity) * channels;
            std::memcpy(&data[at], in + size_t{i} * channels, sizeof(float) * channels);
        }
        write.store(w + n, std::memory_order_release);
    }

    /// Drops what is waiting (from the writer's side): the reader skips it.
    void Discard() {
        skip_to.store(write.load(std::memory_order_relaxed), std::memory_order_release);
    }

    u32 Queued() const {
        const u64 w = write.load(std::memory_order_acquire);
        const u64 r = std::max(read.load(std::memory_order_acquire),
                               skip_to.load(std::memory_order_acquire));
        return static_cast<u32>(w > r ? w - r : 0);
    }

    /// Fills planar outputs; returns the frames that were sound (the rest are zeroed).
    u32 Read(float* const* out, u32 out_channels, u32 count) {
        u64 r = read.load(std::memory_order_relaxed);
        const u64 skip = skip_to.load(std::memory_order_acquire);
        if (skip > r) {
            r = skip;
        }
        const u64 w = write.load(std::memory_order_acquire);
        const u32 n = static_cast<u32>(std::min<u64>(count, w > r ? w - r : 0));
        for (u32 i = 0; i < n; ++i) {
            const size_t at = size_t((r + i) % capacity) * channels;
            for (u32 c = 0; c < out_channels; ++c) {
                out[c][i] = data[at + std::min(c, channels - 1)];
            }
        }
        for (u32 c = 0; c < out_channels; ++c) {
            std::fill(out[c] + n, out[c] + count, 0.0f);
        }
        read.store(r + n, std::memory_order_release);
        return n;
    }

private:
    const u32 channels;
    const u64 capacity;
    std::vector<float> data;
    std::atomic<u64> write{0};
    std::atomic<u64> read{0};
    std::atomic<u64> skip_to{0};
};

enum class Kind { Object, Fixed, Stereo };

struct Voice {
    Kind kind{};
    bool spatial{};
    u32 channels{};
    std::unique_ptr<Ring> ring;
    PHASESource* source{};
    PHASESoundEvent* event{};
    // The bookkeeping below is the emulator's, under g_mutex.
    bool in_use{};
    u64 key{};
    u64 last_tick{};
    float gain{};
    simd_float3 position{0, 0, -1};
};

/// Bookkeeping of objects and which voices are taken.
std::mutex g_mutex;
/// Making voices (PHASE takes its time): one at a time, outside g_mutex.
std::mutex g_make_mutex;
std::once_flag g_once;
std::atomic<bool> g_available{false};
PHASEEngine* g_engine = nil;
PHASEListener* g_listener = nil;
u32 g_device_frames = 256;
/// Voices are never taken apart and never move: the table does not grow, so a voice can be
/// read without a lock while others are being made.
constexpr int MaxVoices = 160;
std::array<std::unique_ptr<Voice>, MaxVoices> g_voices;
std::atomic<int> g_voice_count{0};
std::vector<int> g_object_voices;
std::unordered_map<u64, int> g_objects;
u64 g_tick = 0;
int g_serial = 0;

simd_float4x4 Placed(simd_float3 p) {
    // A source on the listener has no direction: keep it a metre away at least.
    float length = simd_length(p);
    if (length < 1e-3f) {
        p = simd_make_float3(0, 0, -1);
        length = 1;
    }
    if (length < 1.0f) {
        p = p / length;
    }
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[3] = simd_make_float4(p, 1);
    return m;
}

/// A voice playing for good. Called under g_make_mutex.
int MakeVoice(Kind kind) {
    const bool spatial = kind != Kind::Stereo;
    const u32 channels = spatial ? 1 : 2;
    if (g_voice_count.load(std::memory_order_relaxed) >= MaxVoices) {
        return -1;
    }
    NSError* error = nil;
    const int id = g_serial++;
    NSString* mix_id = [NSString stringWithFormat:@"astro.mix.%d", id];
    NSString* node_id = [NSString stringWithFormat:@"astro.node.%d", id];
    NSString* event_id = [NSString stringWithFormat:@"astro.event.%d", id];

    PHASEMixerParameters* parameters = [[PHASEMixerParameters alloc] init];
    PHASEMixerDefinition* mixer = nil;
    PHASESource* source = nil;
    if (spatial) {
        PHASESpatialPipeline* pipeline = [[PHASESpatialPipeline alloc]
            initWithFlags:PHASESpatialPipelineFlagDirectPathTransmission];
        if (pipeline == nil) {
            return -1;
        }
        PHASESpatialMixerDefinition* spatial_mixer =
            [[PHASESpatialMixerDefinition alloc] initWithSpatialPipeline:pipeline
                                                              identifier:mix_id];
        // The title already makes distant sounds quieter.
        PHASEGeometricSpreadingDistanceModelParameters* distance =
            [[PHASEGeometricSpreadingDistanceModelParameters alloc] init];
        distance.rolloffFactor = 0.0;
        spatial_mixer.distanceModelParameters = distance;
        mixer = spatial_mixer;
        source = [[PHASESource alloc] initWithEngine:g_engine];
        source.transform = Placed(simd_make_float3(0, 0, -1));
        if (![g_engine.rootObject addChild:source error:&error]) {
            LOG_ERROR(Lib_AudioOut, "SPATIAL_AUDIO: no source: {}",
                      error.localizedDescription.UTF8String);
            return -1;
        }
        [parameters addSpatialMixerParametersWithIdentifier:mix_id source:source
                                                   listener:g_listener];
    } else {
        AVAudioChannelLayout* layout =
            [[AVAudioChannelLayout alloc] initWithLayoutTag:kAudioChannelLayoutTag_Stereo];
        mixer = [[PHASEChannelMixerDefinition alloc] initWithChannelLayout:layout
                                                                identifier:mix_id];
    }

    AVAudioFormat* format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:SampleRate
                                                                           channels:channels];
    PHASEPullStreamNodeDefinition* node =
        [[PHASEPullStreamNodeDefinition alloc] initWithMixerDefinition:mixer
                                                                format:format
                                                            identifier:node_id];
    node.normalize = NO;
    if (![g_engine.assetRegistry registerSoundEventAssetWithRootNode:node
                                                          identifier:event_id
                                                               error:&error]) {
        LOG_ERROR(Lib_AudioOut, "SPATIAL_AUDIO: no asset: {}",
                  error.localizedDescription.UTF8String);
        return -1;
    }
    PHASESoundEvent* event = [[PHASESoundEvent alloc] initWithEngine:g_engine
                                                     assetIdentifier:event_id
                                                     mixerParameters:parameters
                                                               error:&error];
    if (event == nil) {
        LOG_ERROR(Lib_AudioOut, "SPATIAL_AUDIO: no event: {}",
                  error.localizedDescription.UTF8String);
        return -1;
    }
    PHASEPullStreamNode* pull = event.pullStreamNodes[node_id];
    if (pull == nil) {
        LOG_ERROR(Lib_AudioOut, "SPATIAL_AUDIO: the event has no pull stream");
        return -1;
    }

    auto voice = std::make_unique<Voice>();
    voice->kind = kind;
    voice->spatial = spatial;
    voice->channels = channels;
    // A fifth of a second at most waits in a voice.
    voice->ring = std::make_unique<Ring>(channels, SampleRate / 5);
    voice->source = source;
    voice->event = event;
    Ring* ring = voice->ring.get();
    pull.renderBlock = ^OSStatus(BOOL* is_silence, const AudioTimeStamp*, AVAudioFrameCount frames,
                                 AudioBufferList* output) {
        float* planes[2] = {};
        const u32 count = std::min<u32>(output->mNumberBuffers, 2);
        for (u32 c = 0; c < count; ++c) {
            planes[c] = static_cast<float*>(output->mBuffers[c].mData);
        }
        const u32 got = ring->Read(planes, count, frames);
        *is_silence = got == 0 ? YES : NO;
        return noErr;
    };
    [event startWithCompletion:^(PHASESoundEventStartHandlerReason) {
    }];

    const int index = g_voice_count.load(std::memory_order_relaxed);
    g_voices[index] = std::move(voice);
    g_voice_count.store(index + 1, std::memory_order_release);
    return index;
}

Voice* Get(int voice) {
    return voice >= 0 && voice < g_voice_count.load(std::memory_order_acquire)
               ? g_voices[voice].get()
               : nullptr;
}

/// A free voice of that kind, taken; a new one when there is none.
int Take(Kind kind) {
    {
        std::scoped_lock lock{g_mutex};
        const int count = g_voice_count.load(std::memory_order_acquire);
        for (int i = 0; i < count; ++i) {
            Voice& v = *g_voices[i];
            if (v.kind == kind && !v.in_use) {
                v.in_use = true;
                v.ring->Discard();
                return i;
            }
        }
    }
    std::scoped_lock make{g_make_mutex};
    int index;
    @autoreleasepool {
        index = MakeVoice(kind);
    }
    if (index >= 0) {
        std::scoped_lock lock{g_mutex};
        g_voices[index]->in_use = true;
    }
    return index;
}

} // namespace

bool Start() {
    std::call_once(g_once, [] {
        if (const char* setting = std::getenv("SHADPS4_SPATIAL_AUDIO");
            setting != nullptr && setting[0] == '0') {
            LOG_INFO(Lib_AudioOut, "SPATIAL_AUDIO: off by the settings");
            return;
        }
        @autoreleasepool {
            NSError* error = nil;
            AVAudioSession* session = [AVAudioSession sharedInstance];
            [session setCategory:AVAudioSessionCategoryPlayback error:&error];
            // The title turns the sound with the head already; the system must not do it again.
            if (![session setIntendedSpatialExperience:AVAudioSessionSpatialExperienceBypassed
                                                options:@{}
                                                  error:&error]) {
                LOG_WARNING(Lib_AudioOut, "SPATIAL_AUDIO: system spatialization still on: {}",
                            error.localizedDescription.UTF8String);
            }
            [session setPreferredSampleRate:SampleRate error:nil];
            [session setPreferredIOBufferDuration:0.005 error:nil];
            [session setActive:YES error:nil];
            g_device_frames = std::clamp<u32>(
                static_cast<u32>(std::lround(session.IOBufferDuration * session.sampleRate)), 64,
                4096);

            g_engine = [[PHASEEngine alloc] initWithUpdateMode:PHASEUpdateModeAutomatic];
            g_engine.defaultReverbPreset = PHASEReverbPresetNone;
            if (![g_engine startAndReturnError:&error]) {
                LOG_ERROR(Lib_AudioOut, "SPATIAL_AUDIO: PHASE did not start: {}",
                          error.localizedDescription.UTF8String);
                g_engine = nil;
                return;
            }
            g_listener = [[PHASEListener alloc] initWithEngine:g_engine];
            g_listener.transform = matrix_identity_float4x4;
            if (@available(visionOS 26.0, *)) {
                g_listener.automaticHeadTrackingFlags = 0;
            }
            if (![g_engine.rootObject addChild:g_listener error:&error]) {
                LOG_ERROR(Lib_AudioOut, "SPATIAL_AUDIO: no listener: {}",
                          error.localizedDescription.UTF8String);
                g_engine = nil;
                return;
            }

            std::scoped_lock make{g_make_mutex};
            for (u32 i = 0; i < ObjectVoices; ++i) {
                const int voice = MakeVoice(Kind::Object);
                if (voice < 0) {
                    break;
                }
                g_object_voices.push_back(voice);
            }
            g_available.store(!g_object_voices.empty(), std::memory_order_release);
            LOG_INFO(Lib_AudioOut,
                     "SPATIAL_AUDIO: PHASE on, head-locked; {} voices for 3D objects; device "
                     "{} Hz, {} frames a buffer; route {}",
                     g_object_voices.size(), session.sampleRate, g_device_frames,
                     session.currentRoute.outputs.firstObject.portType.UTF8String ?: "?");
        }
    });
    return g_available;
}

bool Available() {
    return g_available.load(std::memory_order_acquire);
}

int OpenStereo() {
    return Available() ? Take(Kind::Stereo) : -1;
}

int OpenFixedSpatial(float x, float y, float z) {
    if (!Available()) {
        return -1;
    }
    const int voice = Take(Kind::Fixed);
    if (Voice* v = Get(voice)) {
        v->position = simd_make_float3(x, y, z);
        v->source.transform = Placed(v->position);
    }
    return voice;
}

void Close(int voice) {
    std::scoped_lock lock{g_mutex};
    if (Voice* v = Get(voice)) {
        // PHASE events are not taken apart while the engine runs: the voice just falls silent.
        v->ring->Discard();
        v->in_use = false;
    }
}

void Write(int voice, const float* frames, u32 count) {
    if (Voice* v = Get(voice)) {
        v->ring->Write(frames, count);
    }
}

u32 Queued(int voice) {
    Voice* v = Get(voice);
    return v ? v->ring->Queued() : 0;
}

u32 DeviceFrames() {
    return g_device_frames;
}

bool WriteObject(u64 key, const float* mono, u32 count, float x, float y, float z, float gain) {
    if (!Available()) {
        return false;
    }
    std::scoped_lock lock{g_mutex};
    int index = -1;
    if (const auto found = g_objects.find(key); found != g_objects.end()) {
        index = found->second;
    } else {
        for (const int candidate : g_object_voices) {
            if (!g_voices[candidate]->in_use) {
                index = candidate;
                break;
            }
        }
        if (index < 0) {
            return false;
        }
        Voice& fresh = *g_voices[index];
        fresh.in_use = true;
        fresh.key = key;
        fresh.gain = gain;
        fresh.ring->Discard();
        g_objects.emplace(key, index);
    }
    Voice& v = *g_voices[index];
    v.last_tick = g_tick;

    // Objects come straight from the title's 3D port, the rest of its sound after the port's
    // queue and an output port's: they start that much behind (silence) to stay in step, and
    // again whenever they ran dry.
    const u32 device = std::max<u32>(g_device_frames, 256);
    const u32 lead = 2 * device + 3 * count;
    if (const u32 queued = v.ring->Queued(); queued < device) {
        static const std::vector<float> silence(8192, 0.0f);
        u32 fill = lead - queued;
        while (fill > 0) {
            const u32 n = std::min<u32>(fill, static_cast<u32>(silence.size()));
            v.ring->Write(silence.data(), n);
            fill -= n;
        }
    }

    const simd_float3 position = simd_make_float3(x, y, z);
    if (simd_distance_squared(position, v.position) > 1e-6f) {
        v.position = position;
        v.source.transform = Placed(position);
    }

    // The gain moves across the block, so that a change does not click.
    float block[1024];
    u32 done = 0;
    while (done < count) {
        const u32 n = std::min<u32>(count - done, 1024);
        for (u32 i = 0; i < n; ++i) {
            const float t = static_cast<float>(done + i + 1) / static_cast<float>(count);
            block[i] = mono[done + i] * (v.gain + (gain - v.gain) * t);
        }
        v.ring->Write(block, n);
        done += n;
    }
    v.gain = gain;
    return true;
}

void ObjectsTick() {
    if (!Available()) {
        return;
    }
    std::scoped_lock lock{g_mutex};
    ++g_tick;
    for (auto it = g_objects.begin(); it != g_objects.end();) {
        Voice& v = *g_voices[it->second];
        if (g_tick - v.last_tick > ObjectIdleTicks && v.ring->Queued() == 0) {
            v.in_use = false;
            it = g_objects.erase(it);
        } else {
            ++it;
        }
    }
}

} // namespace Libraries::SpatialAudio
