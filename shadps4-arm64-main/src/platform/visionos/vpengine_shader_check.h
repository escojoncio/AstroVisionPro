// VPEngine shader check (diagnostic mode): every guest shader the emulator compiles is also lifted
// by VPEngine's GCN -> VPIR translator with the draw's real state, turned into Metal Shading
// Language and compiled with the headset's own Metal compiler. Results go to the log
// ("VPENGINE_SHADER ..." lines and a running tally); MSL that fails, and lift errors, are written
// to <shader dir>/vpengine/ for inspection. Rendering is not affected.
#pragma once

#include <cstddef>
#include <cstdint>
#include <span>

namespace Shader {
struct Info;
struct RuntimeInfo;
} // namespace Shader

namespace VpengineShaderCheck {

// SHADPS4_VPENGINE_SHADER_CHECK=1 (the app's «Modo diagnóstico»).
bool Enabled();

// Call after the program is translated (info knows its fetch shader). Returns at once: the Metal
// compile runs in the background.
void Check(std::span<const uint32_t> code, const Shader::Info& info, const Shader::RuntimeInfo& runtime,
           size_t perm_idx);

} // namespace VpengineShaderCheck
