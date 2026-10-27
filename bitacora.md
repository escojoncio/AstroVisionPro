# Bitácora — AstroVisionPro

ASTRO BOT Rescue Mission (CUSA12392) y KITCHEN (CUSA06799), PSVR, en Apple Vision Pro (visionOS 27). Base shadPS4 ARM64 (HLE, cargador, kernel, PM4/Liverpool) + FEX (CPU, JIT) + VPKEngine (toda la GPU; único renderer en visionOS). App en `visionos/`, release `visionos-latest/AstroQuest.ipa`.
Detalle anterior en `git log -p bitacora.md`. Detalle técnico estable de la ruta GPU PS4: `notas/vpkengine-ps4.md`.

## Last done
- 2026-10-27 build 484dbfe (app) + VPKEngine `unify/engine` 79e9b85: arreglos de Registros_10. CI en curso.
- Ventanas guest de 64 MiB: `guestBuffer` (R `gpu/ps4/src/renderer.cpp`) ignoraba `size` → recursos que cruzan frontera recortados (HDR 0x705f400000 1440x1536 mapped=12582912/18874368; depth KITCHEN 0x712bcf0000). Ahora size real (tope 256 MiB), clave (base,size), `retireSuperseded`/`windowSuperseded`, tabla FLAT disjunta (base asc, size desc), `shrinkRegion` si Metal rechaza, fallo cacheado por generación o 120 frames. App: `readable()` mismo tope; `vpkengine_mirror.cpp` índice (begin,end) + retirada de mirrors solapados obsoletos.
- Buffers rechazados (gpu.err size=55099392/67108864 en carga de sala → draws con dirección 0): `Device::setRefuseFailedBuffers(true)` (opt-in, solo PS4) → BufferId{} → "bound as zeros"; metal2 `bufferCreated`, log `gpu.metal.info what=buffer_refused` con vm_region. Causa del nil sin conocer.
- Depth a memoria: D32Float/D16/D32FloatS8 por planos (`planesOf`, `retilePlane`, `agreedBase`), solo planos autoritativos (clear completo o fill); antes "image cannot be retiled" fmt=84 → lectores raw veían basura.
- Diagnóstico: `vpps4.resolve_src` (4x: origen del resolve al ojo), `ASTRO_ABNORMAL_TEXT` en `sceSystemServiceReportAbnormalTermination` (systemservice.cpp, `Core::DumpGuestText` en signals.cpp).
- Build anterior ad66333: crash de carga de sala ASTRO resuelto (confirmado en Registros_10); CMASK funciona (`vpps4.meta` cs_meta_writes≈color_clears).
- ctest motor 454/454; código Apple sin compilar en Linux.

## Current state (build 484dbfe, sin probar en visor)
- ASTRO 1x (Registros_10): corrupción en menú y mucho peor tras la carga de sala. Esperado: mejora por ventanas y buffers; sin confirmar.
- ASTRO 4x: ojo negro, "no draw wrote the eye target"; `resolve_dropped twin-unread` es interno y correcto. Causa unverified: origen MS del resolve explícito (leer `vpps4.resolve_src`, `empty_source`).
- KITCHEN: crash guest nulo (+0x8 GameThread, +0x18 Havok, +0x38 CastRay) tras assert del juego (ReportAbnormalTermination desde eboot+0x19dabf2); no es regresión de ad66333. Leer `ASTRO_ABNORMAL_TEXT`; relación con depth recortada unverified.
- Pendiente sin tocar (unverified): LDS fuera de compute por lane y `v_mbcnt` con máscara parcial = 0 (lift.cpp:5262, :1824); fill de D32FloatS8 desde memoria; NaN RGBA16F; caché vieja descartada (archivos .metalar validados por contenido).
- Rendimiento: backend submit 388 ms/s (4x), frame compile 19 ms/s (1x).

## Pendiente (orden)
1. Logs de 484dbfe: `buffer_refused`/`guest_buffer_refused`, `tiled outside guest memory` (debe ser 0), `resolve_src`, `ASTRO_ABNORMAL_TEXT`, `gpu.err`, missing_resources.
2. Semántica GCN: LDS en PS/VS, v_mbcnt, si la corrupción persiste.
3. Rendimiento GPU (memoryless/MSAA, caché MTLLibrary, backend submit).
4. Fusionar `unify/engine` en main de VPKEngine solo cuando PS4 funcione.

## Decisions
- VPKEngine es el único renderer en visionOS; KosmicKrisp/MoltenVK descartados (KK no era jugable: ~10 fps).
- Arreglos generales de GPU PS4, nunca por juego, dirección ni hash.
- Lo de PS4 en el motor compartido entra opt-in (setters/env); defaults = comportamiento de main.
- `constTables=false` para PS4 hasta tener imagen estable; `MetalOptions::renderCache=true` solo para PS4.
- shadPS4 se mantiene para HLE/kernel/PM4 mientras rinda.
- Diagnóstico solo con «Modo diagnóstico» salvo EYE_STATS/EYE_CHAIN; builds solo visionOS.

## Files in play
- App: `shadps4-arm64-main/src/platform/visionos/vpkengine_renderer.mm`, `core/fex/fex_guest_engine.cpp`, `core/memory.{h,cpp}`, `core/signals.cpp`, `shadps4-arm64-main/CMakeLists.txt` (bloque `VPKENGINE_GPU_DIR`), `visionos/vpkengine-gpu.ref`, `visionos/patches/fex-darwin.patch`, `.github/workflows/visionos-app.yml`.
- App: `src/video_core/{page_manager,surface_metas.h,recent_ranges.h}`, `platform/visionos/vpkengine_mirror.cpp`, `core/signals.cpp`, `core/libraries/system/systemservice.cpp`.
- VPKEngine (`unify/engine`): `gpu/ps4/src/{renderer,lifetime,msaa}.cpp`, `gpu/ps4/include/vpps4/renderer.h`, `gpu/core/src/device.cpp`, `gpu/metal2/src/metal_backend.mm`, `gpu/core/src/{device,frame_compiler}.cpp`, `gpu/metal2/src/metal_backend.mm`.

## Module index
- `notas/mapa.md`: cadena CPU/GPU/presentación, dónde está cada función, logs, app, CI.
- `notas/vpkengine-ps4.md`: ruta GPU PS4 sobre el motor unificado, causas ya resueltas, sondas, cómo medir, ramas y repos.
