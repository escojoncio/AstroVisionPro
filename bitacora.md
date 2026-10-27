# Bitácora — AstroVisionPro

ASTRO BOT Rescue Mission (CUSA12392) y KITCHEN (CUSA06799), PSVR, en Apple Vision Pro (visionOS 27). Base shadPS4 ARM64 + FEX (JIT) + VPKEngine (único renderer en visionOS). App en `visionos/`, release `visionos-latest/AstroQuest.ipa`.
Detalle anterior a 2026-10-27 en `git log -p bitacora.md`.

## Last done
- 2026-10-27: bitácora compactada (377 → <100 líneas); mapa estable a `notas/mapa.md`. Logs del visor 02:54 y 02:55 (Registros_5/2) recibidos: 14 volcados `gpu-hang-*.metal`.
- 2026-10-25: `.claude/agents/{coder,reader,Explore}.md`; `CLAUDE.md` línea 1 (cumplir el rol).
- 2026-10-20: `fix-device3`: `report()` con `VPKENGINE_GPU cpu bind phases`; ref VPKEngine → `b2a447b` (ps4/integration).
- 2026-10-20: `fix-device1`: `PrepareLabelWait`/`IdleLabelWait` en `WaitRegMem` (sin bucle caliente), `EYE_STATS`, `ExplainAddress`, prewarm del pipeline de composición.
- 2026-10-20: `ps4/integration` une ramas state, coherence, tiling, msaa, gs, cpucost, submit, pm4 (VPKEngine `PROGRESS-integration.md`); revisión adversarial (`resolveOwned` 200 ms, `GuestMirror` 5 s).

## Current state
- Funciona: arranque bajo FEX, menús de ASTRO BOT con VPKEngine (historial), audio, mando, pantalla plana en el visor, diálogos VR HLE.
- Roto (build actual, log 2026-10-27): ASTRO BOT ojos negros + fps pésimo + entrada con 30–60 s de retraso; KITCHEN sin imagen. GPU hangs volcados. Causa raíz: pendiente de análisis (unverified).
- VPKEngine vp4 (`gpu/ps4/engine/*`) es copia aislada de `gpu/metal2` desde 2026-10-20 (merge-base `f18e8a6`); ninguna mejora de main posterior llega a PS4 (memoryless/MSAA, slots VP_CB_ORDER, prioridad PSO, elisión de estado por draw, unpack nativo, etc.).
- Ramas `ps4/*` en este repo y en VPKEngine: integradas en `ps4/integration`; main de este repo apunta a ese ref.
- Pendiente: imagen en ojos (ASTRO: ojos = slices de target array producidos por draws ES/LS/GS); KITCHEN luz plana (sombras por copias en bruto) — histórico KK, sin verificar con VPKEngine.
- Sin implementar: PS Move; posición del mando sin manos; ImGui (diálogos del sistema no se ven con VPKEngine).

## Decisions
- VPKEngine es el único renderer en visionOS; KosmicKrisp/MoltenVK fuera (código Vulkan aún enlazado).
- Arreglos generales de GPU PS4, nunca por juego; KITCHEN y ASTRO son pruebas del mismo emulador.
- No más cambios en KosmicKrisp.
- Diagnóstico solo con «Modo diagnóstico»; lo medido va fijo en `AstroSettings.environment`.
- Builds solo visionOS (`xros` + simulador), nunca macOS.

## Files in play
- `shadps4-arm64-main/src/platform/visionos/vpkengine_renderer.{h,mm}`, `vpkengine_mirror.cpp`, `vpkengine_presenter.{h,cpp}`
- `shadps4-arm64-main/src/video_core/amdgpu/liverpool.cpp`, `video_core/rasterizer_interface.h`, `core/libraries/hmd/hmd_reprojection.cpp`
- `shadps4-arm64-main/src/core/vr/openxr_host_visionos.mm`, `visionos/App/Render/GameRenderer.swift`
- `visionos/vpkengine-gpu.ref`, `.github/workflows/visionos-app.yml`, `shadps4-arm64-main/CMakeLists.txt` (bloque `VPKENGINE_GPU_DIR`)
- VPKEngine: `gpu/ps4/engine/metal/src/metal_backend.mm` (vp4) frente a `gpu/metal2/src/metal_backend.mm` (main)

## Module index
- `notas/mapa.md`: cadena CPU/GPU/presentación, dónde está cada función, logs de VPKEngine, app, CI y comprobación local.
