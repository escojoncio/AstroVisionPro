# Bitácora — AstroVisionPro

Port de ASTRO BOT Rescue Mission (PSVR, CUSA12392 v1.00) a Apple Vision Pro (visionOS 27).
Base: shadPS4 ARM64 (`shadps4-arm64-main/`) + FEXCore (x86-64 → ARM64) + MoltenVK.
App visionOS en `visionos/` (SwiftUI + Compositor Services + ARKit + GameController).
JIT: arena RWX preparada por StikDebug (protocolo `brk #0xf00d` + universal.js); la app hace detach al terminar.

## Tests de c30e015 (logs 2026-10-09 10:26 = A: solapadas off; 10:32 = B: solapadas on)
- Memoria (mundo, 1440): footprint 6.5 GB con 1.6–1.7 GB libres (antes 7.3–7.6 / 0.6–0.9); GPU 2.07 GB (antes 2.9–3.0); búferes 362 MB (antes 809). Ajustes de staging/VMA confirmados (~−0.9 GB).
- Mundo 30.0 fps a 90 Hz, GPU 80–95 % = ~29 ms/frame; 53 pasadas/frame, 49 cargan sus destinos (81 Mpx cargados/frame). A: térmico nominal 4.5 min. B (empezó en fair): 90→45 Hz a los ~2 min de mundo (aún fair, luego serious), 22.5 fps con GPU 56–70 % → el límite pasa a ser la pantalla. Pasadas solapadas: sin diferencia medible → se dejan off.
- Lista de pasadas por ojo: sombras 2048² en 4 pasadas por cascada (draw-clear con `colour x1` nulo → `x0`+depth → draw sin destinos → depth; cortes en vk_scheduler.cpp:807 por cambio de estado); escena: prepass depth (187 draws) → b100+D (151) → **D sola, 1 draw** (:807) → copia (image.cpp:938) + blit → b100+D (20) → **D sola, 1 draw** (:807) → subida de búfer (buffer_cache.cpp:987) → b100+D (11) → copia → posproceso (cadena de bloom 720→45 px, todas `loaded`).
- Audio: PHASE sonó ~1 s y se calló: todas las colas a 9600 (llenas) el resto de la sesión. Causa: el juego abre el micro (SDL, sdl_audio_in.cpp) a los ~5 s; SDL3 `UpdateAudioSession` (SDL_coreaudio.m:405) con solo grabación abierta pone `setActive:NO` + categoría Record (silencia la salida) → PHASE deja de pedir audio.
- Vibración: ninguna línea en el log (scePadSetVibration a DEBUG, Swift sin logs).

## Build 14547eb (run 37910291713): OK (sin probar) — juntar pasadas, audio con micro, diagnóstico de vibración
- e20dfc7 falló: `fs_info` no es de `Shader::Info` (está en RuntimeInfo); dual-source se mira en `key.blend_controls[0]` con `LiverpoolToVK::IsDualSourceBlendFactor`.
- Juntar pasadas (genérico): `Rasterizer::PipelineForOpenPass`/`NoteOpenPass` (vk_rasterizer.cpp/.h), `PipelineCache::MakeForOpenPass` + `OpenPassTargets` (override al final de `RefreshGraphicsKey`: formatos/muestras/depth-stencil de la pasada, máscara 0 y sin blend en destinos que no son del draw; shaders iguales), `Scheduler::KeepsPassFor`/`PassSerial`/`IsRendering` (vk_scheduler). Condiciones: pasada abierta por un draw (serie igual), con algún destino; destinos del draw ⊂ los de la pasada (misma vista y layout, sin clear) y mismo tamaño, o sin destinos y dentro de la pasada; mismas capas y muestras; sin barreras de búfer; sin feedback loop; el draw no muestrea/escribe ninguna imagen de la pasada (`binding.is_bound` sobre `open_pass.images`); sin dual-source con >1 destino; salidas del PS a destinos ajenos solo si son de clase float; z/stencil de la pasada solo si los tiene. Depth bounds forzado off sin depth propio (`in_open_pass`). Variante no lista (async) → camino normal. Contador `draws kept in the open pass` en la línea `frame shortcuts`. App: «Juntar pasadas» (`merge_passes` → `SHADPS4_MERGE_PASSES`, 1). Esperado: sombras 4→1 pasadas por cascada, escena −2 por ojo (~−10 pasadas, ~−30 Mpx/frame).
- Audio: sesión `PlayAndRecord` con las opciones exactas de SDL (MixWithOthers|DefaultToSpeaker|0x4|A2DP|AirPlay, modo Default) + `SDL_HINT_AUDIO_CATEGORY=playandrecord` (en `Start` y en sdl_audio_in.cpp antes de abrir el micro) → SDL no la toca. Vigilante `SpatialAudio::Watch()` (desde `Pace`): si los render blocks (`g_pulls`) no avanzan 500 ms → hilo `Recover`: sesión de nuevo, `setActive:YES`, engine pause/start, eventos pausados `resume`, parados `stopAndInvalidate` + `StartEvent` nuevo (Voice guarda event_id/node_id/parameters); máx. 1 intento/2 s; log `SPATIAL_AUDIO: PHASE took no sound for …`. Log de cambios de ruta e interrupciones.
- Vibración: pad.cpp `VIBRATION: the title asks for …` (5 primeras + 1/500); Swift `Controller rumble:` (motores creados y localidades, primeras 5 peticiones, errores de CoreHaptics); si no hay motor por asa → uno para ambas (`.handles`/`.default`, intensidad = máx de los dos).
- Pendiente: si la escena sigue >22 ms, atacar el corte por subida de búfer (buffer_cache.cpp:987) y las cargas `loaded` de los posprocesos de pantalla completa; caída de la pantalla a 45 Hz con calor.

## Build e7d85d8 (run 37855488586): OK, KK recompilado con el parche nuevo (kk_shader.c, kk_cmd_draw.c sin errores); `visionos-latest/AstroQuest.ipa` (sin probar)
## Build c30e015 (run 37901660073): OK (sin probar) — diagnóstico de pasadas desde la app
- Pasada principal: ~25 µs por draw y ~13–18 pasadas de la escena por frame (`816x870/1440x1536 1 colour +depth` 300–550 pasadas/s). Hipótesis: shadPS4 corta la pasada (`Scheduler::EndRendering`) para subidas/copias entre draws (`SynchronizeBuffer` → `EndRendering` + `copyBuffer`, texturas, blits), y en KK cada corte = store/load + barrera ALL→ALL.
- App: `pass_diagnostics` (por defecto 1, «Diagnóstico de pasadas en el registro» en Gráficos) → `SHADPS4_FRAME_STATS=2` (ya existente en vk_scheduler.cpp: medias cada pocos segundos y una lista de las pasadas de un frame con el fichero:línea que terminó cada una).

## Build 8358c87 (run 37900930362): OK (sin probar) — audio 3D como PlayStation VR con PHASE
- Modelo PSVR: el juego da a la consola cada objeto 3D (sceAudio3d, hasta 512, posición relativa a la cabeza: +X derecha, +Y arriba, +Z detrás) y puertos de salida (Main 7.1 ×2, Bgm, PadSpk, el estéreo del puerto 3D…); la consola los renderiza binaurales para los auriculares del visor, fijos a la cabeza (el juego ya compensa el giro).
- `src/core/libraries/audio/spatial_audio.h` + `spatial_audio_visionos.mm` (ObjC++ ARC, solo PHASE; los puertos en `phase_audio_out.cpp` porque las cabeceras del emulador no compilan con ARC: `dispatch_release` en semaphore.h; CMake bloque `SHADPS4_VISIONOS`; `project.yml` enlaza PHASE y AVFAudio): `AVAudioSession` playback + `setIntendedSpatialExperience:Bypassed` + IO 5 ms; `PHASEEngine` automático, reverb none; `PHASEListener` identidad, `automaticHeadTrackingFlags = 0` (visionOS 26). Voz = `PHASESoundEvent` permanente con `PHASEPullStreamNode` (`renderBlock` lee un ring SPSC sin locks; silencio si vacío). Tipos: objeto (48 creadas al arrancar, mezclador espacial `DirectPathTransmission`, distancia sin atenuación, `PHASESource` propia), fija (espacial en posición dada), estéreo (`PHASEChannelMixerDefinition` estéreo). Tabla fija de 160 voces (`g_voices`, lectura sin lock); `Take` reutiliza voces libres del mismo tipo; `Close` solo descarta y libera.
- `PhaseAudioOut`/`PhasePortBackend` (mismo .mm; elegido en `sceAudioOutInit` si `SpatialAudio::Start()`; si no, SDL como antes): puertos 8 canales → 7 voces fijas a 2 m (−30, 30, 0, −110, 110, −150, 150°, misma lectura del layout que `surround_virtualizer.cpp`), LFE ×0.5 al par frontal; resto → voz estéreo. `IsDevicePaced`; `Pace` igual que el SDL de visionOS (silencio hasta 2 bloques del dispositivo por voz, espera ≤50 ms si cola > 2 bloques + 1 buffer, `AUDIO_PACE` cada 10 s). Volumen = canal más alto × deslizador.
- `audio3d.cpp` `sceAudio3dPortAdvance`: `SpatialAudio::ObjectsTick()`; objeto puntual (spread < 1.5) → `WriteObject(port<<32|obj, pcm, …, gain)` (rampa de ganancia por bloque; voz con silencio inicial de 2 bloques de dispositivo + 3 granularidades para ir en fase con el camino estéreo); sin voz libre o ancho → el espacializador propio como antes. Objetos sin sonido 48 bloques sueltan su voz.
- App: «Audio 3D como PlayStation VR» (Ajustes › Juego; `spatial_audio` → `SHADPS4_SPATIAL_AUDIO`, por defecto 1).
- Log: `SPATIAL_AUDIO: PHASE on, head-locked; N voices…; device Hz, frames; route`, `SPATIAL_AUDIO: port N (… channels) …`.
- Sin verificar en dispositivo: que PHASE aplique HRTF con la sesión en Bypassed; picos (los objetos ya no pasan por el limitador de la mezcla 3D); CPU con muchas voces.

## VPEngine (escojoncio/VPEngine) como CPU del juego en vez de FEX — seguimiento
- 03:20 UTC: VPEngine tiene `integrations/shadps4/` (`aot_guest_engine.cpp` con la interfaz de `src/core/fex/fex_guest_engine.h`, `vpengine.cmake`, `astrovisionpro.patch` → opción `ENABLE_VPENGINE_GUEST_CPU`, OFF por defecto). El patch aplica limpio (`git apply --check`) sobre main.
- No ha ejecutado todavía ningún juego real. Faltan: traducir `eboot.bin` + `sce_module/*.prx` de ASTRO BOT con `tools/scripts/translate_game.ps1` (necesita los archivos del juego) y decidir dónde guardar el C traducido (no puede ir a este repo público: build local en un Mac, repo privado con token o artefacto privado).
- Al integrarlo, la app no necesitaría JIT ni StikDebug (`JITGate.swift`, `AppModel.canStart` exige `jit.isReady`): habría que saltarse esa espera en una build VPEngine.

## Estudio (sin código): importar la memoria de la consola como búferes de GPU (`VK_EXT_external_memory_host`)
- Viable técnicamente (VAddr == puntero del host; páginas de caché 16 KB = alineación mínima de KK; BDA sobre memoria importada funciona, kk_buffer.c:184-196), pero **no ahora**. Requisitos previos:
  1. `EventWriteEop`/`EventWriteEos`/`ReleaseMem` (liverpool.cpp:813-841, :1417-1426) señalan al procesar el comando, no al acabar la GPU (hasta 8 envíos en vuelo, vk_scheduler.cpp:27/:982). Con copia, el dato se fotografía al grabar; con import, el juego reutilizaría ring buffers aún no leídos → corrupción. Hay que retrasar las señales a la finalización (riesgo de esperas en `WaitRegMem`).
  2. `Rasterizer::UnmapMemory` (vk_rasterizer.cpp:1661) solo invalida; con imports hay que borrar los búferes del rango y `Finish` antes de desmapear (páginas cableadas por IOKit).
  3. `newBufferWithBytesNoCopy` falla con huecos `PROT_NONE` (ResolveOverlaps ensancha ~2 MB) y KK no comprueba el nil (kk_device_memory.c:132-136).
  4. `JoinOverlap` copia-a-import pisaría datos de CPU no subidos.
- Ahorro estimado 0.55–0.65 GB. Importar `backing_base` entero cablearía ~5.5 GB: solo búfer a búfer.
- `BufferCache::RunGarbageCollector` (buffer_cache.cpp:1171): el lambda `clean_up` no se llama nunca (los búferes no se liberan). Activarlo descargaría (con `Finish`) cada búfer: solo valdría para búferes no modificados por la GPU y con poca memoria libre; pendiente.

## Build 14b3f9b (run 37874392362): OK (sin probar) — ajustes de memoria de móvil/visor también en visionOS; audio al ritmo del dispositivo, «Tiempo real» en la app
- Memoria: en visionOS no está `ENABLE_BACHATA_RUNTIME`, así que iban los valores de escritorio: anillo de staging 512 MB (`buffer_cache.cpp` `DefaultStagingBufferSize`; era el búfer de 512 MB de `IOAccelerator` y de `576 MB in 2 of 64 MB or more`), bloques VMA de 256 MB (los `5×256 MB IOAccelerator`, enteros sucios aunque estén medio vacíos), presupuesto de GPU de escritorio. Ahora `#if defined(ENABLE_BACHATA_RUNTIME) || defined(SHADPS4_VISIONOS)` en: staging 64 MB, `preferredLargeHeapBlockSize` 32 MB (`vk_instance.cpp`), presupuesto = ¼ de la RAM (`CollectPhysicalMemoryInfo`), umbrales GC del caché de búferes (`buffer_cache.cpp`). Esperado: −0.45 GB del staging + el desperdicio de bloques VMA (lo dirá `VMA … MB in … blocks, … allocated` en PACE).
- Causa del petardeo (análisis del log de 01:24 + código): en visionOS el backend SDL no era `IsDevicePaced` → `AudioOutputThread` (audioout.cpp) iba por reloj propio y descartaba el tiempo perdido (`now - next_buffer > period → next_buffer = now`); `SDLPortBackend::HandleTiming` volvía a dormir por reloj, sin colchón ante el bloque de CoreAudio; `ManageAudioQueue` borraba la cola entera al llenarse. Puertos de 256 frames a 48 kHz (5.33 ms), sin remuestreo.
- `sdl_audio_out.cpp` (solo `SHADPS4_VISIONOS`): `IsDevicePaced()` = hay stream; `Output` llama a `PaceByDevice()` en vez de `HandleTiming`/`ManageAudioQueue`: si no está cebado o la cola < 1 bloque del dispositivo, silencio hasta 2 bloques; espera (1 ms, máx. 50) mientras la cola > 2 bloques + 1 buffer; si la cola > objetivo + 8 bloques, `SDL_ClearAudioStream` y aviso; `AUDIO_PACE port N: X times nearly empty in 10 s; device buffer F frames, B bytes queued before this buffer` cada 10 s. `CalculateQueueThreshold` guarda `device_buffer_frames`, pone `primed = false` y pasa a INFO.
- `audioout.cpp`: `pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE)` en `AudioOutputThread` (Apple).
- `audio3d.cpp`: `sceAudio3dObjectReserve` a TRACE (eran ~50 líneas/s con log síncrono).
- App: interruptor «Tiempo real» (`real_time` → `SHADPS4_TITLE_TIMESTEP=0` si off) en Ajustes › Juego, junto al idioma.
- Verificar en el log: `AUDIO_PACE … 0 times`, sin `piled up`; con `SHADPS4_AUDIOOUT_STATS=1` el puerto Main ~100 %.

## Build 6e2f370 (run 37872669398): OK (sin probar) — idioma del juego, pasadas solapadas (experimental), memoria del driver
- Idiomas: `visionos/App/Core/GameLanguages.swift` (28 etiquetas de `pc-vr/launch.ps1`; códigos de archivo posibles por idioma; `codesInFiles` lee los sufijos `_lang_<código>` de `data/multi_platformer/text/gfx` — el log de 01:24 muestra `…_lang_us.jxm`); `AppModel.gameLanguageCodes` (al cambiar `gamePath`); ajuste `game_language` (system | etiqueta) → `SHADPS4_CONSOLE_LANGUAGE` (lo lee `emulator.cpp`, `Common::ConsoleLanguageFromTag`); `GameLanguagePicker` (menú; «En tu copia» primero) en Ajustes y junto a Jugar; log `Game language: <tag>; language files in the game: …`. Copia asiática CUSA12307: ja/ko/zh/th; la del usuario CUSA12392 (EU).
- FXAA: quitado el interruptor y la lectura de `edge_smoothing` (el código de `EdgeSmoother` queda sin uso).
- Parche KK, `KK_LIGHT_BARRIERS=1` (ajuste `light_barriers`, «Pasadas solapadas (experimental)», por defecto 0): `end_encoder` de un encoder de render pone `barrierAfterStages:ALL beforeQueueStages:ALL−(VERTEX|OBJECTS|MESH)`; `kk_note_dependency_outside_render` (desde `kk_CmdPipelineBarrier2` y `kk_CmdWaitEvents2`, siempre) marca `cmd->vertex_wait_pending` si algún `dstStageMask` llega a etapas de vértice (incl. ALL_COMMANDS/ALL_GRAPHICS); `kk_BeginCommandBuffer` lo marca; `cs_start_render` pone `barrierAfterQueueStages:ALL beforeStages:VERTEX|OBJECTS|MESH` si está marcado. Log `KK_LIGHT_BARRIERS: N render encoders, M waited…` (cada 4096).
- Parche KK, memoria: `kk_bo.tally_kind` y `kk_bo_note_kind` (Vulkan memory en `kk_AllocateMemory`, descriptor pools en `kk_CreateDescriptorPool`, resto = del driver; importados no cuentan); stderr `KK_MEMORY: … in all; Vulkan memory …, descriptor pools …, the driver's own …` cada 64 MB de cambio.
- shadPS4: `Vulkan::VmaBlocksForReports()` (vk_instance.cpp, `vmaCalculateStatistics`: bytes de bloques vs asignados) en `PACE`.
- Revisión adversarial aplicada (barreras dentro del render también marcan, etapas de consumidor, tally sin avisos falsos, valor de idioma desconocido en el menú, códigos cacheados).

## Build 0f6bcfc probada (log 2026-10-09 01:24; 1440 fija, FXAA, GS en la pasada): sin cierre
- `KK_GS_IN_PASS`: todos los draws con GS dentro de la pasada (`N in the pass, 0 split it`, >70 k); sin fallos visuales reportados.
- Mundo a 100 Hz: 28.8 fps de mediana (test 2: 26.6; test 1 a 816: 29.4), GPU 99 %; pasada principal 18.7 ms/frame (test 2: 21.3). Regresión: coste por draw con GS 0.12 ms (antes 0.25).
- Térmico confirmado: `thermal nominal` → `fair` a ~2.5 min en el mundo; con `fair` el visor pasa a 50 Hz (juego a 25 fps, GPU 78–88 %); después `serious`.
- Memoria (mundo, 7.25 GB, ~930 MB libres): GPU según el driver 2.9 GB; búferes 809 MB en 250 (576 MB en 2 de ≥64 MB), imágenes 1140 MB en 875; ~0.95 GB sin atribuir (KK interno, desperdicio de bloques VMA, búferes de `tile_manager`). Consola en RAM 1.4 GB.
- FXAA: el usuario lo ve muy borroso y pierde detalle → quitar.
- Siguiente palanca de rendimiento: `end_encoder` (kk_cmd_buffer.c) pone `barrierAfterStages:ALL beforeQueueStages:ALL` en cada encoder y `kk_CmdPipelineBarrier2` ignora las barreras fuera de render → cada pasada vacía la GPU.

## Build 0f6bcfc (run 37856887775): OK, `visionos-latest/AstroQuest.ipa` (sin probar) — incluye e7d85d8 + reparto de la memoria GPU
- `buffer_cache/buffer.cpp`: `AllocationTally` (atómicos: bytes, nº, y los de ≥64 MB) con el tamaño VMA de cada asignación; `UniqueBuffer::Create`/destructor suman/restan; `TallyImageAllocation` (llamado desde `UniqueImage::Create`/`~UniqueImage`/`Destroy` en `texture_cache/image.cpp`); `DescribeGpuAllocations()` → `buffers X MB in N (Y MB in M of 64 MB or more), images …`. Los búferes con BDA (los del caché de búferes) llevan `VMA_ALLOCATION_CREATE_DEDICATED_MEMORY_BIT` → son los bloques dedicados de 256/512 MB de `IOAccelerator`.
- `guest_watchdog.cpp` `ReportPace` (visionOS): añade ese texto a `PACE`.

## Test 3 (log 2026-10-09 00:40; 2160 fija, sin AA, build 47cf082): cierre por memoria
- Mundo 14–18 fps, GPU 99–100 %. Pasada principal `2160x2304 1 colour +depth` ~600 ms/s a ~195 pasadas/s: ~37 ms por frame frente a ~19 a 1440 y ~17 a 816 → por debajo de 1440 domina un coste fijo; por encima, los píxeles sí cuestan (corrige lo dicho en el test 2).
- Memoria 8.0 GB con 170–210 MB libres → jetsam. `MEMORY`: IOAccelerator 3554 MB (bloques de 512 MB y 5×256 MB, enteros sucios; VMA usa bloques de 32 MB → son asignaciones dedicadas), consola 1369 residente + 1528 comprimida, untagged 152+592, malloc 221+210 (en uso 1137 de 1242 MB), IOSurface 205.
- Visor a 50 Hz desde ~1 min (test 2: desde ~2 min; test 1: nunca). Pruebas seguidas 00:21, 00:28, 00:40 → hipótesis térmica (la build e7d85d8 registra `thermal` en `Headset:`).
- Plan de memoria: (1) medir en `PACE` cuánto de la memoria GPU es del caché de búferes (copias de la memoria del juego) y cuánto de imágenes; (2) si los búferes pesan: importar la memoria de la consola como búferes de Vulkan (`VK_EXT_external_memory_host` en KK → `newBufferWithBytesNoCopy`) en vez de copiarla (memoria unificada; quita también las subidas).
- AA por IA (MetalFX temporal) exige vectores de movimiento y profundidad por píxel: el juego solo da el color. Opciones espaciales: FXAA (e7d85d8), SMAA.

## Test 2 (log 2026-10-09 00:28; resolución 1440 fija, sin MetalFX, MSAA 1) y commit siguiente
- Pasada principal `1440x1536 1 colour +depth` 420–610 ms/s con 10–27 k draws/s: igual que a 816x870 (test 1) con 3× píxeles → el coste no es por píxel; resolución dinámica y MetalFX no aportan. Memoria igual (7.3–7.6 GB, 600–900 MB libres).
- Desde 00:30:13 el bucle del visor va a 50 Hz (`Headset: … in 250 refreshes`, también las manos): el juego queda en 25 fps con GPU 78–88 %. Causa desconocida (coincide con vídeo `AvPlayer`/`SocialScreen`); test 1 estuvo a 100 Hz todo el rato.
- El cierre a 2880 (build e05ce18) fue con JIT 1024, MSAA 4x y sin los ahorros posteriores: no vale como límite actual. Pendiente probar 2160 y 2880 fijos sin AA.
- Commit siguiente (`[build]`):
  - Parche KK: `pre_render_vertex[4]` en `kk_pipeline_handles`; `kk_compile_vertex_only_pipeline` (kk_shader.c) reescribe el MSL de los dos kernels pre-render (VS-como-compute y GS) a función de vértice (`kernel void`→`vertex void`, `gl_GlobalInvocationID` = (vertex_id, instance_id, 0)); se descarta si el código tiene threadgroup/simd/quad/atomic/ids locales; pipeline sin fragmento, `rasterizationEnabled = NO`, topología punto, mismos formatos de color y muestras. Solo VS+GS sin tess ni multiview. `kk_launch_gs_prerast`: con encoder de render abierto y draw directo → dos draws de puntos (x vértices, y instancias) con barreras vértice→vértice y se restaura `gfx.render`; si no, camino compute de antes. Logs stderr `KK_GS_IN_PASS: … stays a compute pass (motivo)`, `… did not compile as a vertex function`, `… N geometry shader draws in the pass, M split it` (cada 4096). `KK_GS_IN_PASS=0` lo desactiva.
  - App: `dynamic` y `upscale` fijos (sin resolución dinámica ni MetalFX; quitados de Ajustes y de `settings.txt` por defecto); textos de resolución sin cifras de memoria; ajuste `gs_in_pass` (→ `KK_GS_IN_PASS`) e interruptor en Gráficos; `edge_smoothing` (FXAA: `EdgeSmoother.swift` + `edgeVertex`/`edgeFragment` en Shaders.metal, una vez por frame del juego a textura del mismo tamaño, sin cruzar entre ojos) con interruptor «Suavizar bordes (FXAA)»; log `Headset:` añade `display N Hz, thermal <estado>` y `N with edges smoothed`.
  - Revisión adversarial aplicada: topología punto, `atomic` en la lista de bloqueo (un vértice puede ejecutarse más de una vez), contadores atómicos. Pendiente de verificar en dispositivo: barrera vértice→vértice dentro del encoder y lectura de índices del GS.

## Build 47cf082 probada: test 1 (log 2026-10-09 00:21; dinámica, MetalFX ×1.5, JIT 512, MSAA 1)
- Sin cierre. Nave 33–48 fps (GPU 70–96 %); mundo 19–33 fps (casi siempre 28–33), GPU 94–99 %, escena a 816x870. `PACE` memoria en el mundo 7.36–7.59 GB con 600–850 MB libres; GPU 3.0 GB; consola en RAM 1.5 GB.
- `GS_DRAWS` (mundo): `0x3b916cc5043` (GS `0x3b88b54e`, partículas, 3198 dwords) 300–1140/s; `0x7e8aa19af8e` (GS `0x7e82e7ba`, 7050 dwords, ES `0x3cac3810`) 150–800/s; `0xf25459bf2ca` (GS de paso `0xf250a6ed`) 100–133/s, solo en la pasada `1440x1536 1 colour` (1 draw por pasada); `0x6a3e0045bf3` (GS `0x6a2e54fb`, 355 dwords) ocasional; `0x3b916cc5040/41` variantes.
- **Refutado**: la escena no va por el GS de paso; los draws con GS son 3–8 % de los de la pasada principal (600–1470 de 10–30 k/s).
- **Pero cada draw con GS es caro**: regresión sobre 22 ventanas de `816x870 1 colour +depth` (ms/s ~ pasadas + draws + draws GS, R² 0.88): ~0.23 ms por draw con GS, ~3 µs por draw normal. Solo GS: R² 0.46, 0.18 ms/draw; solo draws: R² 0.07. ~1000 draws GS/s ≈ 200 ms/s ≈ 20 % de la GPU (40 % de la pasada principal).
- Causa (fuente KK `b628375`): `kk_launch_gs_prerast` → `cs_get_compute` hace `kk_apply_attachment_store_ops(cmd, true)` + `cs_end` (barrera ALL→ALL en `end_encoder`), dos dispatch (VS-como-compute y GS) con barreras, y `need_to_start_render_pass` → nuevo encoder de render con load y `kk_cmd_buffer_dirty_all_gfx`. Por cada draw con GS: store+load de color y profundidad de la pasada y vaciado completo de la GPU.
- Cadena de pasadas diminutas (25x27…408x435, 1 draw cada una): 0.25–0.3 ms por pasada (~150 ms/s). Coste fijo por encoder: `end_encoder` pone barrera ALL→ALL siempre (KK ignora las barreras de Vulkan fuera de render y confía en esa; `kk_CmdPipelineBarrier2`). Quitarla exige implementar barreras reales: no por ahora.
- Plan elegido (A): en KK, si hay encoder de render abierto y el draw es directo sin unroll de restart, ejecutar VS-como-compute y GS dentro del mismo encoder como draws de solo vértice (`rasterizationEnabled = NO`, vertex_id/instance_id = rejilla 2D) con barrera vértice→vértice, sin cerrar la pasada. Requiere compilar los `pre_render` también como funciones de vértice (sin memoria de grupo ni barreras de grupo). Alternativas: shaders de malla de Metal (lo que hace Metal Shader Converter; mayor), reescribir los 4 GS de ASTRO BOT (específico del juego, inviable para los de 3198/7050 dwords), agrupar draws GS consecutivos (falta saber si lo son).
- Pendiente: test 2 (resolución fija 1440) para el coste por píxel; dónde atravesó Astro la pared.

## Build e05ce18 probada (log 2026-10-08 15:41) y arreglos siguientes
- Pipelines en segundo plano: funcionan (PIPELINE_SLOW 18–96 ms, cientos de draws omitidos, sin tirones).
- Mando: posición por las manos OK (`PAD: seen`). Giróscopo: el último `Controller motion` de la app es 15:42:20; después el emulador recibe siempre el mismo valor (`heading -1 pitch 16 roll 12`) → visionOS apagó los sensores del DualSense al girar la cabeza.
- Ajuste activo `resolution=2880` (`SHADPS4_TITLE_EYE_WIDTH=2880`): memoria del juego +1536 MB (gráficos 2186 MB, targets 880 MB), mínimo dinámico 1632x1744, textura al visor 5760x3072; GPU al 99–100 %, 8–19 fps con CPU 15–40 %. Crash al entrar al mundo: el log se corta en una carga (`mup_review_levels.xml`) sin `ASTRO_CRASH` → cierre por memoria (jetsam, SIGKILL no capturable).
- Arreglos (commit siguiente):
  - `PlayStationController.swift`: `lastMotionTime`/`keepMotionOn` (llamado desde `poll()`): si no hay datos de movimiento >0.5 s, en el hilo principal `sensorsActive` off→on y se vuelve a poner `valueChangedHandler` (máx. 1/s). Logs `Controller motion: no reports for X s (sensors active: …); turning them on again (n)` y `Controller motion: reporting again`.
  - `AstroSettings.swift`: `resolution` por defecto 1440 (también en `defaultFile`); el `settings.txt` existente del usuario no se toca.
  - `SettingsView.swift`: resolución con memoria extra indicada (2160 ≈ +0,7 GB, 2880 +1,5 GB) y aviso en el pie; selector nuevo de MSAA (`msaa` = "" / 2 / 1 → `SHADPS4_MAX_MSAA`).
  - `guest_watchdog.cpp` `ReportPace`: añade `; memory <phys_footprint> MB, <os_proc_available_memory> MB left` (lo segundo solo con `SHADPS4_VISIONOS`).

## Build 66c0aaa probada (log 2026-10-08 16:23) y diagnóstico siguiente (sin build aún)
- Giróscopo: arreglado (`Controller motion: reporting again` tras apagarse los sensores). Mando por manos OK.
- MetalFX: funciona (`each eye enlarged from 1440x1536 to 2160x2304`).
- GPU saturada de verdad: `GPU_TIME` 85–99 %; CPU 30–77 %. La resolución dinámica baja a 816x870 (a veces 960x1080) por ojo a 30 fps → imagen pixelada. MSAA de la consola (4x) sin limitar (sin `SHADPS4_MAX_MSAA`).
- Cierre por memoria confirmado: `PACE` memoria 4.4 GB al arrancar → 6.4 GB en la nave → 7.0 GB al cargar el mundo con 1.2 GB libres; límite del proceso = usado + libre ≈ 8191 MB. `TEXTURE_GC` solo soltó ~35 MB (todo en uso). Memoria directa del juego a 1440: 0x13c000000 (5056 MB); bloques 0x38000000, 0x10000000, 0x36800000, 0x96800000 (2408 MB gráficos) + cargas pequeñas de RoomLoad.
- Comparativa Quest 3 (README-QUEST-VR.md "The size of the picture"): también 816x870–1200x1280 a 30 fps con GPU 97–99 % en escenas pesadas; con 8 GB de RAM totales no se cierra.
- Código añadido (commit sin build, comprobado con `clang++ -fsyntax-only` en Linux con stubs de mach/os):
  - `vk_scheduler.{h,cpp}` `GpuTimer`: bloques de 256 consultas por command buffer (48 bloques); timestamps `BottomOfPipe` antes de `beginRendering` y tras `endRendering` (`PassBegin`/`PassEnd`, `NoteDraw` → `PassDraw`, ahora no inline). Cada 5 s `GPU_PASSES[n]: X ms/s outside passes…; the heaviest: WxH[xL] N colours [+depth]: ms/s, passes/s, draws/s` (10 más caras, clave = tamaño, capas, nº de colores, profundidad). `GPU_TIME` añade `untimed` y `the GPU's memory N MB` (`Instance::GetDeviceMemoryUsage`).
  - `address_space.{h,cpp}`: `Core::ResidentConsoleMemory()` (visionOS: `mincore` sobre el mapeo completo del objeto de memoria de la consola; `g_console_memory`/`g_console_memory_size`).
  - `guest_watchdog.cpp` `ReportPace`: añade `the console's memory in RAM N MB`.
- Build 6e65d9c (dispatch) compilada con lo anterior; el usuario ya había movido el juego a VPS4 → sin probar.
- Carpeta VPS4 (commit siguiente, `[build]`):
  - `visionos/App/Core/GameFolder.swift` (nuevo): bookmark del `.fileImporter` en UserDefaults (`vps4FolderBookmark`) y llavero (genérico, servicio `astroquest.vps4`, cuenta `folder-bookmark`, `AfterFirstUnlock`); `url()` resuelve (defaults y luego llavero), `startAccessingSecurityScopedResource` y lo mantiene; crea `Juegos`, `Partidas`, `Cachés`; `choose()` exige nombre `VPS4` (sin distinguir mayúsculas) y copia `Library/Application Support/shadPS4/home/*` a `Partidas` si está vacía. Logs `VPS4: …`.
  - `AppModel.swift`: `gameFolder`, `folderChosen(_:)`; `findGame` busca primero en `VPS4/Juegos/*` y `VPS4/*` (juego = `eboot.bin` o `sce_sys/param.sfo`; prefiere CUSA12392 sin distinguir mayúsculas) y luego en Documents como antes.
  - `AstroSettings.swift`: `MESA_SHADER_CACHE_DIR` en `VPS4/Cachés/mesa_shader_cache` si hay VPS4; `SHADPS4_HOME_DIR=VPS4/Partidas`.
  - `astro_core.mm`: con `SHADPS4_HOME_DIR`, `create_directories` + `Common::FS::SetUserPath(PathType::HomeDir, …)` antes de arrancar (stderr `Users and saves in …`).
  - `HomeView.swift`: tarjeta Juego con botón "Elegir VPS4" (`.fileImporter` de carpetas) y detalle `VPS4 › <juego>`. `CheckView.swift`: estado de VPS4, botón elegir, y lista de ficheros `sce_sys` (param.sfo obligatorio; resto opcional) — cierra el antiguo pendiente 6.

## Commit tras ba75821: MetalFX, GPU_TIME, recolector de texturas por memoria del proceso
- `visionos/App/Render/Upscaler.swift` (nuevo): `MTLFXSpatialScaler` por ojo. Blit de cada mitad del frame (ojos lado a lado) a una textura privada propia, escalado a `round(ojo·upscale/2)·2`, formato del frame (rgba8Unorm_srgb), `colorProcessingMode = .perceptual`. Si no hay escalador: log `MetalFX: no spatial scaler…` y se muestra como antes.
- `GameRenderer.swift`: `upscaleNewFrame` al tomar un frame nuevo (una vez por frame del juego); `bindPicture` liga texturas 0/1 (ojo izq./der.; sin MetalFX, el frame en ambas); `frame_x` = (0,1,½texel,1−½texel) con MetalFX. Log `Headset:` añade `N enlarged to WxH an eye`; log `MetalFX: each eye enlarged from … to …`.
- `Shaders.metal`: `reprojectFragment` con `left_eye`/`right_eye` según `in.eye`; quitado el borde azul.
- `AstroSettings.swift`/`SettingsView.swift`: `upscale` (1, 1.5, 2; por defecto 1.5), selector "Escalado MetalFX". `project.yml`: `-framework MetalFX`.
- `vk_scheduler.{h,cpp}`: clase `GpuTimer` (por defecto en visionOS; `SHADPS4_GPU_TIMING=0|1`): pool de 512×2 timestamps, `TopOfPipe` tras `begin` y `BottomOfPipe` antes de `end` de cada command buffer; lectura sin espera cuando el tick está libre. Cada 5 s `GPU_TIME[n]: the GPU worked X% …` (n = scheduler). Si el driver no tiene timestamps: `GPU_TIME: the driver has no timestamps…`.
- `texture_cache.cpp` `RunGarbageCollector` (visionOS): umbrales recalculados en cada llamada con `os_proc_available_memory()`: trigger <2 GB libres, pressure <1.25 GB, critical <700 MB. Log `TEXTURE_GC: N images … let go (X MB), Y MB left` (máx. 1 cada 5 s). Motivo: el presupuesto de escritorio (`CollectPhysicalMemoryInfo`, rama integrada) salía del tamaño del heap y el GC no saltaba antes del jetsam.
- Análisis: ASTRO BOT reserva su memoria en bloques al arrancar (0x38000000, 0x10000000, 0x88a00000 de gráficos) y solo libera 1 vez por sesión → liberar memoria del invitado no sirve; `BufferCache::RunGarbageCollector` de upstream no borra nada (el lambda no se usa), se deja así.
- Slots al visor siguen en 6 (`openxr_host_visionos.mm`: con menos, el hilo de la GPU se bloqueaba; a 1440 son ~100 MB).

## Build 47cf082 (run 37846052207): OK; `visionos-latest/AstroQuest.ipa` (sin probar) — medición de GS
- `vk_scheduler.{h,cpp}`: `NoteDraw(u64 gs_hash = 0)`; `GpuTimer::PassDraw(gs_hash)` cuenta `Pass::gs_draws` y `gs_draws_by_hash` (este también fuera de pasadas cronometradas: puede sumar más que `GPU_PASSES`). `GPU_PASSES`: `N draws/s (M with a GS)` por tipo de pasada; nueva línea `GS_DRAWS[n]: <hash del pipeline> X/s, …` (8 mayores).
- `vk_rasterizer.cpp`: `NoteDraw(pipeline->GetGraphicsKey().stage_hashes[Geometry])` en los dos caminos de draw.
- `vk_pipeline_cache.cpp` (visionOS, camino GS real con KK): `GS_HASH <hash pipeline>: es <hash> gs <hash>` una vez por hash (máx. 64) + `LogGsBypassShaders` (GS_INFO/GS_CODE, primeros 6 pares).
- `guest_watchdog.cpp`: `MEMORY` cada 120 s o tras +512 MB (mín. 30 s).

## Build 2ad2afd probada (log 2026-10-08 23:02): sin cierre, sin mejora visible
- Pasada `16384x16384 0 colours` desaparecida; GPU sigue 90–100 % (casi siempre 94–100), mundo a 816x870, casi siempre 28–33 fps con bajadas a 17.8–22.9.
- `GPU_PASSES` mundo: `816x870 1 colour +depth` 320–597 ms/s con 9.4–32 k draws/s (14–48 µs/draw; en la segunda mitad 11–13 k draws/s a 40–48 µs): **el tiempo de la pasada se mantiene en 400–600 ms/s aunque los draws varíen ×3** → no es un coste fijo por draw demostrado. `816x870 1 colour` 51–134; `1440x1536 1 colour` 33–85; `2048x2048 0 colours +depth` (sombras) 29–58 con 10–16 k draws/s (3–7 µs/draw); `816x870 0 colours +depth` 17–36 con 9–28 k draws/s; cadena de bloom (25x27…408x435, y 204x217) 18–59 cada una.
- Hipótesis (sin confirmar; los datos de arriba la debilitan): en KK (fuente leída de `shadexternals/mesa` `b628375`, `src/kosmickrisp/vulkan/kk_cmd_draw.c` camino GS y `cs_get_compute` en `kk_cmd_buffer.c`) cada draw con GS cierra el encoder de render (store de color+profundidad), ejecuta VS y GS como compute y reabre la pasada (load). Si el coste viene de ahí debería seguir al nº de draws con GS, no al total. Otras candidatas: coste por píxel de la escena (sombreado/overdraw) o por pasada. Decide `GS_DRAWS` + `(N with a GS)` de 47cf082 y la prueba con resolución fija. Si `GS_DRAWS` confirma que la escena va casi toda por GS `0xf250a6ed` (paso directo con condición uniforme `s[2:5]` dword 99 == `s[0:3]` dword 24), el arreglo es no usar GS en ese shader: ES como VS + la condición evaluada sin GS (descartar el draw o degenerar la posición), con el código de `GS_CODE` para reproducirla exactamente. Alternativa de fondo: GS → mesh/object shaders de Metal dentro de KK (lo que hace Metal Shader Converter).
- `MEMORY` (mundo, 7.5 GB): internal 2.6 + compressed 2.2 + graphics 3.5. Por tipo: `IOAccelerator` ~3.2 GB (bloques de 512 y 256 MB), memoria de consola ~2.7 GB (1.4 residente + 1.3 comprimida), untagged ~0.7, malloc ~0.4 (en uso 1.1 GB). Arena JIT: `code arena used 113 MB, most 113 MB, of 512 MB` (y no aparece `code arena` entre los tipos de `MEMORY`); 512 sobra. Recorrido de ~70 000 regiones en 220–255 ms.
- Astro atravesó una pared (no la cámara). Hipótesis principal, de la emulación: con `real_time=1` (por defecto; `KnownTitle::OnFrameSubmitted` escribe `frame_rate`/`frame_seconds`/`frame_microseconds` con lo que tardan los frames) el paso en el mundo es ~30 ms (29.6–34.9) con picos de 39–42 y 50 ms (el tope, `longest_step` = 1/20 s), frente a 16.7 ms en consola. `PhysicsStepChanges` solo corrige los cuerpos enviados a un sitio (issue #16), no la colisión del personaje. Sin verificar si Astro es un cuerpo de la librería de física o lo mueve el código del juego con `frame_seconds` (de eso depende que sirvan subpasos). Opciones: subpasos de física (≤ 1/60 s) parcheando el binario para llamar varias veces al paso (bastante más complejo que `PhysicsStepChanges`); bajar `longest_step` solo quita los picos de 40–50 ms (por debajo de ~30 ms ralentiza el juego siempre; `SHADPS4_TITLE_TIMESTEP=60` ≈ `real_time=0`). Prueba que decide: `real_time=0` (pasos fijos de 1/60, cámara lenta) en el mismo sitio; si sigue atravesando, no es el paso. `real_time` no está en los ajustes de la app (solo `settings.txt`): añadir el interruptor «Tiempo real» en la app. Astro estaba saltando (movimiento vertical rápido: encaja con pasos largos). Pendiente: en qué nivel.
- Pendiente de memoria: evitar duplicar en GPU lo que ya está en la memoria de la consola (memoria unificada; KK tiene `VK_EXT_external_memory_host`).
- Prueba sugerida sin build: `Resolución dinámica` desactivada (1440 fija) para separar coste por píxel de coste por draw.

## Build 2ad2afd (run 37834549716): OK, sin avisos en los ficheros cambiados; KK en la app; `visionos-latest/AstroQuest.ipa` (sin probar)
- `vk_rasterizer.{h,cpp}`: `BeginRendering` marca `has_target` (algún color con imagen o profundidad); si no hay, `width/height = min(actual, AttachmentlessExtent())`. `AttachmentlessExtent()`: mismo scissor combinado que `UpdateViewportScissorState` (pantalla/ventana/genérico + offset de ventana, scissor por viewport si `vport_scissor_enable`); borde = max(br, tl) por si el scissor está invertido (KK lo convierte en [br, tl]); con triángulos rellenos (`PolyMode()==Fill`), clip activo y `stage_enable.raw == Vs`, además ≤ `ceil(offset + |scale|)` del viewport; unión de viewports activos (xscale≠0), `AlignUp(…,32)`, entre 1 y el máximo. `SHADPS4_TIGHT_EMPTY_PASSES=0` vuelve a 16384.
- `vk_scheduler.cpp`: `IsAttachmentless(state)`; en `BeginRendering(requested)` si la pasada abierta y la pedida son sin adjuntos con mismo nº de colores y capas: si cabe, se sigue en la abierta; si no, nueva pasada con la unión de tamaños.
- KK (`kk_cmd_draw.c`): sin framebuffer, `renderTargetWidth/Height` = extent del `renderArea` → antes 16384² (262 144 tiles de 32²).
- `guest_watchdog.cpp` (Apple): `DescribeMemory` → `MEMORY:` cada 30 s o tras +256 MB (mín. 10 s): `footprint = internal, compressed, graphics (+compressed), purgeable kept` (ledgers de `TASK_VM_INFO`, con `offsetof` contra `vm_count`); recorrido de regiones (`vm_region_recurse_64`: primero info corta, luego completa solo de lo que se cuenta; submaps fuera) con sucio+comprimido por tipo: `console memory` (objeto de `ConsoleMemoryRange()`, alias del invitado fuera), `code arena` (mapeo rx; rw fuera), etiquetas (`malloc`, `IOAccelerator`, `IOSurface`, `untagged`, `tag N`…); objetos compartidos deduplicados por (`object_id_full`, offset, tamaño); `malloc in use X of Y`; `code arena used/most/of`; 6 regiones más grandes (dirección, MB, etiqueta, `share_mode`); `walked in N ms`.
- `address_space.{h,cpp}`: `Core::ConsoleMemoryRange()`. `jit_arena.{h,cpp}`: `Usage GetUsage()` (`begin`, `used`, `most`, `size`; no inicializa la arena).
- Revisión adversarial aplicada: info corta antes de la completa (la completa recorre página a página con el mapa bloqueado), ids de consola/arena en `static`, `object_id_full`, scissor invertido, modo de polígono.
- Comprobado con `clang++ -fsyntax-only` (rasterizer/scheduler completos; la parte Mach contra stubs con las estructuras reales de XNU).
- Qué mirar en el log: `GPU_PASSES` (la fila `16384x16384 0 colours` debe desaparecer y la GPU bajar 6–23 % en el mundo), fallos de efectos que antes salían (partículas/oclusión) → probar `SHADPS4_TIGHT_EMPTY_PASSES=0`; `MEMORY:` → qué crece de 1.2 a 3.4 GB y `code arena most` para fijar el tamaño del JIT (FEX: búferes de 16→128 MB, `CPUBackend.cpp` `INITIAL_CODE_SIZE`/`MAX_CODE_SIZE`; pico teórico ~256 MB + el anterior mientras se suelta); si `walked in` > 50 ms, espaciarlo.
- Descartado (sin build): devolver páginas de la arena con `madvise(MADV_FREE_REUSABLE)`; una página reutilizada podría no ser ejecutable bajo TXM y el fallo saldría a mitad de partida. Se dimensiona la arena con `code arena most`.

## Build e030f88 probada: tests C1–C4 (logs 2026-10-08 20:18, 20:23, 20:35, 20:41)
Base común: 1440, dinámica, MetalFX ×1.5, MSAA 1. `GPU_TIME`: 4080 timestamps (10×408) funcionan con KK.

| Test | Driver / ajuste | Resultado |
|---|---|---|
| C1 | KK, FOV 100, JIT 1024 | Cierre por memoria al cargar mundo: 8115 MB, 76 MB libres; consola en RAM 1.4 GB, GPU 3.0 GB, resto 3.7 GB. Mundo 816x870 a ~30 fps, GPU 95–99 %. |
| C2 | MoltenVK | Peor: mundo 17–25 fps a 816x870, GPU 100 %; pasada principal 65–74 % (~45 µs/draw frente a ~18 µs en KK). Pasadas pequeñas más baratas que en KK. GPU 2.4 GB. **MoltenVK descartado.** |
| C3 | KK, FOV 85 | Cierre por memoria al cargar nivel 1 (1.3 GB libres antes de cargar). FOV no cambia memoria ni rendimiento. |
| C4 | KK, FOV 100, JIT 512 | Sin cierre (mínimo 339 MB libres). Resto al arrancar 1.2 GB (frente a 1.7 GB con 1024); al final ~3.4 GB. 25–33 fps, 816–960. |

`GPU_PASSES` en el mundo (KK, 816x870):
- Escena `816x870 1 colour +depth`: ~50 % de la GPU, ~400 pasadas/s (~13 por frame), 21–31 k draws/s (~18 µs/draw).
- `16384x16384 0 colours` (pasada sin adjuntos; el emulador usa el área máxima): 6–23 % de la GPU. En GPU por tiles se recorre toda el área.
- Cadena de pasadas pequeñas (25x27…408x435, 1 draw cada una): ~0.25 ms por pasada, ~15 % en total (coste fijo por pasada en KK).
- Sombras 2048², composición 1440x1536, compute fuera de pasadas: ~5 % cada uno.

Memoria: el "resto" (footprint − consola en RAM − GPU) crece 1.2–1.7 GB → 2.6–3.7 GB con KK y con MoltenVK, así que no es del driver. Parte es la consola comprimida (mincore no cuenta `MINCORE_PAGED_OUT`; la consola en RAM baja de 2.0 a 1.4 GB cuando la GPU sube 1.1 GB al cargar mundo). JIT 512 en vez de 1024 ahorra ~0.3–0.5 GB. `jit_arena.cpp` `Free` no devuelve páginas al sistema.

## Siguiente build (plan, por este orden)
1. **Memoria / JIT**: `PACE` con uso real de la arena (`Common::JitArena`: bytes en `used`, máximo histórico) y páginas de consola `MINCORE_PAGED_OUT` (comprimidas); `malloc_zone_statistics` (montón: FEX, Mesa/NIR, shadPS4) en `PACE`. En `JitArena::Free`, devolver páginas: probar `madvise(rw, len, MADV_FREE_REUSABLE)` en el mapeo RW (puede no tener efecto en objeto compartido; verificar con `PACE`). Limitar el búfer de código por hilo de FEX si el uso lo justifica. Después: quitar el ajuste "Memoria ejecutable" y fijar el tamaño en la app.
2. **Pasada 16384x16384 sin adjuntos**: en `vk_rasterizer.cpp`/`Scheduler::BeginRendering`, cuando no hay color ni profundidad, usar como `renderArea`/ancho×alto el scissor o viewport del draw (redondeado) en lugar de 16384. Esperado: −6…−23 % de GPU en el mundo.
3. **Coste por pasada en KK**: revisar barreras entre pasadas (`pipelineBarrier2` de transiciones de imagen) en la cadena de bloom; agrupar o evitar barreras redundantes.
4. **Coste por draw de la escena (~18 µs)**: medir qué cambia entre draws (pipelines, descriptores, buffers subidos dentro de la pasada) con contadores por frame (`SHADPS4_FRAME_STATS=1`) y por pipeline; probar si los draws con GS de KK parten la pasada.
5. Audio: petardeo desde el arranque en todas las pruebas, independiente del driver (pendiente de análisis: `sndx_out_thread` 8–17 % CPU).
6. Antialiasing por defecto en visionOS: 1 (con 4x la GPU no da; con 1, nave a 1440 y 45 fps).

## Build 634efdd probada: A (MSAA 4x) y B (MSAA 1), logs 2026-10-08 18:35 y 18:38
- VPS4 funciona: carpeta resuelta en `.../File Provider Storage/vPS4` (minúscula v aceptada), `SHADPS4_HOME_DIR` aplicado.
- `GPU_TIME: no query pool (ErrorOutOfDeviceMemory)`: KK limita el pool de timestamps (Metal: counter sample buffer ≤32 KB = 4096 timestamps); 12288 falla → sin datos por pasada.
- Memoria: `the console's memory in RAM` 0.9–2.1 GB frente a footprint 4.2–8.0 GB → ~5 GB son del emulador/driver, no del juego. A: cierre al cargar mundo (7.1 GB, 1085 MB libres). B: sobrevivió con 119–170 MB libres (8.0 GB).
- MSAA 1 (B): nave 1440x1536 a 45 fps, GPU 65 %; mundo 816–1200 a 30 fps, GPU 80–96 %. A (MSAA 4x): 816–960 a 30 fps.
- Usuario: audio petardea desde el arranque en ambas; lejano borroso (explicación: 1440 px sobre ~105° ≈ 14 px/grado frente a ~34 de la pantalla → probar `fov` 85–90 %).
- Revisión adversarial (subagente) y arreglos (commit siguiente, `[build]`):
  - `GpuTimer`: tamaños `{10×408, 8×256, 16×64, 4×16}` (≤4096); bloque con tick libre y `eNotReady` >1 s se descarta (`not_ready_since`); memoria GPU vía `DeviceMemoryUsageForReports()` (declarada en `vk_instance.h`), que comprueba `CanReportMemoryUsage`; `g_reported_instance` se publica al final del constructor de `Instance`; `PACE` añade `the GPU's memory N MB`.
  - `astro_core.mm`: `SetUserPath(HomeDir)` solo si es directorio (stderr `No folder for users and saves…` si no).
  - `AppModel.findGame`: un juego exige `eboot.bin` (param.sfo solo en Comprobación). `CheckView`: `.fileImporter` en el `NavigationStack`, no en un `Section`.
- Siguiente prueba: C1 KK + MSAA 1, C2 MoltenVK + MSAA 1 (con GS bypass: ojo izq. y partículas mal, fps algo optimista); criterio: MoltenVK ≥1.5× → migrar a MoltenVK + conversión propia de los 2 GS; si no, seguir con KK optimizando pasadas (`GPU_PASSES`) y memoria (copias GPU de la memoria del juego).

## Build f55a7b9 probada (KosmicKrisp) — el juego es jugable
- Funciona: KK carga y renderiza; GS reales (sin `GS_BYPASS`); ambos ojos; ~25–30 fps en juego (topa en 30 = 3 refrescos a 90 Hz), sin errores de render en el log.
- Problemas: halos en algunas texturas/efectos; imagen borrosa con aliasing (ajuste del usuario: resolución 1440 = 1440x1536 por ojo, sin `SHADPS4_TITLE_EYE_WIDTH`); tirones de 1–2 s que coinciden con compilaciones de pipelines (5–12 por ventana de 5 s); `PAD` siempre `assumed` (las manos nunca colocan el mando); deriva del rumbo del giróscopo.

## Estado tras la última build probada en el dispositivo (commit 9389978; 0b88fc8 probada: pasa la calibración, ojo izq. mal, efectos corruptos, mando girado)

Funciona en el dispositivo:
- Arranque completo del juego bajo FEX: carga de módulos, main de ASOBI, salas, audio (se oye).
- Fotogramas del visor entregados a la escena inmersiva (`GameRenderer.swift`), con reproyección por pose.
- **Primer 3D visible** con el bypass experimental de GS: ojo derecho correcto, ojo izquierdo deforme.
- Sin bloqueos por bucles de fallos de página (causa raíz resuelta, ver abajo).

No funciona / pendiente:
- Ojo izquierdo deforme (GS no emulado; el bypass dibuja el ES como VS).
- Rendimiento: tramos de 2.8–5 fps con muchos efectos (log 2026-10-07 22:12:53–22:13:28: 14 frames/5 s), ~25 fps en otros con el compositor a 50 Hz. Audio petardea.
- Calibración (pantalla verde con silueta): causa encontrada — el juego llama a `sceVrTrackerRecalibrate` y espera ver el estado CALIBRATING→TRACKING; nuestro `vr_tracker.cpp` era el stub de 0.13. Corregido con la fusión de upstream (ver abajo), pendiente de probar.
- Borde azul provisional en `Shaders.metal` (diagnóstico; quitar cuando haya imagen correcta).

## Sesión 2026-10-08: fusión con upstream AstroQuest + diagnóstico

### Fusión
- Base del fork: upstream `bigmak94/AstroQuest` 0.13 (`8431e43`). Fusionado a 3 vías con upstream `807ca1f` (0.20). Único conflicto: `vk_presenter.cpp` (`expected_ratio` ahora `std::optional` de upstream + bloque visionOS conservado).
- Trae: `vr_tracker.cpp` Recalibration (CALIBRATING 200 ms tras `sceVrTrackerRecalibrate`), entradas completas del GS (V0–V7, InvocationId) en `translate.cpp`/`spirv_emit_context.cpp`, viewports conservan su slot en `vk_rasterizer.cpp`, colocación del mando sin tracking (`MoveOwnPadPlace`/`SwitchPadPlace`), giro por pasos, idioma de consola, builds 1.00/1.04 conocidas (`known_title_builds.h`), `ShaderBinaryVersion = 3`.
- `openxr_host_visionos.mm`: añadido `OpenXrHost::AudioDevicesChanged()` vacío (nuevo en upstream, lo llama `sdl_audio_out.cpp`).
- Comprobación local: `clang++ -fsyntax-only -DSHADPS4_VISIONOS=1` de los ficheros fusionados (sin rutas Apple/Mach) sin errores. Script en el historial de la sesión: incluye submódulos fmt, vulkan-headers, ext-boost, robin-map, sirit(+SPIRV-Headers), magic_enum, toml11, half, xbyak, json, vma, dear_imgui, sdl3, date, spdlog, tracy, zydis, xxhash, pugixml, stb; `cmrc` con stub.

### Diagnóstico añadido
- `vk_pipeline_cache.cpp` `LogGsBypassShaders` (visionOS): por cada par ES/GS (máx. 6) escribe `GS_INFO` (hashes, tamaños, itemsize ESGS/GSVS, max out, instancias, slices del color target 0, viewports activos) y `GS_CODE <es|gs|copy> <hash> <offset>: <dwords hex>`. Para desensamblar offline con el decoder GCN del repo.
- `guest_watchdog.cpp` `ReportPace` (Apple): cada 5 s `PACE: <fps> guest frames/s; CPU <total>% in all: <hilo> <%>...` (tiempo de CPU por hilo vía `THREAD_BASIC_INFO`). Si fps < 10: hasta 6 veces por sesión, 12 muestras de pila nativa de los 2 hilos más ocupados (`PACE_SAMPLE`). Simbolizar con `atos -o <binario del IPA> -l 0x100000000`.

### KosmicKrisp en visionOS (commit siguiente a 0b88fc8)
- Motivo: KosmicKrisp (Mesa; el driver Vulkan-sobre-Metal de shadPS4 en macOS) declara `geometryShader`, `tessellationShader`, `multiViewport`, `shaderOutputLayer/ViewportIndex` (`src/kosmickrisp/vulkan/kk_physical_device.c`); emula GS por compute (`libkk/kk_geometry.cl`, `src/poly`). MoltenVK no tiene GS → con KK desaparece el bypass (`GS_BYPASS` ya no debería salir).
- `visionos/patches/kosmickrisp-visionos.patch` sobre `shadexternals/mesa` `b628375` (el commit que fija `mesa-kosmickrisp`):
  - `bridge/mtl_device.m`: fuera de macOS, `MTLCreateSystemDefaultDevice()` (exige `MTLGPUFamilyMetal4`).
  - `vulkan/kk_bo.c`: fuera de macOS, `mach_vm_*` → `vm_*` (sin `mach_vm.h`).
  - `vulkan/kk_image.c` + `kk_physical_device.c`: `VK_EXT_metal_objects` mínimo (`kk_ExportMetalObjectsEXT`: `mtlDevice`, `mtlTexture` de imagen o vista). Lo usa `openxr_host_visionos.mm` para entregar fotogramas al visor.
  - `meson.options` + `vulkan/meson.build`: opción `kosmickrisp-embedded` (enlaza Metal/Foundation/QuartzCore/IOSurface en vez de `-undefined dynamic_lookup`; install name `@rpath/KosmicKrisp.framework/KosmicKrisp`).
  - Regenerar: aplicar en un clon de Mesa, editar, `git diff > visionos/patches/kosmickrisp-visionos.patch`.
- `visionos/scripts/build-kosmickrisp.sh`: herramientas nativas (`mesa_clc`, `vtn_bindgen2`, `kk_clc`; brew llvm/spirv-llvm-translator/libclc) → cross a `arm64-apple-xros26.0` (crossfile generado) → `build/visionos/kosmickrisp/KosmicKrisp.framework` (Info.plist binario, id `org.mesa3d.kosmickrisp`). STAMP = commit + sha del patch + deployment target.
- CI (`visionos-app.yml`): caché `kosmickrisp-visionos-<hash patch+script>`; paso con `continue-on-error` (si falla, la app sale con MoltenVK); el framework se copia a `AstroQuest.app/Frameworks/` antes del zip; log `kosmickrisp.log` publicado en `ci-logs`. La clave de caché del core excluye el patch y el script de KK.
- 55f686d en el dispositivo: el framework carga (`Vulkan driver: KosmicKrisp`, interfaz de loader 7) y crashea al crear la instancia: sin loader, `vkEnumerateInstanceLayerProperties` es NULL (Mesa no lo implementa; lo da el loader). Arreglo: `KosmicKrispGetInstanceProcAddr` envuelve `vk_icdGetInstanceProcAddr` y devuelve `NoInstanceLayers` (0 capas) para esa función; también se devuelve a sí mismo para `vkGetInstanceProcAddr`.
- `vk_platform.cpp` `LoadKosmicKrisp()` (visionOS): `dlopen(<dir del ejecutable>/Frameworks/KosmicKrisp.framework/KosmicKrisp)`, `vk_icdNegotiateLoaderICDInterfaceVersion(7)`, `vk_icdGetInstanceProcAddr` como entrada del dispatcher; si falta o `SHADPS4_VK_DRIVER=moltenvk`, MoltenVK enlazado. Log: `Vulkan driver: KosmicKrisp|MoltenVK`.
- App: ajuste `vulkan_driver=kosmickrisp|moltenvk` → `SHADPS4_VK_DRIVER`; selector "Driver de Vulkan" en Ajustes > Gráficos (`Views/SettingsView.swift`, escribe `settings.txt` con `AstroSettings.write`; añade la línea si falta).
- Compila para xros (workflow `kosmickrisp-visionos.yml`, solo dispatch, misma clave de caché que la app): framework de 14 MB, exporta `vk_icdGetInstanceProcAddr`, `vk_icdGetPhysicalDeviceProcAddr`, `vk_icdNegotiateLoaderICDInterfaceVersion`. Arreglos que hicieron falta: `brew spirv-tools` (herramientas de Mesa), `CAMetalLayer.displaySyncEnabled` solo en macOS (`src/vulkan/wsi/wsi_common_metal_layer.m`), enlazar CoreGraphics y mantener `-undefined dynamic_lookup` (puntos de entrada weak de Mesa; ld avisa "deprecated on visionOS", no falla). `meson compile --ninja-args=-k0` para ver todos los errores.
- Sin probar aún en el dispositivo: carga del framework firmado por SideStore y creación de instancia sin loader.

### Análisis de los GS de ASTRO BOT (log 2026-10-08 13:30)
- Desensamblado con un decodificador hecho con `shader_recompiler/frontend/decode.cpp` (+ format/instruction, magic_enum, spdlog). LLVM 18 no desensambla GFX7.
- GS `0xf250a6ed` (ES `0x244b118d`, copy 25 dwords): carga 6 dwords por vértice del anillo ESGS, compara `s_buffer_load` de dos constantes (`s[2:5]` dword 99 vs `s[0:3]` dword 24) y solo emite el triángulo (3 vértices, paso directo) si son iguales. El bypass lo dibuja siempre → contenido de otra pasada/ojo en el ojo izquierdo.
- GS `0x3b88b54e` (3198 dwords; ES `0x3cac3810` solo escribe un índice, posición 0): genera geometría (partículas/efectos, hasta 32 vértices, 48 dwords/vértice). Con el bypass no se dibuja (posición 0) → efectos ausentes/corruptos.
- `GS_INFO`: un solo slice en el target y solo el viewport 0 (1440x1536) activo: cada ojo es una imagen aparte.

### Rendimiento (`PACE`, mismo log)
- Tramos de 3–12 fps con CPU total 11–25 % y ningún hilo ocupado → hilos esperando (GPU o sincronización), no FEX. En cargas, `RoomLoad_ATQT` ~60 %. Ojos a 1440x1536.

### Mando
- `PlayStationController.swift`: la aceleración de GameController se pasaba como `(-x,-y,-z)·g` (copiado de `SDL_mfijoystick.m`, que no cambia ejes en el acelerómetro) → en reposo el emulador veía el mando apuntando al jugador (90° de cabeceo). Ahora `(-x, -z, +y)·g`, mismos ejes que el giróscopo `(x, z, -y)`. Cada 600 lecturas, `Controller motion:` con los valores crudos.
- `vr_runtime.cpp` `GetPad`: cada 5 s `PAD: <seen|own place|assumed> at x y z from the head; heading/pitch/roll; accelerometer`.


## Cambios por archivo (sesión de depuración en dispositivo)

### Memoria y páginas de 16 KB
- `src/core/address_space.cpp`: `Impl::Protect` en visionOS redondea a páginas de 16 KB (begin hacia abajo, end hacia arriba) antes de `mprotect`; ASSERT con rango y errno.
- `src/video_core/page_manager.cpp`:
  - Constantes de fichero `HOST_PAGE_SIZE`/`HOST_PAGE_BITS` (16 KB/14 en visionOS). Dentro de `PageManager::Impl` se redefinen `PM_PAGE_SIZE`/`PM_PAGE_BITS` = HOST_*; **sin esto la búsqueda de nombres usaba los de la clase `PageManager` (4 KB)** — fue el bug que provocaba el bucle infinito de fallos.
  - `PageState` en visionOS: `u16` con 11 bits de escritores y 5 de lectores; `AddDelta` devuelve `PageWatcherCount`.
  - `UpdatePageWatchers`/`UpdatePageWatchersForRegion` (visionOS): cada subpágina de 4 KB (`TRACKED_PAGE_SIZE`) cuenta una vez en su página de 16 KB; `Protect` de la página entera al cambiar permisos.
  - `GuestFaultSignalHandler`: en visionOS, además de la dirección tocada, invalida/lee las otras 3 subpáginas de 4 KB de la página de 16 KB.
- `src/video_core/renderer_vulkan/vk_rasterizer.cpp`: `ReadMemory` en visionOS devuelve false si `!buffer_cache.IsRegionRegistered` (evita crear buffers desde el manejador de fallos).
- `src/core/memory.cpp`: en `MapMemory`/`MapFile`, un `Fixed` fuera del espacio reubicado se mapea donde haya hueco (avisos `Fixed mapping at ... outside`).
- `src/core/libraries/kernel/memory.cpp`: logs de `sceKernelMprotect`/`sceKernelMtypeprotect` a DEBUG (eran miles/s con log síncrono).

### Señales y FEX
- `src/core/fex/fex_guest_engine.cpp` `HandleGuestSignal`: en Apple solo trata como desalineado si `ESR & 0x3f == 0x21`. **Darwin entrega los fallos de permiso como SIGBUS/BUS_ADRALN**; antes FEX los "arreglaba" y el gestor de memoria de la GPU nunca se enteraba (bucle infinito en código JIT).
- `fex_guest_engine.cpp`: `ValidateHostMapping` con `vm_region_64`; `kHostPageSize = 16384`; guarda de CallRetStack con esa página.
- `visionos/patches/fex-darwin.patch`: x18 reservado, escritura por el mapeo RW de la arena, `aligned_alloc` vía `posix_memalign` (alineación mínima `sizeof(void*)`), páginas de 16 KB. Regenerar con `git add -A && git diff --cached`.
- `src/core/signals.cpp`: `DescribeCrash` (líneas `ASTRO_CRASH`) y `BreakFaultLoop` (visionOS): tras 2000 fallos seguidos en la misma dirección escribe `ASTRO_FAULT_LOOP` (señal, código, ESR, pc/lr, protección real vía `vm_region_64`) y abre la página RW. Red de seguridad; no debería dispararse ya.

### Vigilante (watchdog)
- `src/core/guest_cpu/fex_hle_bridge.cpp`: `ThreadActivity` guarda el puerto Mach; `ThreadName` usa `THREAD_EXTENDED_INFO` en Apple (antes leía /proc → "not tracked").
- `src/core/guest_cpu/guest_watchdog.cpp`: `DescribeNativeThreads` para Apple con `task_threads` + `thread_suspend`/`thread_get_state` + `vm_read_overwrite` del encadenado de frames. Direcciones de la app relativas a 0x100000000 (symbolizar con `llvm-symbolizer --obj=<binario del IPA>`; el binario conserva símbolos).
- A los 20 s sin fotogramas imprime estado de cada hilo invitado (HLE en curso + llamadores x86) y pilas nativas.

### Presentación en el visor
- `src/video_core/renderer_vulkan/vk_presenter.cpp` `PrepareHmdFrame` (visionOS): no se dibuja/presenta el frame de la ventana 2D si hay imagen local del visor; mientras `OpenXrHost::IsShowing()`, nunca se recurre a la ventana.
- `src/core/vr/openxr_host_visionos.mm`: `NumSlots = 6`; `BeginFrame` espera hasta 100 ms en `slot_freed` (condition_variable) a una imagen libre; `notify_all` en EndFrame/DropFrame/ReleaseFrame/TakeFrame.
- `visionos/App/Render/GameRenderer.swift`: `reportNow` escribe cada 5 s `Headset: N game frames taken in M refreshes...` (textura, formato, mismo device, tangentes, orientación).
- `visionos/App/Render/Shaders.metal`: borde azul provisional en los bordes de la imagen del juego.

### Gráficos
- `src/video_core/renderer_vulkan/vk_pipeline_cache.cpp` `RefreshGraphicsStages`, caso `EsGs` sin soporte de GS (visionOS): **bypass experimental** — `bind_stage(Stage::Export, LogicalStage::Vertex)` sin GS; log `GS_BYPASS` (primeras 24). Datos observados: todos los GS de ASTRO BOT son `instances 1, max vertices out 32, primitive in 6, out 2 (TriangleStrip)`.
- `vk_graphics_pipeline.cpp`: en visionOS un pipeline rechazado lanza `std::runtime_error` (la caché lo captura y salta el dibujo) en vez de ASSERT.
- `src/video_core/texture_cache/blit_helper.{h,cpp}`: `CreateMsCopyPipeline` y `CreateColorToMSDepthPipeline` devuelven bool; si Metal rechaza el pipeline se registra una vez (`failed_ms_copy_pl`/`failed_ms_depth_pl`) y se omite la copia.
- `src/shader_recompiler/ir/passes/flatten_extended_userdata_pass.cpp`: implementación ARM64 también en `__APPLE__`.

### App / empaquetado
- `visionos/project.yml`: `-Wl,-exported_symbol,__mh_execute_header` (solo exporta eso; arregló glifos rotos por interposición de FreeType/zlib/operator new).
- `.github/workflows/visionos-app.yml`: compila solo con `[build]` o dispatch (ojo: el filtro `paths` mira solo el push; un `[build]` que solo toca `bitacora.md` no dispara nada → usar `gh api -X POST repos/escojoncio/AstroVisionPro/actions/workflows/visionos-app.yml/dispatches -f ref=main`); timeout 150 min; publica `visionos-latest` (`AstroQuest.ipa`).
- `.github/workflows/stikdebug-visionos.yml` + `.github/stikdebug/autoquit.patch`: StikDebug-visionOS (rama release, 8a7fc130) con `autoQuitAfterEnablingJIT = true`, ID `com.stik.stikdebug`; release `stikdebug-visionos`.
- Bundle ID: `visionos/project.yml` `PRODUCT_BUNDLE_IDENTIFIER: com.kdt.livecontainer` (el App ID ya registrado en la cuenta de firma; SideStore añade el sufijo del equipo). El IPA de la release sale ya con él; se instala con SideStoreRAM. Para reempaquetar a mano un IPA antiguo: plistlib conservando formato binario + `zip -qry -X`.

## Flujo de trabajo
- Logs: el usuario manda `consola-*.txt` (la app los guarda en Documents). Quitar ANSI con `sed 's/\x1b\[[0-9;]*m//g'`.
- Release: `gh api repos/<owner>/AstroVisionPro/releases/tags/visionos-latest` → asset `AstroQuest.ipa`.
- El remoto `origin` del clon local tiende a apuntar al nombre antiguo del repo: hacer push explícito a la URL de AstroVisionPro.

### Cambios tras f55a7b9
- `HeadsetTracking.swift`: log `Hand tracking: <allowed|not allowed|not asked for>; running`; cada 5 s `Hands (<estado>): both seen N, one N, none N, both but not holding N frames; palms last X m apart`. Palma: si los dedos no se ven (mano cerrada sobre el mando) o no hay esqueleto, se usa el origen del ancla (muñeca). Distancia válida entre palmas 0.04–0.45 m (antes 0.05–0.32). Con una sola mano y sin offset previo: mando a 8 cm hacia el centro según el eje derecho de la cabeza.
- `vr_runtime.cpp` `UpdatePadGyro`: sesgo del giróscopo aprendido en reposo (acelerómetro ~g y |w−sesgo| < 0.08 rad/s durante >0.5 s, constante 2 s) y restado; sin referencia de rumbo de las manos, tras >1 s quieto el rumbo se lleva hacia el frente del asiento (`view_turn`) con ganancia 0.25/s. Miembros nuevos `pad_gyro_bias`, `pad_still_seconds` en `vr_runtime.h`.
- `vk_pipeline_cache.cpp`: `PIPELINE_SLOW <hash>: <ms>` para creaciones ≥30 ms (shaders + pipeline en el hilo del procesador de comandos).

### Compilación de pipelines en segundo plano (sin tirones)
- `vk_pipeline_cache.{h,cpp}`: con `async_pipelines` (por defecto en visionOS; `SHADPS4_ASYNC_PIPELINES=0|1`) los pipelines gráficos nuevos se crean en `PipelineWorkers` (clamp(núcleos/3, 2, 4) hilos `shadPS4:PipelinesN`); mientras no están listos `GetGraphicsPipeline` devuelve nullptr y el rasterizador salta el draw. `PendingGraphicsPipeline` guarda copias de `Shader::Info` (las vivas cambian en cada draw), runtime infos, módulos, fetch shader y `sdata`; al terminar `FinishPendingGraphicsPipeline` llama a `GraphicsPipeline::UseStages(live_infos)`, `RegisterPipelineData` y lo mete en `graphics_pipelines`. Fallo → entrada nullptr (draw omitido siempre, como antes). `PIPELINE_SLOW <hash>: <ms> to make, ready <ms> after its first draw ... draws left out`.
- `vk_graphics_pipeline.{h,cpp}`: `GetVertexInputs` → función estática `CollectVertexInputs`; `PrepareSerialization` hace en el hilo principal lo que el constructor lee del estado vivo (vértices si no hay vertex input dinámico, multisample, TCS/TES de rect/quad lists) y el worker construye con `preloading=true`. `IsStorage` siempre es true, así que el layout con sharp por defecto es idéntico.
- Pipelines de compute siguen síncronos.
- App: interruptor "Compilar shaders en segundo plano" (Ajustes > Gráficos, `async_shaders`) → `SHADPS4_ASYNC_PIPELINES`; `MESA_SHADER_CACHE_DIR=<Library/Caches>/mesa_shader_cache` para la caché de Mesa/KK.

## Pendiente (orden recomendado)
0. **Carpeta VPS4** (decidido): carpeta llamada exactamente `VPS4` creada por el usuario en la raíz de "En mi Apple Vision Pro"; la app no puede buscarla sola (sandbox) → un `.fileImporter` de carpeta guiado ("Elige la carpeta VPS4", rechaza otro nombre), bookmark guardado en UserDefaults y además en el llavero (probar si resuelve tras borrar y reinstalar con el mismo equipo y bundle ID; si no, volver a pedirla). Dentro: `Juegos` (detectar por `sce_sys/param.sfo` o `eboot.bin`), `Partidas` (`Common::FS::SetUserPath(PathType::HomeDir, …)` en `astro_core_start` vía env `SHADPS4_HOME_DIR`; migrar `Library/Application Support/shadPS4/home` si `Partidas` está vacía), `Cachés` (`MESA_SHADER_CACHE_DIR`). `UserPaths` de `path_util.cpp` se inicializa estáticamente: no usar HOME/env para el user dir.
0a. **Siguiente decisión según `GPU_PASSES`**: si el coste se concentra (GS emulado por KK, MSAA, copias) → atacar esas pasadas; si está repartido → valorar MoltenVK + conversión propia de los 2 GS de ASTRO BOT. Memoria: evitar copias GPU de la memoria del juego (memoria unificada; KK expone `VK_EXT_external_memory_host`).
0c. Antiguo punto 0, **Carpeta del juego fuera de la app** (sobrevive a borrar la app): `.fileImporter` de carpetas + bookmark security-scoped (`startAccessingSecurityScopedResource`) guardado en `UserDefaults`; tras reinstalar hay que volver a elegirla (el bookmark muere con la app). Dentro van juego(s), saves (user dir del emulador, hoy en Documents: ver `Common::FS::GetUserPath` en `platform/visionos/astro_core.mm`), `settings.txt`, registros y cachés de shaders. Detectar juegos por `sce_sys/param.sfo` (lista, no solo CUSA12392). Ubicación recomendada: carpeta de una de las apps que siempre quedan instaladas o iCloud Drive (cuidado con archivos no descargados).
0b. **Hacia un reproductor de PSVR genérico**: separar lo específico de ASTRO BOT (`core/known_title*.{h,cpp}`) de lo genérico (`sceHmd`, `sceVrTracker`, reproyección, mando); selector de juego en la app. PS Move: no implementado; mapear los Sense de PS VR2 (`SenseTracking.swift`, `AccessoryTrackingProvider`: 6DoF) a dispositivos Move del tracker (`ORBIS_VR_TRACKER_DEVICE_MOVE`) + librería `sceMove` (botones, gatillo, giróscopo, vibración, luz).
1. **Probar la build con MetalFX/GPU_TIME/GC** (con `resolution=1440`): giróscopo al girar la cabeza (`Controller motion: no reports…`/`reporting again`); `PACE` memoria usada/restante al entrar al mundo; `TEXTURE_GC`; `GPU_TIME` (si ~100 %: GPU saturada → medir por pasada/GS de KK; si bajo: esperas/sincronización); `MetalFX:` y nitidez percibida.
2. **Rendimiento**: medir tiempos de GPU (timestamps por fotograma) para separar GPU real de esperas; revisar espera en CPU de `VrExporter::Deliver` (`GetMasterSemaphore()->Wait`) y el seguimiento de páginas de 16 KB.
3. **Posición del mando**: si con el acelerómetro corregido sigue mal, Object Tracking (`ObjectTrackingProvider`) con objeto de referencia del DualSense (escaneo + Create ML en macOS) fusionado con giróscopo y manos. Accessory tracking solo vale para Sense de PS VR2 (ya implementado en `SenseTracking.swift`).
4. Texturas BC6H/BC7 con uso Storage que MoltenVK no crea (`image.cpp:247`).
5. Activar caché de pipelines en disco.
6. (Hecho) Comprobación en la app de ficheros `sce_sys` (param.sfo obligatorio; playgo-chunk.dat, npbind.dat, nptitle.dat, icon0.png, pic0.png, pic1.png, trophy/trophy00.trp opcionales) en la pestaña Comprobación y en la tarjeta Juego.
7. Aviso de FEX "Failed to mprotect last page of code buffer" (inofensivo por ahora).
