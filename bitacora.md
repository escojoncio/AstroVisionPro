# Bitácora — AstroVisionPro

ASTRO BOT Rescue Mission (CUSA12392) y KITCHEN (CUSA06799), PSVR, en Apple Vision Pro (visionOS 27). Base shadPS4 ARM64 (HLE, cargador, kernel, PM4/Liverpool) + FEX (CPU, JIT) + VPKEngine (GPU). App en `visionos/`, release `visionos-latest/AstroQuest.ipa`.
Detalle anterior en `git log -p bitacora.md`. Detalle técnico estable de la ruta GPU PS4: `notas/vpkengine-ps4.md`.

## Last done
- 2026-11-10 RONDA LOGS_8 (MSAA 4x) + LOGS_9 (MSAA 1x), misma build a762289 / motor 8e85a98. Usuario: brazos del gorila a través y encima de todo, efectos solo en un ojo y encima de todo, corrupción esporádica de shaders/efectos, línea negra en aristas, fps sin mejora y muchos momentos <20; nada de eso con KosmicKrisp. Análisis y código por subagentes; revisión adversarial en 2 rondas sin bloqueantes.
  - MEDIDO por frame guest, 4x→1x: zona ~2000 draws 26,3→31,3 fps (GPU 29,8→22,7 ms); ~1450 draws 32,7→33,2 (24,1→20,0); ~2700 draws 19,0→22,6 (36,0→29,1); zona final ~1300 draws 20,1→23,1 (46,2→38,6, GPU 89-93 %). El ahorro de 1x está casi todo en transparencias.
  - Panel 100 Hz: solo existen 50 fps (base, 2 refrescos) y 33,3 (fallback, 3). Regulador en fallback ~96 % de la sesión: sube con GPU <18,4 ms durante `need` s (known_title_pace.h ~170) y su cifra de GPU eran frames en vuelo (+4-6 ms sobre `busy_union`).
  - Por debajo del tope manda el hilo CP: periodo = «Submitting» + «CatchUp» (el juego no entrega N+1 hasta que el CP acaba N: `WaitGpuIdle`, gnmdriver.cpp ~108). CP en zona 2000 draws 1x: draws 20,2 ms (10,1 µs/draw: bind 5,3, shader lookup 1,9, adaptador 1,5), compilar frame 4,0, espera a GPU 3,8 (9,0 en 4x; 9,7 con 2700 draws; 25 en la zona final). Game:Main 13-21 %: FEX no limita. Presentación, holds, flip, wait_label: no limitan.
  - Espera a GPU = `IT_WRITE_DATA` de 256 B, 1 por frame (`why=other a=0x70453a2980 / 0x70453a34c0 by=draw_buffer`): `WriteDataOrdered` no registraba el rango con `cpuAccessed` y el V# se ligaba en sitio. Otra espera: lectura GDS en `EVENT_WRITE_EOS` (liverpool.cpp ~1608; 19 ms/frame en una escena de ~6 s), sin tocar.
  - GPU_SHADER_BENCH (4x): 27,6 fps, GPU 27,5 ms; fs 0x1759c590391 −6,4 ms; los 8 más caros −13,7 ms. Los fps solo subían a 34 por el tope del regulador y porque el CP limita.
  - MSAA 4x real (s4, resolve, sin sample shading); el compositor aplica SMAA siempre (por eso 1x y 4x se ven parecido). Quest (README-QUEST-VR.md): MSAA 1x, 960x1080-1200x1280 a 30 fps, 816x870 en lo más pesado.
  - DESCARTADO con datos para brazos/efectos de un ojo: alpha-to-mask sin color (`a2m_unwritten_draws=0`: b2be31c no actúa), zrange/clamp (0), depth sin test en 4x con color (+84 draws en 90 s), depth DontCare entre pases, clear de depth tras el pase opaco (es `d:LSR` = Load con rect parcial; probable clear de stencil; falta el plano), siembra de color vacía (`seed_missing=0`), 8e85a98 (resuelve a 54 en todo pase antes de la lectura 1x). Los brazos ya estaban en LOGS_5 (antes de color en tile y fusión de prepase). Las capturas framecap-1 de LOGS_8 se tomaron dentro de la prueba L3+R3 (opaco negro = shaders fuera): no valen. Brazos, efectos de un ojo y corrupción: SIN CAUSA.
  - Hecho aparte (confirmado): textura de sombra D32F 1024x1024x8 (T# type 13) se lee de memoria y vale 1.0 (sin oclusor) mientras existe un depth target 512x512x5 en el mismo base; `findTarget` (motor renderer.cpp ~4328) no sirve un target menor que el T#: faltan sombras de luces locales. Sin arreglar (falta saber si es la misma superficie).
  - Línea negra en aristas, causa por código (unverified en visor; falta saber si desaparece con 1x): el color 4x en tile se resuelve y resiembra en cada frontera de encoder; una frontera del motor a mitad del pase opaco (corte de CB, compute/copia/clear intercalado; 1213 de 1648 CBs de escena en una sesión) mezcla color de clear en las muestras de arista. Arreglo diseñado, NO hecho: guardar muestras reales en fronteras del motor con imagen sin resolver (renderer.cpp ~2058, ~5628, `submit()` ~6969; test `msaa_colour_cut_keeps_samples`; ajustar `msaa_colour_on_tile`; coste estimado 1-1,5 ms GPU por ojo cortado).
  - CAMBIOS (subidos, SIN BUILD; `.mm`, known_title.cpp, driver.cpp, gnmdriver.cpp, vk_scheduler.cpp y Swift sin compilar hasta CI). Motor 021167a (ctest 611/611): `Scheduler::syncWrite` (escritura CP ≤4 KiB que esperó → `cpuAccessed`; los draws siguientes copian el V# al grabar; opt-out `VPKENGINE_WRITE_DATA_LIVE=1`; test en `vpps4.buffer_snapshot`); timer `GPU busy_union` siempre activo y tolerante a completados fuera de orden; `Hooks::submit`; captura de usuario `beginSceneCapture`/`endSceneCapture`; sondas. App: `WriteDataOrdered` → `syncWrite`; el regulador recibe `max(tiempo real de GPU, CPU del hilo CP)` por frame (`Pacing::GpuFrameTime`/`FrameWorkTime`, `FrameStats::GpuTime/CpTime`, `Present::GpuTimeNs`; regla y umbrales intactos; Vulkan igual que antes; tests en `tools/tests/known_title_pace_test.cpp`).
  - SONDAS NUEVAS (Modo diagnóstico): `VPKENGINE_PROBE CPFRAME` (ms por imagen: idle, draw, submit por hilo, espera a GPU, lock del motor, `wait_gpu_idle`); RATES `buffer_snapshot_no_{big,align,flat,cpu_read,history,gpu_wrote,label}`, `pointer_snapshot_no_cp_access`, `unaligned_cb_gpu_written` (+ líneas `UNALIGNED_CB_GPU`); `CLEARPASS` (plano y motivo de cada clear); DMASYNC pasa de `why=other` a `why=write_data`. CAPTURA DE USUARIO: L1+R1 sujetos + L3 (sin R3) con el fallo en pantalla → `SCENECAP`, `SCENEDRAW cap=N` (estado completo de cada draw con depth de escena, `view=` por ojo) y PPM nativos `framecap-uN.*` (≤384 MB por captura, ≤32 frames de dispositivo).
- 2026-11-10 RONDA LOGS_7 (build e46ff9a): motor b2be31c/8e85a98 (alpha-to-mask con color 0 no escrito, `psIterSample`, resolve único del depth compartido), app c8975bc (regulador por plan del panel, prueba L3+R3 en VPKEngine). Suma de ahorros brutos seguros de GPU a 1440x1536 4x: 2-4 ms de ~35. Detalle en git.
- 2026-11-10 RONDA LOGS_6 (build 3c406cc): `Present::GpuBusy`, `gpu.excl` y hilo de envío por defecto; motor: prepase+color en un pase (`depthPartners`), color MSAA en tile (`autoMsaa`), pase 1x con companion del depth MSAA, V# RO ≤4 KiB en `cpAccess` copiado al grabar. Detalle en git.
- 2026-11-10 RONDA LOGS_5 (build 472c90b): posición invariante entre prepase y color (`lift.cpp positionOutput()`); confirmado por el usuario.
- Anterior: `git log -p bitacora.md`.

## Current state
- Funciona (confirmado en visor): imagen sin polígonos negros ni bloques; sin tirón periódico; sin cuelgues con hilo de envío.
- Sin compilar ni probar en visor: todo lo de la ronda LOGS_8/9 y lo de LOGS_7.
- Pendiente: fps (tope 33,3 por regulador; CP 24-28 ms/frame; GPU 22,7 ms en 1x y 29,8 en 4x; caídas <20 en zonas de ~2700 draws y en la zona final con GPU saturada); brazos del gorila; efectos en un solo ojo; corrupción esporádica; línea negra en aristas; sombras de luces locales; KITCHEN: crash guest nulo tras assert del juego (unverified).
- Para 50 fps en juego cargado hacen falta a la vez CP ≤~18 ms y GPU ≤18,4 ms por frame.

## Pendiente (orden)
1. NO compilar hasta que el usuario pase el log que tiene pendiente (sesión con Motor gráfico → Sombra en la zona del gorila: compara por draw contra Vulkan, `ASTRO_SHADOW diff/summary`, shadow_compare.h ~448) y diga si la línea negra desaparece con MSAA 1x.
2. Coste por draw del CP (10,1 µs → objetivo ~6,5): reutilizar enlaces/lookup del draw anterior con el mismo material; `bind_table_other`; adaptador.
3. Zona final (GPU 38-46 ms con ~1300 draws): atribuir por pase con `gpu.excl`. Espera GDS de `EVENT_WRITE_EOS`.
4. Con la captura de usuario y la sesión en sombra: causa de brazos / efectos de un ojo; con `unaligned_cb_gpu_written`: corrupción.
5. Línea negra: arreglo diseñado arriba. Sombras locales: `findTarget`. D2 (depth array limpiado slice a slice); NaN RGBA16F; LDS por lane / v_mbcnt.
6. Textos «Pace governor: the GPU took…» no dicen si la cifra es de GPU o de CP.

## Decisions
- Arreglos generales de GPU PS4, nunca por juego, dirección ni hash; opt-out por variable de entorno; todo activo por defecto (el usuario no puede poner variables).
- Referencia = interpretación de shadPS4 (renderer Vulkan/KosmicKrisp de la app, lento pero correcto) y documentación GCN/Liverpool.
- Bajar resolución no cuenta como mejora; foveado: por ahora no.
- Depth MSAA siempre con muestras reales (EQUAL por muestra tras el prepase); solo el color va en tile.
- La etiqueta ordenada por GPU es la barrera que impide al juego reciclar memoria ligada en vivo: no etiquetas inmediatas.
- Diagnóstico solo con «Modo diagnóstico»; logs en <VPS4>/LOGS; una build con todo, no builds sueltas.

## Files in play
- Motor (`fix-resolve-extent`): `gpu/ps4/src/{renderer,scheduler,lifetime}.cpp`, `gpu/ps4/include/vpps4/{renderer.h,scheduler.h,lifetime.h}`, `gpu/core/include/vpgpu/core/{probe.h,submit_policy.h,commands.h}`, `gpu/core/src/{frame_compiler,device}.cpp`, `gpu/metal2/src/metal_backend.mm`, `gpu/shader/gcn/src/lift.cpp`, tests `gpu/ps4/tests/{coherence,renderer,msaa}_tests.cpp`, `gpu/core/tests/{core,probe}_tests.cpp`.
- App: `shadps4-arm64-main/src/platform/visionos/{vpkengine_renderer.mm,vpkengine_renderer.h,vpkengine_presenter.{h,cpp},astro_core.mm}`, `src/core/{known_title.cpp,known_title_pace.h}`, `src/core/libraries/videoout/driver.cpp`, `src/core/libraries/gnmdriver/gnmdriver.cpp`, `src/video_core/amdgpu/liverpool.cpp`, `src/video_core/renderer_vulkan/{vk_scheduler.*,gpu_bench.cpp}`, `src/common/diagnostics.h`, `visionos/App/Core/AstroSettings.swift`, `visionos/vpkengine-gpu.ref`.

## Module index
- `notas/mapa.md`: cadena CPU/GPU/presentación, dónde está cada función, logs, app, CI.
- `notas/vpkengine-ps4.md`: ruta GPU PS4 sobre el motor unificado, causas ya resueltas, sondas, cómo medir, ramas y repos; BC y sombra de píxeles.
