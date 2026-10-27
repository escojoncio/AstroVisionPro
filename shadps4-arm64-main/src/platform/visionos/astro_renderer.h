// Which renderer runs the GPU on visionOS, chosen at run time by the environment variable
// ASTRO_RENDERER (the app's «Motor gráfico», AstroSettings.swift):
//   vpkengine  VPKEngine's own Metal renderer (the default).
//   vulkan     shadPS4's Vulkan renderer on KosmicKrisp (MoltenVK when it is not in the app).
//   shadow     Vulkan is the renderer that draws, writes memory and presents; VPKEngine runs beside
//              it (gnmdriver.cpp RegisterLib: the Tee is still to be made, it is Vulkan alone).
// Both renderers are always compiled in (SHADPS4_VPKENGINE_RENDERER); without VPKEngine's sources
// the build has Vulkan alone and that is what this answers.
#pragma once

#include <cstdlib>
#include <string_view>

namespace AstroRenderer {

enum class Kind { Vpkengine, Vulkan, Shadow };

inline Kind Selected() {
#ifdef SHADPS4_VPKENGINE_RENDERER
    static const Kind kind = [] {
        const char* value = std::getenv("ASTRO_RENDERER");
        const std::string_view name = value != nullptr ? value : "";
        if (name == "vulkan") {
            return Kind::Vulkan;
        }
        if (name == "shadow") {
            return Kind::Shadow;
        }
        return Kind::Vpkengine;
    }();
    return kind;
#else
    return Kind::Vulkan;
#endif
}

/// The Vulkan renderer is made (vulkan, shadow): its presenter, rasterizer and driver exist.
inline bool UsesVulkan() {
    return Selected() != Kind::Vpkengine;
}

} // namespace AstroRenderer
