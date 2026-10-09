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
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <SDL3/SDL_hints.h>

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

    /// Drops what is waiting (from the reader's side).
    void SkipAll() {
        read.store(write.load(std::memory_order_acquire), std::memory_order_release);
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

/// What the microphone heard, mono at SampleRate (a second at most).
std::unique_ptr<Ring> g_mic_ring;

enum class Kind { Object, Fixed, Stereo };

struct Voice {
    Kind kind{};
    bool spatial{};
    u32 channels{};
    std::unique_ptr<Ring> ring;
    PHASESource* source{};
    PHASESoundEvent* event{};
    // What its sound event is made of, to make it again (Recover).
    NSString* event_id{};
    NSString* node_id{};
    PHASEMixerParameters* parameters{};
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

/// The microphone, taken with the session's own engine from the start (StartMicrophone): one
/// owner of the audio session, so nothing takes it down under PHASE when the title opens it.
AVAudioEngine* g_mic_engine = nil;
std::atomic<bool> g_mic_on{false};
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
/// Blocks of sound PHASE has asked the voices for: while this does not move, nothing is heard.
std::atomic<u64> g_pulls{0};

/// The session the headset's audio needs. The title also opens the microphone (SDL's), and SDL
/// sets the session up for what is open: with only a microphone of its own, "record" (which
/// silences every output) after taking the session down. So the session is set up for playing
/// and recording from the start, as SDL sets it up when told to (SDL_HINT_AUDIO_CATEGORY,
/// SDL_coreaudio.m UpdateAudioSession), and SDL then finds it as it wants it and leaves it be.
constexpr NSUInteger SessionOptions =
    AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionDefaultToSpeaker |
    0x4 /* AVAudioSessionCategoryOptionAllowBluetooth */ |
    AVAudioSessionCategoryOptionAllowBluetoothA2DP | AVAudioSessionCategoryOptionAllowAirPlay;

void SetUpSession(AVAudioSession* session) {
    NSError* error = nil;
    if (![session.category isEqualToString:AVAudioSessionCategoryPlayAndRecord] ||
        session.categoryOptions != SessionOptions) {
        if (![session setCategory:AVAudioSessionCategoryPlayAndRecord
                             mode:AVAudioSessionModeDefault
                          options:SessionOptions
                            error:&error]) {
            LOG_WARNING(Lib_AudioOut, "SPATIAL_AUDIO: session not set up: {}",
                        error.localizedDescription.UTF8String);
        }
    }
    // The title turns the sound with the head already; the system must not do it again.
    error = nil;
    if (![session setIntendedSpatialExperience:AVAudioSessionSpatialExperienceBypassed
                                        options:@{}
                                          error:&error]) {
        LOG_WARNING(Lib_AudioOut, "SPATIAL_AUDIO: system spatialization still on: {}",
                    error.localizedDescription.UTF8String);
    }
}

/// Makes the voice's sound event and starts it.
bool StartEvent(Voice& voice) {
    NSError* error = nil;
    PHASESoundEvent* event = [[PHASESoundEvent alloc] initWithEngine:g_engine
                                                     assetIdentifier:voice.event_id
                                                     mixerParameters:voice.parameters
                                                               error:&error];
    if (event == nil) {
        LOG_ERROR(Lib_AudioOut, "SPATIAL_AUDIO: no event: {}",
                  error.localizedDescription.UTF8String);
        return false;
    }
    PHASEPullStreamNode* pull = event.pullStreamNodes[voice.node_id];
    if (pull == nil) {
        LOG_ERROR(Lib_AudioOut, "SPATIAL_AUDIO: the event has no pull stream");
        return false;
    }
    Ring* ring = voice.ring.get();
    pull.renderBlock = ^OSStatus(BOOL* is_silence, const AudioTimeStamp*, AVAudioFrameCount frames,
                                 AudioBufferList* output) {
        float* planes[2] = {};
        const u32 count = std::min<u32>(output->mNumberBuffers, 2);
        for (u32 c = 0; c < count; ++c) {
            planes[c] = static_cast<float*>(output->mBuffers[c].mData);
        }
        const u32 got = ring->Read(planes, count, frames);
        *is_silence = got == 0 ? YES : NO;
        g_pulls.fetch_add(1, std::memory_order_relaxed);
        return noErr;
    };
    [event startWithCompletion:^(PHASESoundEventStartHandlerReason) {
    }];
    voice.event = event;
    return true;
}

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
    auto voice = std::make_unique<Voice>();
    voice->kind = kind;
    voice->spatial = spatial;
    voice->channels = channels;
    // A fifth of a second at most waits in a voice.
    voice->ring = std::make_unique<Ring>(channels, SampleRate / 5);
    voice->source = source;
    voice->event_id = event_id;
    voice->node_id = node_id;
    voice->parameters = parameters;
    if (!StartEvent(*voice)) {
        return -1;
    }

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

/// PHASE stopped asking for sound (the session was taken down under it, by SDL or the
/// system): the session is set up and turned on again, the engine started again and every
/// voice's sound event too. On a thread of its own (it takes a while), one at a time.
std::atomic<bool> g_recovering{false};
u32 g_recoveries = 0;

bool StartMicEngine();

void Recover(u64 stalled_ms) {
    @autoreleasepool {
        AVAudioSession* session = [AVAudioSession sharedInstance];
        const std::string was_category = session.category.UTF8String ?: "?";
        const std::string was_route =
            session.currentRoute.outputs.firstObject.portType.UTF8String ?: "none";
        SetUpSession(session);
        NSError* error = nil;
        const bool active = [session setActive:YES error:&error];
        const std::string active_error =
            active ? "" : (error.localizedDescription.UTF8String ?: "?");
        error = nil;
        bool started = true;
        if (g_engine.renderingState == PHASERenderingStateStarted) {
            [g_engine pause];
        }
        started = [g_engine startAndReturnError:&error];
        const std::string start_error =
            started ? "" : (error.localizedDescription.UTF8String ?: "?");
        // The microphone's engine stops with the session too.
        if (g_mic_engine != nil && !g_mic_engine.isRunning) {
            StartMicEngine();
        }
        u32 resumed = 0;
        u32 remade = 0;
        // Voices are made under this lock (Take): none is half made while they are gone over.
        std::scoped_lock make{g_make_mutex};
        const int count = g_voice_count.load(std::memory_order_acquire);
        for (int i = 0; i < count; ++i) {
            Voice& voice = *g_voices[i];
            if (voice.event == nil) {
                continue;
            }
            switch (voice.event.renderingState) {
            case PHASERenderingStateStarted:
                break;
            case PHASERenderingStatePaused:
                [voice.event resume];
                ++resumed;
                break;
            default:
                [voice.event stopAndInvalidate];
                if (StartEvent(voice)) {
                    ++remade;
                }
                break;
            }
        }
        ++g_recoveries;
        if (g_recoveries <= 20 || g_recoveries % 50 == 0) {
            LOG_WARNING(Lib_AudioOut,
                        "SPATIAL_AUDIO: PHASE took no sound for {} ms (session {}, route {}): "
                        "session on again {}{}, engine started {}{}; {} voices resumed, {} made "
                        "again (time {})",
                        stalled_ms, was_category, was_route, active ? "yes" : "no: ",
                        active_error, started ? "yes" : "no: ", start_error, resumed, remade,
                        g_recoveries);
        }
    }
}

/// Taps the microphone in the format it has now: mono, resampled to SampleRate, into g_mic_ring.
/// False when it has no input (or the tap was refused).
bool InstallMicTap() {
    AVAudioInputNode* input = g_mic_engine.inputNode;
    @try {
        [input removeTapOnBus:0];
    } @catch (NSException*) {
    }
    AVAudioFormat* format = [input outputFormatForBus:0];
    if (format == nil || format.sampleRate <= 0 || format.channelCount == 0) {
        LOG_WARNING(Lib_AudioIn, "MICROPHONE: there is none");
        return false;
    }
    Ring* ring = g_mic_ring.get();
    const double step = format.sampleRate / static_cast<double>(SampleRate);
    // Linear resampling from the microphone's rate, carried over from block to block.
    auto position = std::make_shared<double>(0.0);
    auto previous = std::make_shared<float>(0.0f);
    @try {
        [input installTapOnBus:0
                    bufferSize:1024
                        format:format
                         block:^(AVAudioPCMBuffer* buffer, AVAudioTime*) {
                           const u32 frames = buffer.frameLength;
                           const u32 channels = buffer.format.channelCount;
                           float* const* data = buffer.floatChannelData;
                           if (data == nullptr || frames < 2 || channels == 0) {
                               return;
                           }
                           // Nobody read for a while (half a second waits): what waits is old.
                           if (ring->Queued() > SampleRate / 2) {
                               ring->Discard();
                           }
                           float mono[2048];
                           u32 made = 0;
                           const auto sample = [&](s64 i) -> float {
                               if (i < 0) {
                                   return *previous;
                               }
                               float sum = 0.0f;
                               for (u32 c = 0; c < channels; ++c) {
                                   sum += data[c][i];
                               }
                               return sum / static_cast<float>(channels);
                           };
                           double at = *position;
                           while (at < static_cast<double>(frames) - 1.0 + 1e-9) {
                               const s64 i = static_cast<s64>(std::floor(at));
                               const float t = static_cast<float>(at - std::floor(at));
                               const float a = sample(i);
                               const float b = sample(std::min<s64>(i + 1, frames - 1));
                               mono[made++] = a + (b - a) * t;
                               if (made == 2048) {
                                   ring->Write(mono, made);
                                   made = 0;
                               }
                               at += step;
                           }
                           if (made > 0) {
                               ring->Write(mono, made);
                           }
                           *previous = sample(frames - 1);
                           // Counted from the last sample of this block (index -1 of the next).
                           *position = at - static_cast<double>(frames);
                         }];
    } @catch (NSException* exception) {
        LOG_WARNING(Lib_AudioIn, "MICROPHONE: not tapped: {}",
                    exception.reason.UTF8String ?: "?");
        return false;
    }
    LOG_INFO(Lib_AudioIn, "MICROPHONE: {} Hz, {} channels, to mono {} Hz", format.sampleRate,
             format.channelCount, SampleRate);
    return true;
}

/// (Re)starts the microphone's engine with a tap for the input it has now.
bool StartMicEngine() {
    if (!InstallMicTap()) {
        return false;
    }
    NSError* error = nil;
    bool started = false;
    @try {
        [g_mic_engine prepare];
        started = [g_mic_engine startAndReturnError:&error];
    } @catch (NSException* exception) {
        LOG_WARNING(Lib_AudioIn, "MICROPHONE: did not start: {}",
                    exception.reason.UTF8String ?: "?");
        return false;
    }
    if (!started) {
        LOG_WARNING(Lib_AudioIn, "MICROPHONE: did not start: {}",
                    error.localizedDescription.UTF8String ?: "?");
    }
    return started;
}

/// Starts taking the microphone when the title first opens it (StartMicEngine), with the engine
/// of its own on the session as it is (SDL would take the session down and set it up again,
/// which silences PHASE for a moment); it is tapped again whenever the input changes.
void StartMicrophone() {
    if (AVAudioSession.sharedInstance.recordPermission == AVAudioSessionRecordPermissionDenied) {
        LOG_INFO(Lib_AudioIn, "MICROPHONE: not allowed by the system; the title hears silence");
        return;
    }
    g_mic_engine = [[AVAudioEngine alloc] init];
    g_mic_ring = std::make_unique<Ring>(1, SampleRate);
    if (!StartMicEngine()) {
        g_mic_engine = nil;
        return;
    }
    [[NSNotificationCenter defaultCenter]
        addObserverForName:AVAudioEngineConfigurationChangeNotification
                    object:g_mic_engine
                     queue:nil
                usingBlock:^(NSNotification*) {
                  LOG_INFO(Lib_AudioIn, "MICROPHONE: its input changed, tapped again");
                  StartMicEngine();
                }];
    g_mic_on.store(true, std::memory_order_release);
}

} // namespace

bool OpenMicrophone() {
    static std::once_flag once;
    std::call_once(once, [] {
        if (!Available()) {
            return;
        }
        @autoreleasepool {
            StartMicrophone();
        }
    });
    return MicrophoneOn();
}

bool MicrophoneOn() {
    return g_mic_on.load(std::memory_order_acquire);
}

u32 MicrophoneQueued() {
    return MicrophoneOn() ? g_mic_ring->Queued() : 0;
}

u32 MicrophoneRead(float* mono, u32 count) {
    if (!MicrophoneOn()) {
        std::fill(mono, mono + count, 0.0f);
        return 0;
    }
    float* planes[1] = {mono};
    return g_mic_ring->Read(planes, 1, count);
}

void MicrophoneClear() {
    if (MicrophoneOn()) {
        g_mic_ring->SkipAll();
    }
}

void Watch() {
    if (!Available()) {
        return;
    }
    using Clock = std::chrono::steady_clock;
    static std::mutex mutex;
    static Clock::time_point last_check{};
    static Clock::time_point last_moved{};
    static Clock::time_point last_try{};
    static u64 last_pulls = 0;
    std::unique_lock lock{mutex, std::try_to_lock};
    if (!lock.owns_lock()) {
        return;
    }
    const auto now = Clock::now();
    if (now - last_check < std::chrono::milliseconds(100)) {
        return;
    }
    last_check = now;
    const u64 pulls = g_pulls.load(std::memory_order_relaxed);
    if (pulls != last_pulls || last_moved.time_since_epoch().count() == 0) {
        last_pulls = pulls;
        last_moved = now;
        return;
    }
    // Half a second without a single block asked for, and not tried for two.
    if (now - last_moved < std::chrono::milliseconds(500) ||
        now - last_try < std::chrono::seconds(2) || g_recovering.exchange(true)) {
        return;
    }
    last_try = now;
    const u64 stalled_ms = static_cast<u64>(
        std::chrono::duration_cast<std::chrono::milliseconds>(now - last_moved).count());
    std::thread([stalled_ms] {
        Recover(stalled_ms);
        g_recovering.store(false);
    }).detach();
}

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
            // SDL (the microphone) is to set the session up as it is set up here.
            SDL_SetHint(SDL_HINT_AUDIO_CATEGORY, "playandrecord");
            SetUpSession(session);
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
            // Changes of where the sound goes, for the log.
            [[NSNotificationCenter defaultCenter]
                addObserverForName:AVAudioSessionRouteChangeNotification
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification* note) {
                          const NSUInteger reason = [note.userInfo[AVAudioSessionRouteChangeReasonKey]
                              unsignedIntegerValue];
                          AVAudioSession* now = [AVAudioSession sharedInstance];
                          LOG_INFO(Lib_AudioOut,
                                   "SPATIAL_AUDIO: route changed (reason {}): {}, category {}",
                                   reason,
                                   now.currentRoute.outputs.firstObject.portType.UTF8String ?: "none",
                                   now.category.UTF8String ?: "?");
                        }];
            [[NSNotificationCenter defaultCenter]
                addObserverForName:AVAudioSessionInterruptionNotification
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification* note) {
                          const NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey]
                              unsignedIntegerValue];
                          LOG_INFO(Lib_AudioOut, "SPATIAL_AUDIO: session interrupted ({})",
                                   type == AVAudioSessionInterruptionTypeBegan ? "began" : "ended");
                        }];
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
