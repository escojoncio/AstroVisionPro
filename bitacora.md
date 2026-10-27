# Bitácora — AstroVisionPro

ASTRO BOT Rescue Mission (CUSA12392) y KITCHEN (CUSA06799), PSVR, en Apple Vision Pro (visionOS 27). Base shadPS4 ARM64 (HLE, cargador, kernel, PM4/Liverpool) + FEX (CPU, JIT) + VPKEngine (toda la GPU; único renderer en visionOS). App en `visionos/`, release `visionos-latest/AstroQuest.ipa`.
Detalle anterior en `git log -p bitacora.md`. Detalle técnico estable de la ruta GPU PS4: `notas/vpkengine-ps4.md`.

## Last done
- 2026-10-27 build ad66333 (app) + VPKEngine `unify/engine` 2a5eff2 (ref actualizado): arreglos de Registros_9. CI pendiente de resultado.
- Crash ASTRO (1x y 4x, carga de sala, hilo RoomLoad_ATQT): memcpy HLE (op 628) escribía en página guest RO; el rastreo protege páginas host de 16 KB pero el fallo solo soltaba rangos que solapaban 8 bytes → bucle. Ahora `Rasterizer::InvalidateHostPage` (page_manager.cpp, rasterizer_interface.h, vpkengine_renderer.mm) suelta toda la página; `RecentRanges<64>` 200 ms (`video_core/recent_ranges.h`); `PageManager::IsWriteProtected`; hasta 2 barridos; insert+protect de `watch()` bajo `watch_mutex`.
- Corrupción 1x (frames acumulados): el adaptador no tenía rastreo CMASK/HTILE (EliminateFastClear era no-op; log: todo color `c0:LS`). Portado `surface_metas` de shadPS4: `video_core/surface_metas.h`; Dispatch (hook `Hooks::computeBuffers`/`computeBuffersWanted` en vpps4, xor por opcode+neg+ds_swizzle, `complete=false` no salta), FillBuffer/CopyBuffer (`TryHtileClear`), clear sintético RectList antes del draw si la meta está limpia, EliminateFastClear real, `EraseRange` en UnmapMemory (vía `pendingUnmaps`). Formato no exacto en `fastClearColor` → no consume meta. Línea `vpps4.meta` cada 600 submits.
- Tests: VPKEngine ctest 448/448 (incl. `vpps4.compute_buffer_hook`); `test_recent_ranges`/`test_surface_metas` solo con shim (sin gtest local). .mm sin compilar en Linux.

## Current state (build ad66333, sin probar en visor)
- Esperado: sin crash en carga de sala de ASTRO; clears de color/depth (`gpu.enc` con `c0:C*`). Confirmar con `vpps4.meta` qué mecanismo usa ASTRO (cs/dma/eliminates/color_clears/depth_clears).
- Ojos mezclados: ambos ojos muestrean el mismo T# intermedio RGBA16F (luma NaN); si persiste tras los clears, causa distinta (unverified).
- MSAA 4x sin imagen antes del crash: no explicado (backend submit 434 ms/s, `resolve-dropped ... twin-unread`).
- `texfail` target MS mayor que su mapeo (`mapped=12582912 expected=18874368`): sin relacionar.
- Pipelines: `hold for pipelines` ~700 ms/s (2 fps), `missing_pipelines=33`.
- KITCHEN: crash SIGSEGV addr=0x18 en código guest (HavokWorkerThread, `call [rax+0x18]`) tras 4 `sceSystemServiceReportAbnormalTermination`; causa no investigada.
- Crash FEX MicrophoneThread / entitlements: sin cambios (ver git log de bitácora).

## Pendiente (orden)
1. Analizar logs de ad66333: crash de sala, `vpps4.meta`, `gpu.enc` clears, ojos, 4x.
2. KITCHEN addr=0x18; pipelines (hold/missing); NaN RGBA16F; texfail de mapeo MS.
3. Rendimiento GPU: memoryless/MSAA del core, caché de MTLLibrary en disco, `backend submit`, `alignedConstantCopy`.
4. Fusionar `unify/engine` en main de VPKEngine solo cuando la ruta PS4 funcione.
5. Futuro: PM4/Gnm/VideoOut en VPKEngine; CPU AOT si la CPU limita.

## Decisions
- VPKEngine es el único renderer en visionOS; KosmicKrisp/MoltenVK descartados (KK no era jugable: ~10 fps).
- Arreglos generales de GPU PS4, nunca por juego, dirección ni hash.
- Lo de PS4 en el motor compartido entra opt-in (setters/env); defaults = comportamiento de main.
- `constTables=false` para PS4 hasta tener imagen estable; `MetalOptions::renderCache=true` solo para PS4.
- shadPS4 se mantiene para HLE/kernel/PM4 mientras rinda.
- Diagnóstico solo con «Modo diagnóstico» salvo EYE_STATS/EYE_CHAIN; builds solo visionOS.

## Files in play
- App: `shadps4-arm64-main/src/platform/visionos/vpkengine_renderer.mm`, `core/fex/fex_guest_engine.cpp`, `core/memory.{h,cpp}`, `core/signals.cpp`, `shadps4-arm64-main/CMakeLists.txt` (bloque `VPKENGINE_GPU_DIR`), `visionos/vpkengine-gpu.ref`, `visionos/patches/fex-darwin.patch`, `.github/workflows/visionos-app.yml`.
- App: `src/video_core/{page_manager,surface_metas.h,recent_ranges.h}`.
- VPKEngine (`unify/engine`): `gpu/ps4/src/{renderer,lifetime,msaa}.cpp`, `gpu/ps4/include/vpps4/renderer.h`, `gpu/core/src/{device,frame_compiler}.cpp`, `gpu/metal2/src/metal_backend.mm`.

## Module index
- `notas/mapa.md`: cadena CPU/GPU/presentación, dónde está cada función, logs, app, CI.
- `notas/vpkengine-ps4.md`: ruta GPU PS4 sobre el motor unificado, causas ya resueltas, sondas, cómo medir, ramas y repos.
