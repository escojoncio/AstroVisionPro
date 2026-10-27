# Bitácora — AstroVisionPro

ASTRO BOT Rescue Mission (CUSA12392) y KITCHEN (CUSA06799), PSVR, en Apple Vision Pro (visionOS 27). Base shadPS4 ARM64 (HLE, cargador, kernel, PM4/Liverpool) + FEX (CPU, JIT) + VPKEngine (toda la GPU; único renderer en visionOS). App en `visionos/`, release `visionos-latest/AstroQuest.ipa`.
Detalle anterior en `git log -p bitacora.md`. Detalle técnico estable de la ruta GPU PS4: `notas/vpkengine-ps4.md`.

## Last done
- 2026-10-27 build 51cfaae (CI OK): primera build con la ruta PS4 sobre el VPKEngine unificado (rama `unify/engine` 7c1f1cf, NO fusionada en main de VPKEngine; `visionos/vpkengine-gpu.ref` → 7c1f1cf).
- 2026-10-27 VPKEngine `unify/engine`: vpps4 (`gpu/ps4`) usa `gpu/core`, `gpu/metal2`, `gpu/shader/{ir,msl,gcn}` de main; `gpu/ps4/engine/` borrado. Funciones de PS4 añadidas a core/metal2 aditivas e INERTES por defecto (VPVulkan/Alyx/VQP sin cambio; test `gpu_core.defaults`). 447 tests Linux OK. Detalle en notas.
- 2026-10-27 app: watcher de `owned` una vez por clave (crash KITCHEN `page_manager.cpp:91` «Not enough watchers»); `HostMapGeneration()` (SpanCache ya no se vacía con Protect/NameVirtualRange/SetDirectMemoryType: antes 750 vaciados/s en ASTRO); FEX `CreateThread`/`DestroyThread` bajo `GetCodeInvalidationMutex`, `L2Pointer==~0` → ENOMEM, línea `BACHATA_FEX_THREAD`; `fex-darwin.patch` VirtualMemSize 1<<35; hook `view` copia `baseMip`/`mips`.
- 2026-10-27 vpps4: `Impl::resolve()` vuelca/descarta el clear pendiente del destino ANTES del resolve (antes lo borraba después → ojos negros con MSAA); anillo GSVS con layout de hardware (antes posición (x,0,0,0)); caché de 8 regiones; base_level de T# con vista [base..last]; sondas `vpps4.texprobe`/`vpps4.texfail`.
- 2026-10-27 app: pad sin backlog (`DrainNewest`; Cross llega en 3–172 ms); `HmdSetupDialog` con máquina de estados real; ASTRO_CRASH completo al log del emulador (rip guest real vía FEX `RestoreRIPFromHostPC`, dladdr, últimas 32 HLE); `ReportAbnormalTermination` registra estado (sigue devolviendo OK).

## Current state (log Registros_9, build 51cfaae, 2026-10-27 15:00 — SIN ANALIZAR aún)
- Logs en el adjunto `Registros_9.zip` del usuario (7 ficheros consola-*/emulador-* 14:59–15:03). Análisis pendiente: hacerlo primero.
- MSAA 4x: sin imagen y crash (ASTRO y KITCHEN). Causa unverified.
- MSAA 1x: ASTRO dibuja la intro 3D (logo PlayStation VR) con geometría e iluminación, pero corrupción masiva: copias de la geometría acumuladas y superpuestas, «TM» repetido, bandas/dientes, ojos mezclados. Captura del usuario lo confirma.
- Hipótesis principal (unverified): los clears no llegan → cada frame se pinta encima del anterior. Candidatos, por orden:
  1. Fast clears CMASK/HTILE: `EliminateFastClear` y `FmaskDecompress` son no-op en `vpkengine_renderer.mm`; si el título borra con fast clear + eliminate, el color nunca se borra.
  2. Semántica cambiada por la unificación: `memValid` de core de main convierte Load de contenido «indefinido» en DontCare; `placeTiles`/TileLocal/memoryless/HeavyGeometry de main frente a la política de `gpu/ps4/src/lifetime.cpp`; comparar decisiones load/store/clear con vp4 (VPKEngine `ps4/integration` c7737aa, `gpu/ps4/engine/{core,metal}`).
  3. Descarte de clear pendiente en `Impl::resolve()` (nuevo hoy) cuando el destino se reutiliza.
  4. Ojos mezclados: comprobar si ambos ojos acaban en el mismo target o `ComposeEyes` lee mal (`PRESENT eye`, `EYE_CHAIN`).
- Reproducir offline con NullBackend/CaptureBackend: frame con clear + draws dos veces seguidas, mirar acciones load/store.
- Logo de Sony repetido 3–4 veces (build fd86995, MSAA 1x): causa no confirmada; la build 51cfaae trae `vpps4.texprobe`/`texfail` para cerrarla. Tiling revisado contra shadPS4 sin fallos.
- Rendimiento (fd86995, MSAA 1x): ASTRO ~12 fps, KITCHEN ~8 fps a 100 Hz. `backend submit` 111–241 ms/s; GPU no medida aún con el motor unificado.
- Crash ASTRO MicrophoneThread: FEX LookupCache con `L1Pointer=0xfffffff` = mmap fallido (~272 MB VA por hilo FEX); mitigado (ENOMEM, VA 208 MB/hilo); confirmar con `BACHATA_FEX_THREAD` (process_va_mb, live, errno). Entitlements extended-virtual-addressing/increased-memory-limit presentes en `AstroQuest.entitlements` (unverified si la firma SideStore los conserva).
- KITCHEN: tras arreglar el diálogo y el watcher, comprobar si sigue cayendo.

## Pendiente (orden)
1. Analizar Registros_9: crash 4x, corrupción 1x (clears), ojos mezclados, texprobe del logo, `cpu submit phases`, `cpu region caches` (map mutations), `BACHATA_FEX_THREAD`.
2. Arreglos generales → revisión adversarial → una build.
3. Rendimiento GPU: memoryless/MSAA del core de main, caché de MTLLibrary en disco (no existe: `newLibraryWithSource` en cada arranque), coste de `backend submit`, CB sin alinear copiados al grabar (`gpu/ps4/src/renderer.cpp` `alignedConstantCopy`, 320/frame).
4. Fusionar `unify/engine` en main de VPKEngine solo cuando la ruta PS4 funcione (otras sesiones trabajan en main para Alyx/VQP).
5. Futuro (decidido: seguir con shadPS4 mientras el rendimiento sea suficiente): PM4/Gnm/VideoOut en VPKEngine; CPU AOT de VPKEngine (variante sin JIT, aparcada desde 2026-10-09) solo si la CPU limita.

## Decisions
- VPKEngine es el único renderer en visionOS; KosmicKrisp/MoltenVK descartados (KK no era jugable: ~10 fps).
- Arreglos generales de GPU PS4, nunca por juego, dirección ni hash.
- Lo de PS4 en el motor compartido entra opt-in (setters/env); defaults = comportamiento de main.
- `constTables=false` para PS4 hasta tener imagen estable; `MetalOptions::renderCache=true` solo para PS4.
- shadPS4 se mantiene para HLE/kernel/PM4 mientras rinda.
- Diagnóstico solo con «Modo diagnóstico» salvo EYE_STATS/EYE_CHAIN; builds solo visionOS.

## Files in play
- App: `shadps4-arm64-main/src/platform/visionos/vpkengine_renderer.mm`, `core/fex/fex_guest_engine.cpp`, `core/memory.{h,cpp}`, `core/signals.cpp`, `shadps4-arm64-main/CMakeLists.txt` (bloque `VPKENGINE_GPU_DIR`), `visionos/vpkengine-gpu.ref`, `visionos/patches/fex-darwin.patch`, `.github/workflows/visionos-app.yml`.
- VPKEngine (`unify/engine`): `gpu/ps4/src/{renderer,lifetime,msaa}.cpp`, `gpu/core/src/{device,frame_compiler}.cpp`, `gpu/metal2/src/metal_backend.mm`.

## Module index
- `notas/mapa.md`: cadena CPU/GPU/presentación, dónde está cada función, logs, app, CI.
- `notas/vpkengine-ps4.md`: ruta GPU PS4 sobre el motor unificado, causas ya resueltas, sondas, cómo medir, ramas y repos.
