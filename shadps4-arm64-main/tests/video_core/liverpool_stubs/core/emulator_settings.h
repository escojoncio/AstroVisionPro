#pragma once
struct EmulatorSettingsType { bool IsVkHostMarkersEnabled() { return false; } bool IsVkGuestMarkersEnabled() { return false; } bool IsCopyGpuBuffers() { return false; } };
inline EmulatorSettingsType EmulatorSettings;
