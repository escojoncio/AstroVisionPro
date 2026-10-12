// VPEngine renderer, shadow mode («Motor gráfico: VPEngine (sombra)»): every draw and dispatch the
// emulator records is also turned into VPEngine work (vpps4::Renderer: lifted GCN shaders, Metal
// pipelines, guest memory used in place) and run on the GPU through VPEngine's own Metal backend.
// The picture still comes from the Vulkan path; the log reports what VPEngine ran and what it cost
// ("VPENGINE_GPU ..." lines: draws run / skipped and why, encoders, GPU ms per frame).
#pragma once

#include <cstdint>

#include "common/types.h"

namespace Shader {
struct Info;
}
namespace AmdGpu {
union Regs;
struct ComputeProgram;
}

namespace VpengineRenderer {

// SHADPS4_VPENGINE_RENDERER=1 (set by the app's graphics engine setting).
bool Enabled();

// After the Vulkan pipeline is known: its vertex and pixel stage infos (pixel may be null).
void Draw(const AmdGpu::Regs& regs, const Shader::Info& vs, const Shader::Info* ps, bool indexed,
          u32 index_offset);
void Dispatch(const AmdGpu::ComputeProgram& program, const Shader::Info& cs);
// CB_COLOR_CONTROL.MODE = RESOLVE: CB0 resolved into CB1 (a copy: VPEngine renders at 1 sample).
void Resolve(const AmdGpu::Regs& regs);
// (Indirect draws and dispatches are not run yet: their arguments live in GPU memory.)
// The CPU wrote guest memory.
void Invalidate(VAddr address, u64 size);
// A frame was presented: VPEngine submits what it recorded since the last one.
void EndFrame();

} // namespace VpengineRenderer
