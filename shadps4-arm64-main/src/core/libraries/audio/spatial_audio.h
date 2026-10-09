// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include "common/types.h"

// The headset's own 3D audio, as PlayStation VR does it: the title hands the console each sound
// of its 3D audio port on its own, placed relative to the wearer's head, and the console renders
// them for the headphones with a head-related transfer function; surround ports are heard from
// speakers around the head. Here Apple's PHASE does the rendering (spatial_audio_visionos.mm).
//
// Head-locked: the title already places every sound relative to the head it is told about, so
// the listener stays put and the system's own spatialization is bypassed (it would turn the
// sound with the head a second time).
namespace Libraries::SpatialAudio {

/// Starts the engine once (SHADPS4_SPATIAL_AUDIO=0 keeps it off); false when it is not there.
bool Start();
bool Available();

/// A voice that plays a stream as it is, in both ears (stereo or mono ports). -1 if none left.
int OpenStereo();
/// A voice heard from a direction: +X right, +Y up, +Z behind, metres. -1 if none left.
int OpenFixedSpatial(float x, float y, float z);
void Close(int voice);

/// Adds interleaved frames (2 channels for a stereo voice, 1 for a spatial one); what does not
/// fit is dropped.
void Write(int voice, const float* frames, u32 count);
/// Frames waiting to be played.
u32 Queued(int voice);
/// Frames the device takes at a time.
u32 DeviceFrames();

/// The title's 3D objects: one block of mono sound for the object `key`, placed (head-relative)
/// and scaled by `gain`. False when every voice is taken (the caller mixes it itself).
bool WriteObject(u64 key, const float* mono, u32 count, float x, float y, float z, float gain);
/// Called once per block of the 3D port: objects silent for a while give their voice back.
void ObjectsTick();

/// Called often by whoever writes to the voices: when PHASE has stopped asking for sound (the
/// audio session was taken down under it), it is started again.
void Watch();

} // namespace Libraries::SpatialAudio
