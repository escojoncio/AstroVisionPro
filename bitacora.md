# Bitácora — AstroVisionPro

ASTRO BOT Rescue Mission (CUSA12392) y KITCHEN (CUSA06799), PSVR, en Apple Vision Pro (visionOS 27). Base shadPS4 ARM64 (HLE, cargador, kernel, PM4/Liverpool) + FEX (CPU, JIT) + VPKEngine (toda la GPU; único renderer en visionOS). App en `visionos/`, release `visionos-latest/AstroQuest.ipa`.
Detalle anterior en `git log -p bitacora.md`. Detalle técnico estable de la ruta GPU PS4: `notas/vpkengine-ps4.md`.

## Last done
- 2026-10-28 (motor VPKEngine `fix-resolve-extent` 7d1a382, ref actualizado): Registros_15 (c9a164a, VPKEngine solo, ASTRO): ojo negro resuelto (EYE_STATS luma 0.29/0.26), pero fps guest 30→8 en 100 s, footprint 2791→6528 MB (motor reporta GPU 0 MB), GpuCommandProcessor 20→99 %, 2.1 M `unaligned constant buffer copied`, 137 `no staging memory for a tiled texture`, 303 `staging memory limit reached`, resolves_dropped 1672. Cambios (`gpu/ps4/src/renderer.cpp`, `memory_tracker.*`, tests): dedup de CB desalineado 64→4096 entradas con clave address+bytes+versión y memcmp en acierto; `gpuBytesOf` cuenta mips, twin MS y depth; `evict()` salta bytes==0; `tex.bytes` (layout) cacheado al crear la textura; sonda `VPKENGINE_PROBE P7` (tracker_spans(_max), forget_history, ring_chains, aligned_copy_bytes, gpu_bytes, targets, textures, staging_live) cada 600 frames. ctest 492/492 (Linux); Metal sin ejecutar. Son cambios de contabilidad/coste; la causa de la memoria sigue unverified hasta leer P7.
- 2026-10-28 (rama `fix-resolve-extent` → main; motor ref 7ca6207, VPKEngine rama `fix-resolve-extent`): Registros_14 (ef2d65e, VPKEngine solo) mostró `skipped=0` y ningún BC: los skips BC de Registros_13 eran de la sombra (forzaba `fc.bc=false`). Causa real del ojo negro 4x y distorsión 1x: el Resolve del adaptador (`vpkengine_renderer.mm`) construía src/dst con pitch/alto (832x896, 1472x1536) en vez del extent del título (`last_cb_extent`: 816x870, 1440x1536) → `resolve()` del motor creaba targets nunca dibujados y resolvía MS vacío (4x) o memoria vieja (1x). Arreglo: `vpkengine_extent.h` `TargetExtents::Apply` (hint, si no caché por dirección solo con registros+formato idénticos, tope 256) usado por Draw y Resolve; motor `resolve()` elige el target dibujado (lastDraw, área, muestras) si no hay exacto dibujado, dst `min(dst, origen)` solo si el origen es menor; `mirrorTarget` refresca antes de la guarda (`lastDraw==never && writeSeq==0` → target entero) y copia `min(desc, target)`. Sondas `VPKENGINE_PROBE P1/P6`, `vpps4.probe P2-P5` (40 primeros, luego cada 600). Sombra: `fc.bc` del dispositivo. ctest 489/489; CI app 40692355534 OK.
- 2026-10-28 (rama `shadow-pixels-v2` → main; motor `visionos/vpkengine-gpu.ref` = VPKEngine `shadow-mode` 816b34b): análisis de Registros_13 (sombra a4044ab) y arreglos. CI app OK (run 40628699938); ctest motor 481/481; shim app compare 17 / pixels 14. Nada probado en visor.
- Causa dominante medida en Registros_13: `skip[ps: texture unavailable]` 840396 (ASTRO) / 145816 (KITCHEN) por BC1-7 sin host (`gCaps.bc=false`: formatos 38/0, 39/0, 40/0, 41/0, 41/9). Además `upload ring full` (KITCHEN), `geometry scratch memory exhausted` (ASTRO) y T# 816x870 muestreando el target 896x896 completo. Sombra a4044ab: equal 1.9 % (ASTRO) / 0.05 % (KITCHEN), casi todo artefacto del comparador.
- Motor `gpu/ps4`: BC1-7 por software (`bc_block.h` único fuente C++/MSL, `bc_decode.cpp` envoltorio CPU, kernel `bcdecode` en `gpu_tiler.{h,cpp}` con detile fusionado, salida a scratch + `BufferToTexture`, dirty por nivel, prefetch del kernel si `!bc`, respaldo CPU solo si el kernel falla). Límites con `bc=false`: staging 128 MiB, 64 MiB decodificados/frame (`setMemoryLimits`), kernel compilando → draw omitido ("bc kernel compiling"/"bc decode budget"). Goldens `gpu/ps4/tests/kernels/*.metal` en `compile_all.sh`.
- Motor: ring de subida encadena y reintenta (`take()`, segmento dedicado si > chunk, indirecto reintenta el trío); `reclaimScratch()`; T# más pequeño que su RT → `mirrorTarget` (copia `TextureToTexture`, recopia por `writeSeq`/`version`; sin MSAA; integer-only sigue con el RT, `Resource::integerOnly` en caché de traducción bit 1); fallos de fill transitorios dejan `filled=false`; memo de programa `programKeyCached` con muestreo de contenido; `Texture::told` eliminado.
- Motor opt-in sombra de píxeles: `Hooks::seed`/`SeedImage` (D32Float, D16, D32FloatS8 con Z+stencil), `setGuestReadOnly`, `dropGuestBuffers()`, `Resolved::color[].cleared` real, `ResolvedBuffer.pointer`.
- App sombra: hash de programa común (`pgm_hash`), buffers por puntero solo si ambos lados, "pipeline compiling" único skip de host, formatos bit-idénticos (`BitIdenticalView`); captura de píxeles cada `ASTRO_SHADOW_PIXELS` s (10; 0 = off; presupuesto 500 ms, `ASTRO_SHADOW_PIXELS_BUDGET_MS`): Vulkan lee RT/depth/texturas GPU recortados a viewport∩scissor (`ShadowPixelsBefore/After`, `shadow_pixels.h`), segundo renderer VPK en Metal real con ventanas mmap privadas (`PixelEngine` en `vpkengine_renderer.mm`), log `ASTRO_PIXEL diff|summary`.
- CI motor `gpu.yml`: `replay-compare` falla también en el commit base e5a0fc5 (BPT trap en replay Metal del simulador): previo, no de gpu/ps4.

## Current state (sin probar en visor)
- Registros_14 (ef2d65e): 4x ojo negro (luma 0, resolves_dropped 5557/5946 = síntoma); 1x imagen distorsionada; fps 4x ~8 (backend submit 556 ms/s, gpu 78 ms), 1x ~22 (29→24 guest), memoria 1x 2678→4163 MB (causa unverified: leer `P3 mem`). Notas presentes: "staging memory limit reached: copy source refused", "no staging memory for a tiled texture", "GPU detile/retile refused".
- Sombra a MSAA 4: `ASTRO_PIXEL` comparó 1 draw por captura (skips: vk:msaa, depth msaa, depth layers/mips, multi viewport, buffer written by GPU). Para comparar píxeles hace falta MSAA 1 o ampliar cobertura.
- Esperado tras la build: BC deja de saltar draws; menos `upload ring full`/`geometry scratch`; muestreo correcto de T# menores que su RT. Sin confirmar.
- Riesgo: memoria del visor con BC decodificado (BC7 ×4, BC6H ×8; ~564 MB libres en logs previos); kernel `bcdecode` compilado en CI pero nunca ejecutado en Metal; D32FloatS8/D24S8 no se siembra en Vulkan (draw omitido "depth format" en captura de píxeles).
- ASTRO 4x: ojo negro, "no draw wrote the eye target"; causa unverified: origen MS del resolve (`vpps4.resolve_src`, `empty_source`).
- KITCHEN: crash guest nulo (+0x8 GameThread, +0x18 Havok, +0x38 CastRay) tras assert del juego (`ASTRO_ABNORMAL_TEXT`); no es regresión de la GPU (unverified).
- Pendiente sin tocar (unverified): LDS fuera de compute por lane y `v_mbcnt` con máscara parcial = 0 (lift.cpp:5262, :1824); NaN RGBA16F; MSAA T# menor que el target usa el RT completo.
- Rendimiento: GpuCommandProcessor 99 % de un núcleo; ASTRO 19 fps guest, KITCHEN 25 fps (sombra, Registros_13); draw_adapter 478 ms/s.

## Pendiente (orden)
0. Registros con VPKEngine solo: leer `VPKENGINE_PROBE P7` (¿gpu_bytes explica 2791→6528 MB? ¿tracker_spans_max cerca de 131072 y forget_history>0 → refills masivos?). Hipótesis a verificar con P7: MemoryTracker `forgetHistory` (memory_tracker.cpp:46) fuerza refill de todo; barridos O(n) en markSynced/release; evicción solo cada 16 submits. No leídos aún: metal_backend.mm (heaps/views/MTLLibrary), frame_compiler.cpp, device.cpp.
1. Registros con VPKEngine solo (4x y 1x): confirmar ojo con imagen y sin distorsión; leer `VPKENGINE_PROBE P1` (override=hint|cache) y `P6`, `vpps4.probe P2` (from dibujado), `P3 mem` (crecimiento). Antes: Registros con Motor gráfico = VPKEngine solo (ASTRO hasta menú start, KITCHEN hasta partida): leer `vpps4.frame` (`skip[...]` por motivo, incl. "bc decode budget"/"bc kernel compiling"), `footprint`/memoria, fps, `ASTRO_ABNORMAL_TEXT`.
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
