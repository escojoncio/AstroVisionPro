# Bitácora — AstroVisionPro

Port de ASTRO BOT Rescue Mission (PSVR, CUSA12392 v1.00) a Apple Vision Pro (visionOS 27), camino hacia un emulador de PSVR general.
Base: shadPS4 ARM64 (`shadps4-arm64-main/`) + FEXCore (x86-64 → ARM64, JIT) + KosmicKrisp (Mesa, Vulkan sobre Metal; MoltenVK como alternativa).
App visionOS en `visionos/` (SwiftUI + Compositor Services + ARKit + GameController). Release `visionos-latest/AstroQuest.ipa` (bundle ID `com.kdt.livecontainer`, SideStore).
JIT: arena RWX preparada por StikDebug (protocolo `brk #0xf00d` + universal.js); la app hace detach al terminar.
Compactada el 2026-10-11: lo resuelto queda en «Histórico» como una línea; el detalle está en el historial de git de este fichero (`git log -p bitacora.md`).

## Estado (2026-10-11, noche) y siguiente sesión
- Última build: 50110d0 (run 38157060123), OK, sin probar: etiqueta de frame de la reproyección + diagnóstico de MSAA (abajo). Última probada: 9f8f123 (log 18:38, KITCHEN; MSAA 2x activo).
- KITCHEN con 9f8f123: `sceVrTrackerInit` aceptado (bloque de 144 bytes, el nuestro es de 128: layout de otro SDK; `init: parameter block:` en el log), HMD y mando registrados, `sceHmdReprojectionInitialize` (type 1, pipe 4 queue 3), `SetCallback` (stub), `SetDisplayBuffers(1, 0, 1)`, **2 `sceHmdReprojectionStart`** (ojos 960x1080, tan 1.732/1.0/1.0/1.192) y se congela: `GpuCommandProcessor` y `GameThread` al 100 %, `PACE 0.0`, el visor sin frames (`texture 1920x1080`, luego 0). Hipótesis: espera (WAIT_REG_MEM en GPU o sondeo en CPU) sobre `OrbisHmdReprojectionParam::frame_label`, que la reproyección de la consola escribe al leer los ojos; la nuestra no. Dos búferes → 2 frames y bloqueo.
- Siguiente: KITCHEN con la build en curso: buscar `REPROJECTION_LABEL` (se resolvió una espera de GPU), `frame N: frame label at … (now …)` (valores que el juego pone), `PM4 WAIT_REG_MEM stalled` (otra espera de GPU, con dirección/valor/ref). Si no sale ninguna y sigue colgado: el juego sondea la etiqueta en CPU → escribirla en `sceHmdReprojectionStart`/al entregar el frame con el valor que esperan (deducir de los `now` de los frames). ASTRO BOT con MSAA 2x/4x: bordes, fps y memoria (pendiente de log).
- Herramientas aquí: comprobación de sintaxis con `clang++ -std=c++23 -fsyntax-only`, submódulos (`git submodule update --init --depth 1`, de uno en uno si falla): fmt spdlog vulkan-headers robin-map magic_enum ext-boost sirit (+ `externals/sirit/externals/SPIRV-Headers`) toml11 xbyak zydis vma miniz half json xxhash tracy dear_imgui sdl3; `-DSPDLOG_FMT_EXTERNAL`, `-DVK_NO_PROTOTYPES -DVULKAN_HPP_NO_CONSTRUCTORS -DVULKAN_HPP_NO_STRUCT_SETTERS -DVULKAN_HPP_HAS_SPACESHIP_OPERATOR -DVULKAN_HPP_DISPATCH_LOADER_DYNAMIC=1 -DVULKAN_HPP_NO_EXCEPTIONS`, `-DSHADPS4_VISIONOS -DENABLE_OPENXR_HOST`, un `miniz_export.h` vacío. `vk_presenter.cpp` da 2 errores ajenos de ImGui (ImVec2) sin el imconfig del proyecto. spirv-cross: compilar KhronosGroup/SPIRV-Cross con cmake. Fuente de KK: `git fetch --depth 1 --filter=blob:none https://github.com/shadexternals/mesa.git b628375fb1fd99476bfbaaa0532deb6fe3a6870e` con sparse `src/kosmickrisp/`.
- Comprobar que el visor tiene la build nueva antes de leer un log: línea de `vr_tracker.cpp:NNN` / `Multisampling limited to N` / ajustes nuevos en la app (SideStore a veces deja la anterior).

## Build 50110d0 (sin probar) — diagnóstico de MSAA
- ASTRO BOT con `SHADPS4_MAX_MSAA=2` (log 18:43): `Multisampling limited to 2 samples`, pero el usuario no ve suavizado (igual que con 4x el 2026-10-09). Hipótesis: EQAA (el juego pide 8 muestras) resuelto por shader propio con FMask (shadPS4 apenas lo emula → se lee una muestra) frente a resolve de CB (`Rasterizer::Resolve` → `Image::Resolve`: `resolveImage` si el host es MS, `SmoothInto` con `SHADPS4_RESOLVE_AA=1` si es 1x).
- Logs nuevos: `MSAA: image WxH fmt at addr: the title's N samples, M on the host` (`image.cpp` ctor, 12 primeras); `MSAA: resolve …` (`Image::Resolve`, 6 primeras); `MSAA: FMask decompression … skipped` (`vk_rasterizer.cpp`, 4); `MSAA: <stage> shader <hash> reads N multisampled image(s), M FMask(s)` (`vk_pipeline_cache.cpp` `LogMsaaReads`, 16).
- Rendimiento con 2x (log 18:43): mundo 24–27 fps a 90 Hz, 37–42 ms/imagen (thermal fair): ~+7–10 ms frente a 1x sin beneficio visible.

## Build 50110d0 (sin probar) — etiqueta de frame de la reproyección (general)
- `hmd/hmd_reprojection.cpp`: `Reprojection::frame_labels` (las 8 últimas `param->frame_label`, anotadas en `sceHmdReprojectionStart`); log de los 4 primeros frames con la etiqueta y su valor (`frame N: frame label at …`), `unknown_48`, `unknown_50`. `SatisfyReprojectionLabelWait(address, function, ref, mask)` (declarada en `hmd.h`): si la dirección cae en una etiqueta anotada (u64, rango de 8 bytes), escribe el valor que cumple la comparación de WAIT_REG_MEM (1 <: ref−1; 4 !=: ref^mask; 6 >: ref+1; resto: ref; bajo la máscara) con `Memory::TryWriteBacking` (o memcpy), como los EOP; log `REPROJECTION_LABEL` (8 primeras).
- `video_core/amdgpu/liverpool.cpp` `WaitRegMem` (gfx y ASC): llamada antes del bucle y cada 1024 vueltas dentro (el frame puede entregarse después de empezar la espera); el log `PM4 WAIT_REG_MEM stalled …` (cada 100 000 vueltas) también en visionOS.
- Revisión adversarial (Sonnet): aplicados reintento dentro del bucle y escritura por el backing. Aceptado: casos límite de la aritmética (ref 0 con <, desbordes) y carrera leer-mezclar-escribir con máscara parcial.

## Build 9f8f123 (run 38155314130): OK (sin probar) — VrTracker tolerante + MSAA
- `vr_tracker/vr_tracker.cpp`: `sceVrTrackerQueryMemory`/`sceVrTrackerInit` solo rechazan un bloque nulo; lo que una consola comprobaría (tamaño del bloque, tamaños/alineaciones de memoria, cola de cómputo) se registra (`init: …`, y si difiere `init: parameter block:` con los u32 del bloque) y se acepta: la librería es emulada y no usa esa memoria (nadie lee los `g_*_pointer`). Quitados los ASSERT de `VirtualQuery`. `RegisterDeviceInternal`: el mismo handle de HMD otra vez → OK; antes de Init, log `register device: not initialised` (4 primeras).
- Revisión adversarial (Sonnet): sin defectos; añadido el volcado del bloque.
- App: selector «Antialiasing del juego (MSAA)» 1x/2x/4x en Ajustes › Imagen (`msaa_samples`, por defecto 2; clave nueva, la vieja `msaa` se ignora) → `SHADPS4_MAX_MSAA` (antes fijo a 1: el juego pide 8 muestras en la escena y se dibujaba sin MSAA; solo quedaba el SMAA del visor). Quitado en 2026-10-08 por memoria/GPU con JIT 1024; hoy JIT 512 y búferes de móvil. Mirar en el log `Multisampling limited to N samples`, memoria (`PACE`/`MEMORY`) al entrar al mundo y ms/imagen; si 4x cierra la app por memoria, 2x.

## Build db3820f (run 38151282493): OK (sin probar) — pantalla plana en el visor (general)
- `vk_presenter.{h,cpp}`: `PrepareScreenAsHmdFrame(attribute, cpu_address, fov&, eye_width&, eye_height&)`: imagen del flip (como `PrepareFrame`) → `AcquireLocal(2·ancho, alto)` → `hmd_pp_pass` con una región por ojo: pantalla de 70° de ancho (tan 0,7002) centrada en las tangentes del ojo (temple/nariz según ojo), misma imagen en ambos ojos (lejos), resto negro (el pase limpia). Tamaño/FOV = los del último frame de casco (`last_hmd_fov`, `last_hmd_eye_width/height`, puestos en `PrepareHmdFrame`), o 1440x1536 y `Fov{}` de PSVR si no hubo ninguno. Sin anfitrión local → nada.
- `driver.{h,cpp}` (VideoOut): `SubmitScreenToHeadset` llamado al principio de `SubmitFlipInternal` (visionOS, índice ≠ −1): si `OpenXrHost::IsShowing()` y no ha habido `SubmitHmdFrame` en 1 s (`last_hmd_submit_ns`), manda el flip al visor como petición `is_hmd` con `export_frame` y `render_pose = screen_pose` (pose de la cabeza del anfitrión vía `Runtime::HostHeadPose` —sin `GetHead`, que fija el asiento la primera vez—, solo guiñada, tomada al empezar cada tramo de imágenes planas → pantalla fija en la sala: la app reproyecta por rotación). Cabeza sin seguimiento aún → ventana como antes. Log `SCREEN_IN_HEADSET: …` al empezar cada tramo. Sin imagen libre del visor → reintento con `EnqueueCommand` (como los frames de casco; la ventana no se ve). `TakeGuestSubmit()` para no ensuciar `FrameStats`. `Runtime::frame_counter` atómico (lo usan dos hilos).
- Revisión adversarial (Sonnet): aplicados asiento intacto, reintento en vez de ventana, ángulo mayor, contador atómico, sello de `FrameStats`. Aceptado: diálogo de servicio sin estado (igual que `HmdSetupDialog`); en modo pantalla no se atienden capturas «solo juego» ni HDR.
- `hmd/hmd_setup_dialog.cpp`: `libSceVrServiceDialog` en HLE (Initialize `hYFXG8FWThI`, Open `60-cjn5Dn0Q`, UpdateStatus `RmRtBJpoHlA`, GetStatus `kUavKmsczkY`, GetResult `cYnBkgm8I0c` = OK, Close `hBH2ABP7IeY`, Terminate `M4xKWUytNMo`): termina al instante con OK (casco puesto). Antes UpdateStatus sin resolver devolvía 0 (NONE). NIDs: base64 (`+`, `-`) de los 8 primeros bytes de SHA1(nombre + `518D64A635DED8C1E6B039B1C3E55230`) en orden inverso, 11 caracteres.
- Efecto en ASTRO BOT: lo que el juego muestre en plano antes de empezar la reproyección (logos, avisos) ahora se ve en el visor.

## Informe de rendimiento: dónde estamos, qué se probó, qué queda
Datos de los logs del visor (Vision Pro M2), ASTRO BOT, KosmicKrisp salvo donde se dice.

### Cadena
- CPU del juego: FEX (JIT). VPEngine (AOT sin JIT, build aparte `visionos-vpengine`, repo escojoncio/VPEngine): convierte en el visor (318/335 piezas), firma del pack aceptada, el eboot no llega a engancharse; nunca ejecutó el juego.
- GPU: GCN → SPIR-V (shadPS4) → KK: SPIR-V → NIR → MSL → compilador de Metal. MoltenVK: SPIR-V → SPIRV-Cross → MSL.
- Imagen: 1440x1536 por ojo, ambos ojos por frame, reproyección por pose en `GameRenderer.swift`, SMAA propio. Límite: GPU (94–100 % en el mundo); la CPU no limita.

### Números de referencia (mundo, quieto, KK, en frío)
- **~30 ms de GPU por imagen** → 30 fps a 90 Hz / 33 a 100 Hz (consola: 60). Con thermal fair/serious, +10–40 % y el visor baja a 50 Hz (25 fps) a los ~1,5–2,5 min.
- Por frame: ~2000 draws, ~6,5 M vértices, ~42–46 pasadas de Vulkan, ~49–55 encoders de render de Metal.
- Pasadas (`GPU_PASSES`): escena `1440x1536 1 colour +depth` 14–23 ms (~70 %); fuera de pasadas ~5; `1440x1536 1 colour` ~4; bloom ~3; sombras 2048² ~2; prepass ~0,6.
- Banco por etapas: normal 31–32; sin píxeles 18–20; 3 vértices por draw 16–17,5; sin solo-profundidad ~30; sin GS ~29.
- Resolución: 816 ≈ 1440 en la escena; 2160 sube (19 → 37 ms) y se queda sin memoria.
- Banco por shader: `fs 0x1759c590391` −5…−11 ms (casi todo fragmento), `fs 0xede974d10fd` hasta −3; los 8 principales a la vez −14,7 ms. `1759` decompilado: 5 texturas, 2 cascadas × 9 muestras de sombra, 4 bucles de luces, 127 lecturas de constantes; sin discard, LessEqual, opaco.
- MoltenVK: 13 fps, ~77 ms/imagen. Descartado.

### Probado
| Cambio | Resultado |
|---|---|
| Resolución dinámica + MetalFX | Sin ganancia; quitado |
| Pasada sin adjuntos 16384² → tamaño real | −6…−23 % GPU |
| GS dentro de la pasada (`KK_GS_IN_PASS`) | Coste por draw GS 0,25 → 0,12 ms |
| Juntar pasadas (`SHADPS4_MERGE_PASSES`) | Pequeña; activo |
| Pasadas solapadas (`KK_LIGHT_BARRIERS`) | Neutral; off |
| Restart en listas off | Sin efecto en ASTRO BOT |
| Memoria GS entre pasadas (`KK_HEAP_BETWEEN_PASSES`) | Neutral; activo |
| Suavizado al resolver off | ≤0,5 ms |
| Reloj de GPU automático | Corrección (sombras/efectos), no rendimiento |
| Constantes como UBO (`SHADPS4_CONSTANT_UBO`) | Sin ganancia; activo |
| Caché de pipelines + precarga | Quita tirones y draws saltados (28 988 → 36); no cambia fps |
| Píxeles sin NoContraction (`SHADPS4_EXACT_PIXEL_MATH=0`) | Sin ganancia |

### Palancas no probadas (coste/efecto)
1. **Robustez**: el dispositivo pide `robustBufferAccess2`, `robustImageAccess2`, `nullDescriptor` (`vk_instance.cpp:333-340, 547-550`): KK comprueba límites en cada acceso. Probar sin las dos primeras (mantener `nullDescriptor`) con el banco. Riesgo: lecturas fuera de rango.
2. **MSL de KK para `fs 0x1759c590391`**: volcarlo (parche de KK → log/VPS4) y compararlo con SPIRV-Cross del mismo SPIR-V: modo matemático, límites, muestreos de comparación, bucles.
3. **Costes fijos de KK** (~10 ms independientes de píxeles/vértices): `end_encoder` con barrera ALL→ALL, copias por compute en vez de blit, teselación por compute para RectList/QuadList, encoders cortados. Requiere barreras reales en KK.
4. **Térmico**: tope de fps estable (30 a 90 Hz) frente a 33 → 25.
5. **Backend Metal nativo**: ~30–35 mil líneas; ganancia incierta (Dolphin +23–30 % frente a MoltenVK; Ryujinx retiró el suyo).
6. Cambios del juego (menos muestras/resolución de sombras): rechazados hasta ahora en favor de arreglos generales.

### Cómo medir
- Mundo, quieto, L3+R3 → banco por shader (~1 min): `GPU_SHADER_BENCH`. «Prueba de GPU con L3 + R3» = por etapas para el otro.
- Cada 5 s: `frame stats at`, `GPU_TIME[0]`, `[App] Headset:` (Hz y térmico), `GPU_PASSES`, `KK_CENSUS`, `PACE`. Comparar solo en frío. Tabla rápida: script que agrupa fps/draws/Hz/térmico/ms por ventana (regex sobre esas tres líneas).
- Quitar ANSI de los logs: `sed 's/\x1b\[[0-9;]*m//g'`.

## Mapa de funciones (dónde está cada cosa)
### Emulador (shadps4-arm64-main/src)
- Caché de pipelines (`SHADPS4_PIPELINE_CACHE`, app «Guardar y precargar shaders», `shader_cache`=1): `vk_pipeline_serialization.cpp` (`Info::Serialize` con `images`/`samplers` elemento a elemento; `ShaderMetaVersion`/`PipelineKeyVersion` 3; `CacheTag` = formato, `uniform_buffer_max_size`, `sizeof` de InfoPersistent/GraphicsPipelineKey/RuntimeInfo, `exact_pixel_math`, tras el perfil con su relleno a cero; perfil distinto → `DataBase::Clear()`; precarga gráfica como `PendingGraphicsPipeline` `preloaded` en la cola de fondo; compute síncrono). `SerializationSupport::{buffer_is_storage,image_num_bindings}` (gráficos y compute). `cache_storage.cpp`: ficheros sueltos en `VPS4/Partidas/cache/<serial>[-<driver no KK>]`, escritura `.part`+rename, `preloading.mark` (si queda al arrancar → vaciar). `emulator.cpp` fuerza no archivado.
- Pipelines en segundo plano (`SHADPS4_ASYNC_PIPELINES`): `vk_pipeline_cache.cpp` `PipelineWorkers` (cola urgente + de fondo; hilo 0 solo urgentes), `MakeOnWorker`, `WaitForJob` (40 ms por 100 ms), `FinishPendingGraphicsPipeline`, promoción de precargados pedidos por un draw. Logs `PIPELINE_SLOW`, `PIPELINE_PRELOAD`, `PIPELINE_PRELOAD_LATE`.
- Constantes como UBO: `resource.h` `BufferResource::uniform_buffer_max_size` + `IsStorage`; `vk_pipeline_cache.cpp` lo fija con `SHADPS4_CONSTANT_UBO=1`.
- Cálculo exacto en píxeles: `emit_spirv_floating_point.cpp` `ExactPixelMath()`/`Decorate`.
- Bancos de GPU (L3+R3): `gpu_bench.h` + `vk_rasterizer.cpp` (`GpuBench`, `ShaderTest`, `BenchLeavesOut`, `BenchPixelsOut/Back`, `DescribeDrawState`, `GPU_SHADER_STATE`, `GPU_SHADER_SPIRV`); `GpuTimer` en `vk_scheduler.cpp` (`GPU_TIME`, por pasada); `FrameStats` (`SHADPS4_FRAME_STATS=2`, `GPU_PASSES`, lista de pasadas).
- Reloj de GPU del juego: `video_core/amdgpu/game_clock.{h,cpp}` (`SHADPS4_GPU_CLOCK_SCALE`=auto|1|0.5|0.25; `GPU_STAMPS`, `GPU_CLOCK_AUTO`); `liverpool.cpp` re-sincroniza al empezar cada frame; `known_title.cpp` `GpuClockTuner` (lee los ms que mide el juego en el objeto de `resolution_pointer` 0x08/0x10), `DumpResolutionControl` (`QUALITY_DUMP`), `TendResolution`. Todo lo de ASTRO BOT exige serial CUSA12392.
- Pantalla plana en el visor: `driver.cpp` `SubmitScreenToHeadset`, `vk_presenter.cpp` `PrepareScreenAsHmdFrame`.
- Presentación al visor: `vk_presenter.cpp` `PrepareHmdFrame` (sin ventana mientras `IsShowing`), `vk_vr_exporter.cpp` `AcquireLocal`, `core/vr/openxr_host_visionos.mm` (`NumSlots` 6, `BeginFrame` espera ≤100 ms).
- Memoria de 16 KB: `address_space.cpp` `Protect`, `page_manager.cpp` (`HOST_PAGE_SIZE`, `PageState` u16, subpáginas), `vk_rasterizer.cpp` `ReadMemory`, `memory.cpp` Fixed fuera de rango. FEX: `fex_guest_engine.cpp` (SIGBUS de permisos en Darwin, `kHostPageSize`), parche `visionos/patches/fex-darwin.patch`. SRT walkers: `flatten_extended_userdata_pass.cpp` (ARM64 en arena JIT; interpretados sin memoria ejecutable).
- Memoria y diagnóstico: `guest_watchdog.cpp` (`PACE`, `MEMORY`, pilas nativas a los 20 s sin frames), `signals.cpp` (`ASTRO_CRASH`, `ASTRO_FAULT_LOOP`), `buffer.cpp` `AllocationTally`; staging 64 MB, bloques VMA 32 MB, presupuesto ¼ RAM en visionOS.
- KK: `vk_platform.cpp` `LoadKosmicKrisp()` (dlopen de `Frameworks/KosmicKrisp.framework`, `SHADPS4_VK_DRIVER`); parche `visionos/patches/kosmickrisp-visionos.patch` sobre Mesa `b628375` (Metal4, `vm_*`, `VK_EXT_metal_objects`, embebido, GS en la pasada `KK_GS_IN_PASS`, `KK_HEAP_BETWEEN_PASSES`, `KK_LIGHT_BARRIERS`, censo `KK_CENSUS`, memoria `KK_MEMORY`); script `visionos/scripts/build-kosmickrisp.sh`; regenerar el parche con `git diff` en un clon de Mesa.
- Pasadas: `vk_scheduler.cpp` `BeginRendering` (pasadas sin adjuntos al tamaño del scissor; juntar pasadas), `vk_instance.cpp` (`SHADPS4_LIST_RESTART`).
- Audio: PHASE espacial (`spatial_audio_visionos.mm`, `SHADPS4_SPATIAL_AUDIO`), micro propio (`phase_audio_in.cpp`), SDL al ritmo del dispositivo (`sdl_audio_out.cpp` `PaceByDevice`).
- Idioma: `SHADPS4_CONSOLE_LANGUAGE` (`emulator.cpp`).
### App (visionos/App)
- Ajustes: `Core/AstroSettings.swift` (`settings.txt` en Documents; `AstroSettings.write`; `environment` arma las variables), `Views/SettingsView.swift` (todo ajuste tiene interruptor/selector; nada se edita a mano).
- Juego: `Core/AppModel.swift` `findGame` (todas las carpetas con `eboot.bin` en VPS4/Juegos, VPS4, Documents, Documents/games → `games`; orden `game` → `game_folder` → CUSA12392 en VPS4 → …), `chooseGame`; `Views/HomeView.swift` tarjeta Juego con «Cambiar». Carpeta VPS4: `Core/GameFolder.swift` (bookmark).
- Visor: `Render/GameRenderer.swift` (reproyección, log `Headset:`), `Render/EdgeSmoother.swift` + `Render/SMAA/*` (SMAA), `Tracking/HeadsetTracking.swift` (manos), `Tracking/SenseTracking.swift` (mandos Sense).
- Mando: `Controller/PlayStationController.swift` (ejes del acelerómetro corregidos, vibración con `makePlayer` por asa como SDL, `handlesGameControllerEvents`), `Controller/RumbleTest.swift`.
- Logs: `Core/LogFiles.swift` (`consola-*.txt`), `Views/LogsView.swift`.
### CI
- `.github/workflows/visionos-app.yml`: solo `[build]` o dispatch (el filtro `paths` mira el push: un `[build]` que solo toca la bitácora no compila → dispatch); borra borradores de `visionos-latest`, publica y comprueba el enlace; `concurrency` en el job; caché del core y de KK.
- `kosmickrisp-visionos.yml` (dispatch), `stikdebug-visionos.yml` (StikDebug con autoquit), `visionos-vpengine.yml` (`[build-vpengine]`).
- Commits: identidad `Claude` con email vacío.

## Histórico (resuelto; detalle en git)
- 2026-10-07/08: arranque bajo FEX, bucle de fallos de página por páginas de 16 KB (resuelto), SIGBUS de Darwin, KosmicKrisp en visionOS (GS reales, ambos ojos), fusión con upstream AstroQuest 0.20, análisis de los GS de ASTRO BOT.
- 2026-10-08/09: memoria (JIT 512 MB, staging/VMA de móvil, cierre por memoria a 2160), pasada 16384² arreglada, GS en la pasada, FXAA (quitado) → SMAA, MetalFX y resolución dinámica (quitados), carpeta VPS4, comprobación de `sce_sys`, idiomas, audio PHASE 3D y micro, petardeo de audio, vibración (arreglada: `makePlayer` simple; el reproductor avanzado fallaba en visionOS 27), mando por GameController, reloj de GPU del juego (sombras siempre), bancos de GPU por etapas y por shader, censo de KK.
- 2026-10-10/11: constantes como UBO, caché de pipelines en disco con precarga, selector de juego, caché por driver, cálculo no exacto en píxeles.
- VPEngine (2026-10-09): variante sin JIT; 7 pruebas en el visor hasta firma del pack aceptada; eboot sin enganchar. Seguimiento en el repo de VPEngine.

## Pendiente (no rendimiento)
- KITCHEN (CUSA06799) y otros PSVR: ver «Estado».
- PS Move: no implementado (mapear Sense de PS VR2 a dispositivos Move del tracker).
- Posición del mando sin manos: Object Tracking del DualSense (necesita Mac para el modelo); hoy giróscopo + manos.
- BC6H/BC7 con uso Storage en MoltenVK (`image.cpp:247`).
- Aviso de FEX «Failed to mprotect last page of code buffer» (inofensivo).
