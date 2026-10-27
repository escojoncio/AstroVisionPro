# Bitácora — AstroVisionPro

ASTRO BOT Rescue Mission (CUSA12392) y KITCHEN (CUSA06799), PSVR, en Apple Vision Pro (visionOS 27). Base shadPS4 ARM64 + FEX (JIT) + VPKEngine (único renderer en visionOS). App en `visionos/`, release `visionos-latest/AstroQuest.ipa`.
Detalle anterior a 2026-10-27 en `git log -p bitacora.md`.

## Last done
- 2026-10-27 (VPKEngine c7737aa; ref → c7737aa): `gpu/ps4/src/renderer.cpp` `Impl::resolve()`: clear pendiente del destino (o su compañero MS) se descarta si el resolve lo cubre entero, si no `flushClear(*to)` antes de resolver (antes se emitía después y borraba el resolve → ojos negros con MSAA; con MSAA 1x había imagen); origen del resolve prefiere target MS solo en empate de `lastUse`; contadores `resolveDestClearDropped/Flushed`; 5 tests en `tests/msaa_tests.cpp`.
- 2026-10-27 (app 71acabd): ASTRO_CRASH también al log del emulador (`Common::Log::WriteRaw`, fd del sink), «last HLE syscall» frente a «guest rip at fault» (`BachataQueryGuestRipAtHostPc` → FEX `RestoreRIPFromHostPC`, límites de `JitArena`), dladdr en código host, HLE en curso, guarda de reentrada; `sceSystemServiceReportAbnormalTermination` registra registros + `DumpGuestState` (3 primeras), sigue devolviendo OK (no hay salida limpia del juego en visionOS).
- 2026-10-27 (VPKEngine ps4/integration 119e02a..f33783c; `visionos/vpkengine-gpu.ref` → f33783c): anillo GSVS al layout de hardware (`gcn/src/lift.cpp` liftRing/gsEmit: planos de 64 B, grupos de 16 lanes; test `gcn.geom.astro` con palabras reales) → causa de ojos negros de ASTRO (posición (x,0,0,0)); caché de 8 regiones en vpps4 `Impl::region()`; hold en dos regímenes (`core/src/device.cpp` takeFrame: calentamiento 1500 ms/120 frames/10 s, estable `VPKENGINE_HOLD_MS`=12 ms solo draws; Dispatch/ES/GS siempre completo; `Draw::expandedBy` → `expansion_pending`); port metal2 de main 48ba0cf, c06a96a, f6f2de5 (parcial), a7136b6, d2ab444 (parcial); sondas `backingAt`/`DrawProbe`.
- 2026-10-27 (app): `vpkengine_renderer.mm`: SpanCache por `MappingGeneration()` (sin vaciado cada 8 ms; negativos cacheados; reintento de mirror 16 ms), `framesInFlight` 3 (`VPKENGINE_FRAMES_IN_FLIGHT`), líneas `cpu region caches` y `cpu submit phases`, drain antes de EYE_STATS, sondas `EYE_CHAIN` (siempre) / `EYE_PS`, `EYE_GS` (diagnóstico).
- 2026-10-27 (app): pad `ReadStates` → `DrainNewest` (sin backlog de 64), `PushMotionState`, sonda `CrossProbe` (flanco de Cross → entrega, ms); `hmd_setup_dialog_state.h`: máquina de estados real (sin Open nunca FINISHED; VrServiceDialog sin cambio); `signals.cpp` `DescribeGuest` (GPR, código guest ±0x40 con módulo+offset) + anillo de 32 HLE por hilo (`fex_hle_bridge.cpp`).
- 2026-10-27: bitácora compactada; mapa estable a `notas/mapa.md`.
- 2026-10-20: `ps4/integration` une ramas state, coherence, tiling, msaa, gs, cpucost, submit, pm4 (VPKEngine `PROGRESS-integration.md`).

## Current state
- Funciona: arranque bajo FEX, menús de ASTRO BOT con VPKEngine (historial), audio, mando, pantalla plana en el visor, diálogos VR HLE.
- Diagnóstico log 2026-10-27 (antes de los arreglos): ASTRO en VR ~10 fps, todos los draws hechos, target de ojo a ceros (bug GSVS); `buffer lookup` ~487 ms/s (vm_region tras vaciados de caché); KITCHEN presenta pantalla plana y cae a los ~5 s con null en código del juego (eboot+0x1acd37e) tras UpdateStatus sin Open; `gpu-hang-*.metal` de otra ejecución (VS raymarch con bucle hasta vp_guard 65536).
- Build b707d90 probada (logs 10:31–10:46): Cross llega en 3–172 ms; KITCHEN pasa el diálogo, muestra 2D y cae (ReportAbnormalTermination de WorkerThread → nulo colateral en GameThread); ASTRO ojos negros con MSAA 4x (EYE_CHAIN: fuente = resolve de `color_*_ms` a 0), con imagen con MSAA 1x y crash en código host al crear MicrophoneThread (HLE sin identificar).
- Reunificación con VPKEngine main: plan hecho (fase 1 core+metal2+vpps4+app, fase 2 ir/msl/gcn); base común real 7db7cd2; a metal2 de main le faltan completedFrames/waitFramesBelow/waitAll/encodeInterop/notify de frame; riesgo de doble decisión memoryless/stores (vpps4 lifetime frente a core de main).
- Auditoría GCN/MSL (sin cambios): `gpu-hang-*.metal` vienen del camino SPIR-V/Vulkan (`gpu/shader/spirv/src/lower.cpp`, guard 65536 `gpu/vulkan/src/recipes.h:87`), no del lifter GCN. Pendientes (unverified): `int(x)` sin saturar en `lower.cpp:3151-3168`; `max/min` en vez de `fmax/fmin` (`ps4/engine/msl/src/msl.cpp:921`) con `MTLMathModeFast`; guard por etapa; CB sin alinear copiado al grabar (`gpu/ps4/src/renderer.cpp:3243`, `alignedConstantCopy` :584) no ve escrituras GPU del mismo frame (320/frame en ASTRO) → posible constante vieja.
- Retraso de entrada de 30–60 s: cola de pad explica ~0,5 s; resto probablemente carga lenta (primer frame a ~27 s) (unverified).
- VPKEngine vp4 (`gpu/ps4/engine/*`) es copia aislada de `gpu/metal2` (merge-base `7db7cd2`); core vp4 divergido ~800 líneas (label_queue, submit_policy, Scheduler). No portado de main: 7538816 (choca con RenderCache vp4), 308ccb2, memoria/MSAA (política en core), 51b78be. Reunificación completa: siguiente paso si hay imagen.
- No existe caché en disco de MTLLibrary (newLibraryWithSource en cada arranque, ms_max 252); opción: cachear el MSL traducido.
- Ramas `ps4/*` en este repo y en VPKEngine: integradas en `ps4/integration`; main de este repo apunta a ese ref.
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
