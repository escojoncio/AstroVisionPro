#pragma once
#include "common/types.h"
#include "video_core/amdgpu/regs.h"
struct DebugStateType { bool DumpingCurrentReg() { return false; } void PushRegsDump(u64, u64, const AmdGpu::Regs&) {} void PushRegsDumpCompute(u64, u64, const AmdGpu::ComputeProgram&) {} };
inline DebugStateType DebugState;
