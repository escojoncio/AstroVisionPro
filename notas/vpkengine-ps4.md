# Ruta GPU PS4 sobre VPKEngine (estado 2026-10-27)

## Repos y ramas
- VPKEngine: rama `unify/engine` (7c1f1cf) = main (6181b91) + ruta PS4 unificada. `ps4/integration` (c7737aa) = versión anterior con copia congelada `gpu/ps4/engine/{core,metal,ir,msl,gcn}` (namespaces vp4*), útil para comparar semántica.
- El historial de main y ps4/integration se reescribió el 2026-10-27 (mismos árboles, hashes nuevos; base común real 7db7cd2).
- La app compila el motor desde el commit de `visionos/vpkengine-gpu.ref` (CI lo clona por SHA; el commit debe estar subido).

## Estructura unificada
- `gpu/core` (vpgpu): Device, Frame, frame_compiler, PipelineCache, LabelQueue, SubmitPolicy. Añadido para PS4: hilo de envío (`startSubmitThread`), `afterFrame`/`pumpLabels`/`waitLabels`, hold de dos regímenes (`setHoldSteadyMs`, `setHoldWarmupFrames`; env `VPKENGINE_HOLD_MS`/`VPKENGINE_HOLD_WARMUP_FRAMES`; Dispatch/ES/GS siempre hold completo; `Draw::expandedBy` → `badDraws` «expansion_pending»), `lockBackend()` solo con hilo de envío, `Frame::hasExpansion()`.
- `gpu/metal2`: `completedFrames` real (antes ~0), `waitFramesBelow`, `waitAll`, `notifyFrameDone` (solo desde el handler de completado), `takeSlotWaitMs`, `caps.bc`, `encodeInterop`, `FrameDoneGate`, caché de estado de render (`MetalOptions::renderCache`, env `VPKENGINE_RENDER_CACHE`), `ViewDesc::mips==0` = todos los niveles.
- `gpu/shader/{ir,msl,gcn}`: un solo traductor; gcn = el de PS4; ir/msl con f64, wave64, ImageStore "rvvI", minlod; goldens de Vulkan/SPIR-V/GLES sin cambios.
- `gpu/ps4` (vpps4): frontend PS4. `keepSamples=true` en todo StoreAndResolve (main apaga muestras por defecto con `msaaColorResolveOnTile`). `formats.cpp` `setFormatCaps` desde `caps().bc`.
- App: `vpkengine_renderer.mm` crea `vpgpu::metal2::MetalBackend` (framesInFlight 3, renderCache on) y Device con hold PS4 por setters.

## Causas ya resueltas (no repetir)
- Ojos negros (1): anillo GSVS con layout inventado → solo componente x llegaba al copy VS. Hardware: planos de 64 B, grupos de 16 lanes (`gcn/src/lift.cpp` liftRing/gsEmit; test `gcn.geom.astro` con palabras reales).
- Ojos negros con MSAA (2): `Impl::resolve()` no volcaba el fast clear pendiente del destino; se emitía después y borraba el resolve (tests `renderer_resolve_dest_clear_*`).
- CPU por draw: SpanCache vaciada cada 8 ms y luego por cualquier mutación de memoria → `HostMapGeneration()`.
- Hold de 1500 ms por frame tras el arranque → régimen estable 12 ms solo draws.
- KITCHEN: `HmdSetupDialog` devolvía FINISHED sin Open (nulo en eboot+0x1acd37e); watcher de `owned` liberado N veces (`page_manager.cpp:91`).
- Entrada con retraso: cola de pad de 64 estados (ahora `DrainNewest`).

## Sondas y cómo medir (logs del visor)
- `EYE_STATS` (luma y % no negro por ojo, cada 2 s) y `EYE_CHAIN` (fuente del pase de ojo → resolve → ojo): siempre.
- `EYE_PS`, `EYE_GS`: solo «Modo diagnóstico».
- `vpps4.texprobe` (texturas muestreadas en pases ≥1024²: T#, superficie, fill) y `vpps4.texfail` (fuera de memoria / layout no cubierto): 300 primeros submits.
- `VPKENGINE_GPU cpu:`, `cpu bind phases`, `cpu submit phases`, `cpu region caches` (incluye map mutations por tipo), `vpps4.frame` (draws hechos/total, skips), census `PS4_CENSUS`, `gpu.hold`, `gpu.err`, `[App] Headset:`.
- Crash: bloque `ASTRO_CRASH` en el log del emulador y en stderr (consola): last HLE syscall, guest rip at fault, pc host simbolizado, últimas 32 HLE del hilo. `BACHATA_FEX_THREAD` por hilo creado.
- Logs: quitar ANSI con `sed 's/\x1b\[[0-9;]*m//g'`; consola-* = stderr y app; emulador-* = log del emulador.

## Comprobación local
- Motor: `cmake -S gpu -B <dir> -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build <dir> && ctest --test-dir <dir>` (447 tests en Linux; los .mm de Metal solo compilan en CI de Apple).
- Tests de vpps4 usan NullBackend/CaptureBackend (orden de comandos, load/store, vistas).

## Sospechas abiertas (unverified)
- Fast clears CMASK/HTILE sin aplicar (`EliminateFastClear`/`FmaskDecompress` no-op) → acumulación entre frames.
- `memValid` de main + política de `lifetime.cpp` → Load convertido en DontCare.
- Indirectos → HeavyGeometry en main (memoria real en vez de memoryless).
- CB sin alinear copiado al grabar: no ve escrituras GPU del mismo frame.
- `max/min` frente a `fmax/fmin` con fast math; `int(x)` sin saturar en el camino SPIR-V.
