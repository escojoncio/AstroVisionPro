#pragma once
namespace Platform {
enum class InterruptId { GfxEop, GpuIdle, GfxFlip, Compute0RelMem };
struct IrqC { static IrqC* Instance() { static IrqC i; return &i; } void Signal(InterruptId, unsigned long long = 0) {} };
}
