# Bitácora — AstroVisionPro

ASTRO BOT Rescue Mission (CUSA12392) y KITCHEN (CUSA06799), PSVR, en Apple Vision Pro (visionOS 27). Base shadPS4 ARM64 (HLE, cargador, kernel, PM4/Liverpool) + FEX (CPU, JIT) + VPKEngine (toda la GPU; único renderer en visionOS). App en `visionos/`, release `visionos-latest/AstroQuest.ipa`.
Detalle anterior en `git log -p bitacora.md`. Detalle técnico estable de la ruta GPU PS4: `notas/vpkengine-ps4.md`.

## Last done
- 2026-10-28 (rama `shadow-pixels-v2` → main; motor `visionos/vpkengine-gpu.ref` = VPKEngine `shadow-mode` 816b34b): análisis de Registros_13 (sombra a4044ab) y arreglos. CI app OK (run 40628699938); ctest motor 481/481; shim app compare 17 / pixels 14. Nada probado en visor.
- Causa dominante medida en Registros_13: `skip[ps: texture unavailable]` 840396 (ASTRO) / 145816 (KITCHEN) por BC1-7 sin host (`gCaps.bc=false`: formatos 38/0, 39/0, 40/0, 41/0, 41/9). Además `upload ring full` (KITCHEN), `geometry scratch memory exhausted` (ASTRO) y T# 816x870 muestreando el target 896x896 completo. Sombra a4044ab: equal 1.9 % (ASTRO) / 0.05 % (KITCHEN), casi todo artefacto del comparador.
- Motor `gpu/ps4`: BC1-7 por software (`bc_block.h` único fuente C++/MSL, `bc_decode.cpp` envoltorio CPU, kernel `bcdecode` en `gpu_tiler.{h,cpp}` con detile fusionado, salida a scratch + `BufferToTexture`, dirty por nivel, prefetch del kernel si `!bc`, respaldo CPU solo si el kernel falla). Límites con `bc=false`: staging 128 MiB, 64 MiB decodificados/frame (`setMemoryLimits`), kernel compilando → draw omitido ("bc kernel compiling"/"bc decode budget"). Goldens `gpu/ps4/tests/kernels/*.metal` en `compile_all.sh`.
- Motor: ring de subida encadena y reintenta (`take()`, segmento dedicado si > chunk, indirecto reintenta el trío); `reclaimScratch()`; T# más pequeño que su RT → `mirrorTarget` (copia `TextureToTexture`, recopia por `writeSeq`/`version`; sin MSAA; integer-only sigue con el RT, `Resource::integerOnly` en caché de traducción bit 1); fallos de fill transitorios dejan `filled=false`; memo de programa `programKeyCached` con muestreo de contenido; `Texture::told` eliminado.
- Motor opt-in sombra de píxeles: `Hooks::seed`/`SeedImage` (D32Float, D16, D32FloatS8 con Z+stencil), `setGuestReadOnly`, `dropGuestBuffers()`, `Resolved::color[].cleared` real, `ResolvedBuffer.pointer`.
- App sombra: hash de programa común (`pgm_hash`), buffers por puntero solo si ambos lados, "pipeline compiling" único skip de host, formatos bit-idénticos (`BitIdenticalView`); captura de píxeles cada `ASTRO_SHADOW_PIXELS` s (10; 0 = off; presupuesto 500 ms, `ASTRO_SHADOW_PIXELS_BUDGET_MS`): Vulkan lee RT/depth/texturas GPU recortados a viewport∩scissor (`ShadowPixelsBefore/After`, `shadow_pixels.h`), segundo renderer VPK en Metal real con ventanas mmap privadas (`PixelEngine` en `vpkengine_renderer.mm`), log `ASTRO_PIXEL diff|summary`.
- CI motor `gpu.yml`: `replay-compare` falla también en el commit base e5a0fc5 (BPT trap en replay Metal del simulador): previo, no de gpu/ps4.

## Current state (sin probar en visor)
- Esperado tras la build: BC deja de saltar draws; menos `upload ring full`/`geometry scratch`; muestreo correcto de T# menores que su RT. Sin confirmar.
- Riesgo: memoria del visor con BC decodificado (BC7 ×4, BC6H ×8; ~564 MB libres en logs previos); kernel `bcdecode` compilado en CI pero nunca ejecutado en Metal; D32FloatS8/D24S8 no se siembra en Vulkan (draw omitido "depth format" en captura de píxeles).
- ASTRO 4x: ojo negro, "no draw wrote the eye target"; causa unverified: origen MS del resolve (`vpps4.resolve_src`, `empty_source`).
- KITCHEN: crash guest nulo (+0x8 GameThread, +0x18 Havok, +0x38 CastRay) tras assert del juego (`ASTRO_ABNORMAL_TEXT`); no es regresión de la GPU (unverified).
- Pendiente sin tocar (unverified): LDS fuera de compute por lane y `v_mbcnt` con máscara parcial = 0 (lift.cpp:5262, :1824); NaN RGBA16F; MSAA T# menor que el target usa el RT completo.
- Rendimiento: GpuCommandProcessor 99 % de un núcleo; ASTRO 19 fps guest, KITCHEN 25 fps (sombra, Registros_13); draw_adapter 478 ms/s.

## Pendiente (orden)
1. Registros con Motor gráfico = VPKEngine solo (ASTRO hasta menú start, KITCHEN hasta partida): leer `vpps4.frame` (`skip[...]` por motivo, incl. "bc decode budget"/"bc kernel compiling"), `footprint`/memoria, fps, `ASTRO_ABNORMAL_TEXT`.
2. Registros con Motor gráfico = Sombra (2-3 min): `ASTRO_SHADOW summary/top/diff` (ya solo diffs reales) y `ASTRO_PIXEL diff|summary` (primer draw divergente por RT, pct/maxerr/psnr, motivos skipped). Decidir cada diff contra GCN/Liverpool.
3. Arreglar por categoría en una sola build; si hace falta cobertura: sembrar D32S8/D24S8 en Vulkan, MSAA mirror, compute decoder con escritura directa.
4. Si persiste corrupción con diffs a cero: semántica GCN (lift.cpp:5262/:1824).
5. Fusionar VPKEngine `shadow-mode` → `unify/engine` → main solo cuando PS4 funcione.
6. Rendimiento GPU: CPU de `draw_adapter`/lookup de texturas, hilos de codificación, memoryless/MSAA, caché MTLLibrary, foveado.

## Decisions
- Referencia de la sombra = interpretación de shadPS4 (texture/buffer cache, decodificación), no la imagen de KosmicKrisp; cada diff se decide contra documentación GCN/Liverpool. Objetivo: paridad con shadPS4 y después superarlo (Metal nativo).
- VPKEngine es el único renderer en visionOS; KosmicKrisp/MoltenVK descartados (KK no era jugable: ~10 fps).
- Arreglos generales de GPU PS4, nunca por juego, dirección ni hash.
- Lo de PS4 en el motor compartido entra opt-in (setters/env); defaults = comportamiento de main.
- `constTables=false` para PS4 hasta tener imagen estable; `MetalOptions::renderCache=true` solo para PS4.
- shadPS4 se mantiene para HLE/kernel/PM4 mientras rinda.
- Diagnóstico solo con «Modo diagnóstico» salvo EYE_STATS/EYE_CHAIN; builds solo visionOS.
- Destino BC: scratch + `BufferToTexture` (texturas sin usage de escritura, compresión sin pérdida posible).

## Files in play
- Motor (`shadow-mode`): `gpu/ps4/src/{renderer,gpu_tiler,bc_decode,translation_cache}.cpp`, `gpu/ps4/include/vpps4/{renderer.h,bc_block.h,bc_decode.h,resolved.h}`, `gpu/ps4/tests/*`, `gpu/shader/ir/include/vpir/ir.h`, `gpu/shader/msl/tests/compile_all.sh`.
- App: `shadps4-arm64-main/src/video_core/{shadow_record.h,shadow_compare.h,shadow_pixels.h,tee_rasterizer.h}`, `renderer_vulkan/{vk_rasterizer.cpp,vk_pipeline_cache.cpp}`, `buffer_cache/buffer_cache.cpp`, `src/platform/visionos/vpkengine_renderer.mm`, `tests/video_core/test_shadow_{compare,pixels}.cpp`, `visionos/vpkengine-gpu.ref`.

## Module index
- `notas/mapa.md`: cadena CPU/GPU/presentación, dónde está cada función, logs, app, CI.
- `notas/vpkengine-ps4.md`: ruta GPU PS4 sobre el motor unificado, causas ya resueltas, sondas, cómo medir, ramas y repos; BC y sombra de píxeles.
