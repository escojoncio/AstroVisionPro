# Bitácora — AstroVisionPro

Port de ASTRO BOT Rescue Mission (PSVR, CUSA12392 v1.00) a Apple Vision Pro (visionOS 27), camino hacia un emulador de PSVR general.
Base: shadPS4 ARM64 (`shadps4-arm64-main/`) + FEXCore (x86-64 → ARM64, JIT) + KosmicKrisp (Mesa, Vulkan sobre Metal; MoltenVK como alternativa).
App visionOS en `visionos/` (SwiftUI + Compositor Services + ARKit + GameController). Release `visionos-latest/AstroQuest.ipa` (bundle ID `com.kdt.livecontainer`, SideStore).
JIT: arena RWX preparada por StikDebug (protocolo `brk #0xf00d` + universal.js); la app hace detach al terminar.
Compactada el 2026-10-11: lo resuelto queda en «Histórico» como una línea; el detalle está en el historial de git de este fichero (`git log -p bitacora.md`).

## Estado (2026-10-11, noche) y siguiente sesión
- Build en curso: limpieza de ajustes + «Modo diagnóstico» único + diagnósticos de KITCHEN + volcado de shaders para VPEngine (secciones siguientes). Probar: ASTRO BOT con diagnóstico apagado (no debe empeorar; log limpio) y KITCHEN con diagnóstico encendido + volcado L1+R1+L3 ya dentro de la escena → buscar `READ_UNWRITTEN`, `SMALL_BUFFER`, `DIAG: budgets reset`, PNG `d*_…_notgpu` de profundidad/sombras.
- Build faa8cfa (profundidad en dirección de escritura + alpha-to-coverage): probada, sin cambio visual en KITCHEN (abajo). Build e8e0180 (copias en bruto, 2dVr, barreras): sin cambio visual en KITCHEN. Build 34050d6: KITCHEN ya entra y se ve la escena (log 20:53), pero con aspecto incorrecto (usuario: «como 030_…240x135»), sin los paneles emergentes/subtítulos; 26 fps, ~37,6 ms (antes 32: ahora la escena pasa la prueba de profundidad y se sombrea de verdad; `960x1080 1 colour` 200 → 255 ms/s). `REPROJECTION_LABEL_NEAR` no saltó esta vez. `sceHmdReprojectionStart2dVr` (stub) llamado 119 veces solo en la transición de carga (20:54:15–20), no en juego. `RAW_WRITE` agotó sus 16 logs en el menú (no se ve si tocó la profundidad en VR). Pendiente: volcado de esta sesión (VPS4/Partidas/rt_dump, 67 imágenes). Build e9697ac: KITCHEN colgado al entrar en VR (log 20:38). Build 0b1aaf8 (run 38160653309): probada (log 19:55, volcado OK) — volcado en VPS4/Partidas/rt_dump + `GPU_COMPUTE` (abajo; la de 4293712 se canceló). Build 4148263 (run 38159260534): OK, sin probar — atajo de volcado + color de las imágenes planas de 10 bits + frames de casco leídos tras su dibujo (abajo). Última probada: 50110d0 (logs 19:02 KITCHEN, 19:04 ASTRO BOT).
- **KITCHEN arranca y corre**: la etiqueta de frame lo desbloqueó (`REPROJECTION_LABEL`: el juego pone la etiqueta a un contador, p. ej. 0x555, y la GPU espera ==0; escrito 0). Esperas de arranque en gfx (`0x786d640e20/28/30` ==0) y asc1 (`0x7019f28e38/ec8`, `0x7019f260f8` ==1) que se resuelven solas. 30 fps, GPU 98 %, ~360 draws/imagen, ~33 ms/imagen; ojos 960x1080 A2B10G10R10UnormPack32, tan 1.732/1.0/1.0/1.192. **Problema: imagen casi negra** (se ven siluetas con luces; no se ven subtítulos). Hipótesis: exposición/HDR del juego (compute asíncrono) o color de los ojos de 10 bits UNORM mal tratado en `hmd_pp_pass`/`linear_out`, o subtítulos en una capa que no emulamos.
- **MSAA en ASTRO BOT funciona técnicamente**: color 4 muestras / profundidad 8 (EQAA) → 2 en el host; `Image::Resolve` por `resolveImage` (`4 samples, 2 on the host`); ningún shader lee MS ni FMask; sin `FMask decompression`. Poco visible por 2x + ampliación ~2,5× al visor; el MSAA no trata aliasing de shader/texturas. Coste 2x: ~+7–10 ms/imagen.
- Siguiente: con la build en curso, en KITCHEN L1+R1+L3 → `VPS4/Partidas/rt_dump/*.png` (+ lista `cache image at …` y traza de 3000 draws en el log) → ver si los ojos ya salen oscuros del juego (exposición) o se oscurecen en nuestra composición (formato 10 bits).
- Herramientas aquí: comprobación de sintaxis con `clang++ -std=c++23 -fsyntax-only`, submódulos (`git submodule update --init --depth 1`, de uno en uno si falla): fmt spdlog vulkan-headers robin-map magic_enum ext-boost sirit (+ `externals/sirit/externals/SPIRV-Headers`) toml11 xbyak zydis vma miniz half json xxhash tracy dear_imgui sdl3; `-DSPDLOG_FMT_EXTERNAL`, `-DVK_NO_PROTOTYPES -DVULKAN_HPP_NO_CONSTRUCTORS -DVULKAN_HPP_NO_STRUCT_SETTERS -DVULKAN_HPP_HAS_SPACESHIP_OPERATOR -DVULKAN_HPP_DISPATCH_LOADER_DYNAMIC=1 -DVULKAN_HPP_NO_EXCEPTIONS`, `-DSHADPS4_VISIONOS -DENABLE_OPENXR_HOST`, un `miniz_export.h` vacío. `vk_presenter.cpp` da 2 errores ajenos de ImGui (ImVec2) sin el imconfig del proyecto. spirv-cross: compilar KhronosGroup/SPIRV-Cross con cmake. Fuente de KK: `git fetch --depth 1 --filter=blob:none https://github.com/shadexternals/mesa.git b628375fb1fd99476bfbaaa0532deb6fe3a6870e` con sparse `src/kosmickrisp/`.
- Comprobar que el visor tiene la build nueva antes de leer un log: línea de `vr_tracker.cpp:NNN` / `Multisampling limited to N` / ajustes nuevos en la app (SideStore a veces deja la anterior).

## Interfaz de rasterizador (hito 1 del cliente VPEngine, sin cambio de comportamiento)
- `src/video_core/rasterizer_interface.h`: `VideoCore::RasterizerInterface` (virtual puro) con lo que usan Liverpool,
  `Core::MemoryManager` y `VideoCore::PageManager`: Draw/DrawIndirect, DispatchDirect/Indirect, marcadores, Fill/CopyBuffer,
  ReadDataFromGds, Invalidate/ReadMemory, IsMapped, Map/UnmapMemory, CpSync, Flush, Finish, OnSubmit.
- `vk_rasterizer.h`: `Vulkan::Rasterizer final : public VideoCore::RasterizerInterface` (los métodos con `override`).
- `liverpool.h` (`BindRasterizer`, miembro), `core/memory.h` (`SetRasterizer`, miembro), `page_manager.{h,cpp}`: usan la
  interfaz. Diseño del renderer VPEngine: VPEngine `docs/ADAPTER.md`.

## Comprobación de shaders de VPEngine en el visor (Modo diagnóstico)
- `visionos-app.yml`: paso «VPEngine shader translator» clona escojoncio/VPEngine en `vpengine/` al commit de
  `visionos/vpengine-gpu.ref` (actualizarlo para coger traductor nuevo); `core-inputs.txt` incluye `gpu/shader` de VPEngine
  (clave de caché del núcleo); `VPENGINE_GPU_DIR=$PWD/vpengine/gpu bash build-core.sh` → `-DVPENGINE_GPU_DIR`.
- `CMakeLists.txt` (bloque `SHADPS4_VISIONOS`): con `VPENGINE_GPU_DIR`, compila `gpu/shader/{ir,msl}/src/*.cpp`,
  `gcn/src/{gcn,lift}.cpp` + `src/platform/visionos/vpengine_shader_check.{h,mm}` (ARC) dentro de `shadps4`;
  define `SHADPS4_VPENGINE_SHADER_CHECK=1`.
- `vk_pipeline_cache.cpp` `CompileModule`, tras `TranslateProgram`: `VpengineShaderCheck::Check(code, info, runtime_info,
  perm_idx)` si `SHADPS4_VPENGINE_SHADER_CHECK=1` (la app lo pone con «Modo diagnóstico», `AstroSettings.swift`).
- `vpengine_shader_check.mm`: `LiftInput` con el estado real (user SGPRs = `num_user_data`, PS `addr_flags`, formatos
  de exportación por MRT, CS tamaño de grupo/tgid/LDS, VS `num_input_vgprs` y el fetch de `ParseFetchShader`) →
  `vpgcn::lift` → `vpmsl::emitMsl` → `newLibraryWithSource` asíncrono (Metal 3.1, fast math). Log: `VPENGINE_SHADER
  <st>_<hash>_<perm> OK: lift X ms, N bytes, Metal Y ms` o `lift:/verifier:/Metal:` + primera línea; resumen
  `VPENGINE_SHADERS: ...` cada 10. Fallos → `<ShaderDir>/vpengine/<nombre>.metal(.txt)` / `.lift.txt`
  (ShaderDir = `VPS4/VPEngine/shaders` en modo diagnóstico). No cambia el render.
- Descriptores reales (`describe` del `LiftInput`): el check lee los dwords del T#/V# donde el lifter los trazó
  (user data del draw, punteros vía `vm_read_overwrite`, que falla en vez de fallar la página con direcciones viejas de
  pipelines precargados; tablas tras el código desde `pgm_base`) → dimensión (1D/2D/3D/cubo/arrays, cubo array si
  `last_array > 5`), tipo de texel (Uint/Sint/float) y dfmt/nfmt de buffers tipados. Antes todo era 2D float.
- Censo de draws (mismo modo): estado por `pgm_hash` (pendiente/OK/fallo pegajoso/etapa no soportada, primer error);
  `vk_rasterizer.cpp` `NoteVpengineDraw` (Draw y DrawIndirect, tras tener pipeline: hashes de `GetStages()`) y
  `NoteDispatch` (DispatchDirect antes del HLE, DispatchIndirect); `vk_presenter.cpp` `Present` → `EndFrame`. Cada 10 s:
  `VPENGINE_DRAWS: N frames, per frame D draws (X% with every shader running in VPEngine, Y% waiting …)` + hasta 8
  líneas `VPENGINE_DRAWS   blocked by <st>_<hash>: n per frame (motivo)`. Traductor: VPEngine 7c00184 (semántica
  exacta validada con test diferencial, también con control de flujo; LDS de píxel como memoria por carril: 174/174 del
  corpus; stores tipados y formatos empaquetados; `image_get_lod`).

## Volcado de shaders para VPEngine (va en la misma build que la limpieza)
- `emulator.cpp` (`#ifdef SHADPS4_VISIONOS`, tras `SHADPS4_PIPELINE_CACHE`): `SHADPS4_DUMP_SHADERS=<carpeta>` → crea la carpeta,
  `SetUserPath(ShaderDir, carpeta)` + `SetDumpShaders(true)`; log `GPU dumpShaders: true`. shadPS4 escribe en `<carpeta>/dumps`
  `<etapa>_<hash>.bin` (código GCN, en `CompileModule`), `vs_<hash>.fetch.bin`, `.spv` y `irprogram.txt`.
- App (`AstroSettings.swift`): con «Modo diagnóstico» → `SHADPS4_DUMP_SHADERS=VPS4/VPEngine/shaders`; texto del ajuste
  actualizado (`SettingsView.swift`). Para VPEngine solo valen `.bin` y `.fetch.bin` (corpus del lifter GCN → VPIR).

## Build en curso — limpieza de ajustes, «Modo diagnóstico», diagnósticos de KITCHEN
- App (`Core/AstroSettings.swift`, `Views/SettingsView.swift`): quitados los ajustes `vulkan_driver`, `async_shaders`, `shader_cache`, `gs_in_pass`, `heap_between_passes`, `merge_passes`, `light_barriers`, `device_barriers`, `list_restart`, `constant_ubo`, `exact_pixel_math`, `raw_image_sync`, `antialias`, `real_time`, `close_launcher`, `controller_to_app`, `gpu_clock_scale`, `gpu_test`, `pass_diagnostics`, `msaa` (claves viejas en settings.txt: ignoradas en `apply`). `environment` pasa fijos: `SHADPS4_VK_DRIVER=kosmickrisp`, `ASYNC_PIPELINES=1`, `PIPELINE_CACHE=1` (sin env el emulador la deja apagada), `KK_GS_IN_PASS=1`, `KK_HEAP_BETWEEN_PASSES=1`, `KK_LIGHT_BARRIERS=0`, `MERGE_PASSES=1`, `LIST_RESTART=0`, `CONSTANT_UBO=1` (sin env: apagado), `EXACT_PIXEL_MATH=0`, `RAW_IMAGE_SYNC=1`, `RESOLVE_AA=0`, `GPU_CLOCK_SCALE=auto` (el factor solo lo mueve el `GpuClockTuner` de CUSA12392). `closeLauncher`/`controllerToApp` = `let true`. Borrado `Controller/RumbleTest.swift` y `PlayStationController.testRumble`. Nuevo ajuste `diagnostics` («Modo diagnóstico», sección Diagnóstico, por defecto no) → `SHADPS4_DIAGNOSTICS=1`, `SHADPS4_FRAME_STATS=2`, `SHADPS4_GPU_BENCH=shaders`, `GPU_STAMP_LOG`, `QUALITY_DUMP`, `KK_CENSUS`. Sin texto que mande a editar settings.txt. Código de KK sin tocar (decisión: no más cambios en KK). Trazas `BACHATA_*` de la plataforma base: no tocadas (comparte la build de Quest; inertes en visionOS).
- Emulador: `src/common/diagnostics.h` (`Common::Diagnostics()`, `DiagEpoch()`, `BumpDiagEpoch(why)`, `DiagBudget{n}` con `Take()` y `Take(key)`, ≤64 claves, se vacía al cambiar la época). Época nueva en el primer `sceHmdReprojectionStart` tras ≥1 s sin él y en el primer `Start2dVr` de una racha (`DIAG: budgets reset`). Pasan a diagnóstico y a presupuestos por época/dirección: `RAW_WRITE`/`RAW_READ`/`RAW_IMAGE_SYNC`, `DEPTH_COPY_DRAW`/`DEPTH_MIRROR` (2 por dirección), `MSAA:`, `REPROJECTION_LABEL(_NEAR)`, volcados de args de 2dVr, `HMD frame … eye`, `init:` de VrTracker. Solo con diagnóstico: `GpuBench::Start` (L3+R3), atajo L1+R1+L3 (`astro_core.mm`) y la comprobación de `dump_render_targets` (`vk_presenter.cpp`).
- `READ_UNWRITTEN` (`vk_rasterizer.cpp` `BindTextures`, antes de `FindTexture`): imagen leída que es profundidad / tile de profundidad / usada como destino y nunca GpuModified → etapa, hash, binding, dirección, formato, tamaño, capas, flags (una vez por shader+dirección).
- Volcado: `Presenter::DumpDepthImages` (≤48 imágenes de profundidad, capas 0 y 1, `copyImageToBuffer` del aspecto depth con el formato del host `image_ci.format`, gris min..max) → `dNNN_<addr>_WxHxL_<fmt>_layerN_gpu|notgpu[_flat].png`; los de color acaban en `_gpu`. `SMALL_BUFFER`: durante la traza del volcado, escrituras de compute ≤256 B (máx. 16) leídas de la GPU en el siguiente `PrepareHmdFrame` (copia a búfer Download + `Finish`) → floats y hex.
- Revisión adversarial (Sonnet): Swift sin errores encontrados; C++: corregido el tamaño de texel por formato del host (D16S8 sustituido) y la alineación a 4 del offset por capa.

## Resultado build faa8cfa (log 22:45) y siguiente paso
- KITCHEN sin cambio visual (solo albedo, sin luz/sombras, todo iluminado plano). 27 fps.
- Hipótesis de profundidad **descartada**: `DEPTH_COPY_DRAW` muestra que el juego usa la copia clásica (color desactivado + force z dirty/valid, `→ copied`, p. ej. 0x714bcf0000→0x714b3f0000 en el menú); `DEPTH_MIRROR` nunca saltó (ningún draw normal con lectura≠escritura). Aun así, `DepthStencilCopy` ahora marca la destino GpuModified (antes 0x40: podía re-subirse de memoria).
- `Start2dVr` funciona: 21 llamadas al entrar en VR; arg0 = struct {+0x00 Gnm::Texture* (1920x1080 A2B10G10R10, tile 14, en 0x7152578000 / 0x71503f0000), +0x08 ptr, +0x10 floats 1.0/1.0, +0x20 frame label (0x7039f25ba0/bd0, las mismas de Start, valen 1), +0x28 0x1388}; args 1-5: contador, 0, 0x522, 0x28000, 0xe00000. Es el aviso «visor y mando no detectados» del propio juego (sceHmdSetupDialog Open + 2991 UpdateStatus/Terminate; `sceVrTrackerGetPlayAreaWarningInfo` stub 1682 veces; `sceCameraSetVideoSync`). Se ve pequeño y muy comprimido. Pendiente: tamaño/escala de la pantalla 2D; registrar la etiqueta de +0x20 (son las de Start: seguro).
- Subtítulos: no van por 2dVr (solo se llama al arrancar).
- Sospechoso principal de la luz plana: sombras. Mapa `0x715a1f0000` (1024², D32, 32 capas): `RAW_WRITE` restaura capas 0 y 1 desde la copia en memoria (`UploadRawLayers`, 16 veces), pero no consta que esa copia (`0x71421f0000`) se haya llenado con lo dibujado: los logs `RAW_READ` (tope 16) se agotaron en el menú con la imagen 1920x1080 `0x714abf8000`. Mismo problema de topes en `RAW_WRITE` y `DEPTH_COPY_DRAW`.
- Siguiente: (1) topes de log por dirección o reiniciados al entrar en VR; (2) volcado de los valores de los búferes pequeños escritos por dispatches 1x1x1 (exposición) y de una capa del mapa de sombras; (3) limpieza de ajustes/diagnósticos acordada (ver lista en la respuesta del 2026-10-11: fijos, borrados, «Modo diagnóstico» único, perfil por juego).

## Build faa8cfa — profundidad en la dirección de escritura (luz de KITCHEN) y alpha-to-coverage
- Build e8e0180 probada (log 22:16, foto): sin cambio visual: solo color base (albedo), sin luz ni sombras; pelo/cuchillos como tarjetas opacas. `RAW_READ`/`RAW_WRITE` activos (menú 1920x1080). 27 fps, ~36 ms.
- Traza p.txt: la pasada de luz `ps 0x277022eb7c2` (fullscreen sobre `cb0 0x712a400000`, la escena con albedo) lee t0 = profundidad **`0x712ac80000`**, que ningún draw ni compute escribe (flags 0x40: nunca GpuModified) → profundidad vacía → «cielo» → sin luz. Hipótesis: los draws de escena tienen `DB_Z_READ_BASE` (0x712b100000, donde dibujamos) ≠ `DB_Z_WRITE_BASE` (0x712ac80000, donde la consola la escribe). shadPS4 dibuja siempre en la de lectura (`ImageDesc(..., write_buffer=false)`); solo copiaba con color desactivado + force_z_dirty/valid (`DepthStencilCopy`).
- `vk_rasterizer.{h,cpp}`: `FilterDraw` registra `DEPTH_COPY_DRAW:` (12 primeras, lectura/escritura, modo de color, force z, «copied/NOT copied»); si lectura≠escritura con escritura de z → `depth_mirrors` (write_address, descs de lectura/escritura, capas; máx. 8; se borra si un draw usa esa superficie como depth). `RunDepthMirrors(pipeline)` antes de `PrepareRenderState` (draws) y de `BindResources` (dispatches): para cada textura de los shaders, `MirrorPendingDepth(addr)` → `CopyDepthBetween` (copyImage de profundidad, mismo formato/muestras/capas; marca GpuModified y quita Dirty; log `DEPTH_MIRROR:` 8 veces). `DepthStencilCopy` usa `CopyDepthBetween` y marca la destino GpuModified. `SHADPS4_DEPTH_MIRROR=0` lo apaga.
- Alpha-to-coverage: `GraphicsPipelineKey::alpha_to_coverage` (bit en el struct de `depth_clip_enable`, sin cambiar sizeof) = `reg_array[0xA2DC] & 1` (DB_ALPHA_TO_MASK) en `vk_pipeline_cache.cpp`; `vk_graphics_pipeline.cpp` `alphaToCoverageEnable` si además `mrt_mask & 1` (las dos rutas de multisampling, también la de precarga).

## Build e8e0180 — copias en bruto coherentes (sombras/TAA), 2D en VR, barreras
- Volcado 20:53 (KITCHEN visible pero «sin shaders»: plano, sobreexpuesto). Traza: el mapa de sombras `0x713a1f0000` (1024², D32, 32 capas) lo gestiona el juego por capas con copias de compute en bruto: restauración por ojo `2048x1x1` R `0x71421f0000`/4 MB → W capa 0 (y capa 1), «clear» en bruto de capa y copia de seguridad capa 0 → `0x71421f0000`. Fallaban ambos sentidos: escrituras de una capa (no imagen entera) no llegaban a la imagen; lecturas en bruto leían memoria vieja (el buffer cache solo sincroniza imagen→memoria para texel buffers). Igual en `2176x1x1` normales `0x712b9c0000`→`0x7125400000` (decals) e historia TAA `0x712a840000`→`0x7161ea8000`. Inferido: luces sin sombras → aspecto plano. Exposición: sin pruebas de readback (no tocado).
- `texture_cache.{h,cpp}`: `InvalidateWholeImagesFromGPU` reconoce capas enteras de arrays de 1 nivel thin (`raw_layer_writes`, `UploadRawLayers` sube solo esas capas; `LayerRangeInfo` ajusta `bank_swizzle` por slice); `FindImageForRawRead` + `raw_touched_images` + `raw_synced` (capas ya volcadas, se borra al dibujar/escribir); `raw_marked_in_bind` (no refrescar en el mismo bind que la marcó; `ClearRawBindMarks`); limpieza en `UnregisterImage`. Logs `RAW_WRITE … layers`, `RAW_IMAGE_SYNC`, `RAW_READ`.
- `buffer_cache.{h,cpp}` `SynchronizeRawReadFromImage`: `TileImage` de imagen/capas al buffer antes de una lectura en bruto ≥64 KB. `tile_manager.{h,cpp}`: `TileImage` con `ImageInfo`. `vk_rasterizer.cpp`: `BindBuffers` llama a la sincronización; `BindResources` limpia marcas (SCOPE_EXIT); traza `TRACE   targets:` (blend cb0/cb1, cb1-3, `db_slice`). App: «Copias de imágenes por compute coherentes (sombras, TAA)» (`raw_image_sync`, por defecto sí → `SHADPS4_RAW_IMAGE_SYNC`).
- `sceHmdReprojectionStart2dVr` (`hmd_reprojection.cpp`): 6 args u64; log de args + volcado hex (3 primeras); `GuestReadable` (QueryProtection, CpuRead, rango); busca descriptor Gnm plausible en los 6 args (dirección y punteros dentro): Color2D, 64–4096, pitch≥ancho, parejas dfmt/nfmt y tile modes en lista blanca, tamaño dentro del área mapeada. Etiqueta de frame: solo se registran candidatos en el log (no se usa). Envía `HmdFrame{is_screen=true}` → `driver.cpp` `SubmitScreenFrameInternal` (pantalla 70° fija, comparte `screen_pose`; sin casco/host o sin pose → `FinishFlip`) → `vk_presenter` `PrepareTextureAsScreenHmdFrame` (vista con el swizzle del descriptor; `ComposeScreenAsHmdFrame` común con `PrepareScreenAsHmdFrame`). Swizzle de los ojos: ya se respetaba (`ImageViewInfo` usa `DstSelect`); el R/B cambiado del volcado es del blit en crudo. Log `HMD frame … eye` con dfmt/nfmt/dst_sel/vista.
- Rendimiento: los ~0,11 ms por corte de KITCHEN son dependencias reales (pirámide de bloom ping-pong). `image.cpp` `Transit`: destino solo adjunto de color → `ColorAttachmentOutput`; solo profundidad → `Early|LateFragmentTests` (antes `AllGraphics|Compute`: hacía que `KK_LIGHT_BARRIERS` esperase siempre antes de vértices). KK (parche): `KK_BARRIER_VISIBILITY=device` → `end_encoder` con `MTL4VisibilityOptionDevice` en vez de `ResourceAlias` (`mtl_barrier_after_stages_device_visible`); app «Barreras ligeras entre pasadas (experimental)» (`device_barriers`, por defecto no). Decisión: no más cambios en KosmicKrisp (el traductor gráfico propio de VPEngine lo sustituirá). Ideas para VPEngine, no para KK: compresión sin pérdidas (imágenes sin ShaderWrite/PixelFormatView cuando no hagan falta), barreras por dependencia real en vez de ALL→ALL por encoder, espera de vértices solo si el VS lee imágenes, foveado.

## Build 34050d6 — espera de la GPU en una etiqueta de frame vecina aún no entregada
- Log 20:38 (build e9697ac): KITCHEN se queda colgado al entrar en VR (sin imagen ni sonido). `sceHmdReprojectionStart` frame 0 registra la etiqueta `0x7019f25ba0` (se libera); la GPU espera `==0` en **`0x7019f25bd0`** (la del frame 1, 0x30 más allá, vale 1) **antes** de que el juego haya llamado a ReprojectionStart del frame 1 → `SatisfyReprojectionLabelWait` no la conoce → gfx bloqueada para siempre (836 M vueltas) y el juego espera a esa GPU. En logs anteriores el frame 1 se registraba antes (carrera; el cambio de tiempos de `RAW_WRITE` la destapó).
- `hmd_reprojection.cpp` `SatisfyReprojectionLabelWait(address, function, ref, mask, new_wait)`: dirección no registrada pero a <0x80 de una etiqueta conocida, comparación `==`, alineada → tabla de 4 esperas por dirección (gfx y ASC); `new_wait` (llamada previa al bucle) reinicia su reloj; a los 100 ms de la misma espera se escribe el valor pedido (log `REPROJECTION_LABEL_NEAR`, 8 veces). `hmd.h` firma con `new_wait = false`; `liverpool.cpp` pasa `true` en las dos llamadas previas al bucle (gfx y ASC).
- `RAW_WRITE` en el menú: 3 imágenes 1920x1080 B10G11R11 (0x7f8000) reescritas en bruto por compute (clears) → re-subida cada vez; menú a ~36 ms/imagen. Vigilar coste.

## Build e9697ac — imágenes reescritas en bruto por un shader (KITCHEN negro, sin subtítulos)
- Volcado de KITCHEN (log 19:55): G-buffer bien (normales `0x712b580000` RGBA8, material `0x712b9c0000`), escena HDR `0x712a400000` casi negra, ojos negros con manchas blancas. Por ojo (cada ojo es una pasada completa del juego): compute de luces/tiles → **`2304x1x1` escribe en bruto (sin formato) toda la memoria de la profundidad `0x712b100000` (D32 960x1080, 0x480000)**, y `48x1x1` su HTILE (con xor: no es un clear para `IsComputeMetaClear`) → escena con z GreaterEqual y escritura → UI/subtítulos con z GreaterEqual sin escritura → tono → copia al ojo. `BindBuffers` solo invalidaba imágenes con escrituras formateadas → la profundidad seguía con la del ojo anterior → casi todo descartado.
- `texture_cache.{h,cpp}` `InvalidateWholeImagesFromGPU(address, size)`: marca `GpuDirty` (re-subida desde el buffer cache en el próximo `UpdateImage`) las imágenes con `guest_address == address`, `guest_size <= size <= guest_size + 64 KB`, sin MSAA, no ya `GpuDirty`; log `RAW_WRITE:` (16 primeras). `vk_rasterizer.cpp` `BindBuffers`: escrita y no formateada → esto (formateada → `InvalidateMemoryFromGPU` como antes).
- `GPU_COMPUTE` (log 19:55): ~476 ms/s entre pasadas, de ellos **~385 ms/s sin dispatch** (≈3400 huecos/s, ~0,11 ms cada uno: cierre/apertura de encoder de KK con barrera) y `cs 0x878fd9bc` (2176x1x1, copias de imagen por compute del juego, ~40/frame) ~47 ms/s. Lo caro de KITCHEN son los ~115 cambios de pasada por frame. Siguiente para rendimiento: probar `KK_LIGHT_BARRIERS` en KITCHEN y reducir cortes de pasada (`image.cpp:568` `Transit` termina la pasada en casi todas).

## Build 0b1aaf8 — volcado de imágenes en VPS4/Partidas/rt_dump
- Log 19:33 (build 4148263): KITCHEN sigue casi negro tras leer los frames de casco después de su dibujo (no era eso, o no solo). El volcado L1+R1+L3 funcionó (63 imágenes) pero en `UserDir` = contenedor de la app (`Library/Application Support/shadPS4/rt_dump`), invisible en Archivos. Ahora `vk_presenter.cpp` `DumpGpuImages` (visionOS) y el log de `astro_core.mm` usan `PathType::HomeDir` (= `SHADPS4_HOME_DIR`, VPS4/Partidas). La marca `dump_render_targets` sigue en `UserDir`.
- Cadena del frame de KITCHEN (traza tras el volcado): escena HDR en `0x714a400000` 960x1080 B10G11R11 (z GreaterEqual, profundidad `0x714b100000`) → bloom (cadena 240x270…3x4 y vuelta) → dispatches de reducción `32x16 → 1x1` + `1x1x1` (luminancia media / exposición; búfer `0x703e8a2890` 0x14 → `0x716e7e53d0`) → tono con LUT 3D (`ps 0x8326b984e6`, LUTs 32³ en `0x71780b8000`/`0x7178078000`) en `0x714a840000`/`0x714a400000` → capa con BC7 sRGB 1920x1080 (`0x71725ff800`, z GreaterEqual con `0x714ac80000`) → **un único draw por ojo** (`ps 0x5011e6157d0`, lee `0x714a400000`) a los ojos A2B10G10R10 (`0x7152138000`/`0x7152930000` y `0x7150be8000`/`0x71503f0000`, este último = búfer 2 de VideoOut, 1920x1080, separados 0x7F8000 = 1920x1088x4).
- Hipótesis de lo negro (a confirmar con los PNG): exposición automática mal calculada (reducción por compute o lectura de la CPU de un resultado de la GPU con `readbacks_mode` Disabled) o tono/LUT. Si la escena HDR se ve bien y la de después del tono no → exposición/LUT.
- Rendimiento igual que antes (30 fps, GPU 98 %, ~32 ms; térmico nominal).

## Build 0b1aaf8 — tiempo de GPU entre pasadas por shader de compute (`GPU_COMPUTE`)
- KITCHEN debería ir a 60 (consola). Log 19:02: 30 fps, GPU 98 %, ~33 ms/imagen; por frame ~123 pasadas (todas cargan sus destinos, ~46 Mpx), ~370 draws, **~121 dispatches**, 2 submits. `GPU_PASSES`: **~490 ms/s fuera de pasadas (~16 ms/frame, la mitad)** frente a ~5 ms en ASTRO BOT; `960x1080 1 colour` ~200 ms/s (26 pasadas de 1 draw/frame: cadenas de post y desenfoque por ojo), escena `960x1080 3 colours +depth` ~115, `512x512` ~72. `KK_CENSUS`: 240 encoders de compute/s por `kk_cmd_dispatch.c:83`, 120 por `kk_dispatch_precomp` (`kk_cmd_buffer.c:1007`), 120 por `copy_image` (`kk_cmd_copy.c:300`).
- `vk_scheduler.{h,cpp}`: `Scheduler::NoteDispatch(cs_hash, x, y, z)` → `GpuTimer::Dispatch` guarda en el bloque (`Block::work`, `before_pass` = nº de pasada siguiente; tope 4096; `overflow` si se pasan las `MaxPasses`). En `Collect`, `AttributeGaps`: el hueco antes de la pasada s (desde el fin de la s−1, o el inicio del command buffer, hasta el inicio de la s; el último hasta el fin del buffer, salvo `overflow`) se reparte a partes iguales entre sus dispatches; sin dispatches → «no dispatch (copies, barriers…)». Sin timestamps nuevos (usa los de pasada y buffer). Log cada 5 s: `GPU_COMPUTE[0]: X ms/s between passes, N kinds; the heaviest: cs 0x… ms/s (% alone), dispatches/s, groups AxBxC`.
- `vk_rasterizer.cpp`: `DispatchDirect`/`DispatchIndirect` llaman a `NoteDispatch` (indirecto con 0x0x0; se guarda el último tamaño no nulo).
- Siguiente: con el log, el shader de compute que más pesa → `GPU_SHADER_SPIRV`/decompilar y ver si es trabajo del juego (luces/exposición asíncronas) o nuestro (copias, detilado, precomp de KK).

## Build 4148263 — frames de casco leídos después de su dibujo (general)
- Causa probable de lo oscuro y sin subtítulos en KITCHEN: `SubmitHmdFrame` usaba `Liverpool::SendCommand`, y los comandos corren antes de cualquier envío en cola (incluso a mitad de uno, `ProcessCommands` dentro de las tareas) → los ojos se leían antes de que el DCB del frame (enviado justo antes de `sceHmdReprojectionStart`) los pintara del todo (sin tono final ni UI). ASTRO BOT espera su GPU antes de entregar.
- `amdgpu/liverpool.{h,cpp}`: `SendCommandAfterGfx(func)`: si `gfx_done >= gfx_submitted`, comando normal; si no, a `after_gfx` (objetivo = `gfx_submitted`, hora). `SubmitGfx` cuenta `gfx_submitted` antes de encolar la tarea; al terminar una tarea de la cola GFX `++gfx_done`; `ReleaseAfterGfxLocked()` (tras cada tarea terminada, y tras cada `resume` si `has_after_gfx`) pasa a `command_queue` las que alcanzaron su objetivo o llevan >50 ms (aviso una vez: un envío podría esperar lo que hace el comando → como antes, sin congelar).
- `videoout/driver.cpp` `SubmitHmdFrame`: `SendCommandAfterGfx` en vez de `SendCommand`.
- Revisión adversarial (Sonnet): añadidos el límite de 50 ms y el orden del contador; aceptado: flips normales pueden adelantar a un frame de casco diferido.

## Build 4148263 — imágenes planas de 10 bits «sRGB»
- Usuario: los menús planos de KITCHEN se ven muy brillantes («como HDR»). Sus búferes de VideoOut son `A2R10G10B10Srgb`; `GetFrameViewFormat` los ve como `eA2R10G10B10UnormPack32` (Vulkan no tiene sRGB de 10 bits) → valores ya codificados leídos como lineales → `post_process.frag` los codificaba otra vez (doble gamma).
- `host_passes/pp_pass.h` `Settings::input_encoded`; `host_shaders/post_process.frag` `decoded()` al leer (en `main` y `shown`); `vk_presenter.cpp` `PrepareScreenAsHmdFrame` lo activa para `A2R10G10B10Srgb`. La ventana (`PrepareFrame`) y los ojos (`PrepareHmdFrame`) sin cambios.
- Pendiente de ver con el volcado: si los ojos de KITCHEN (`A2B10G10R10UnormPack32`) también llevan valores codificados (entonces lo oscuro no sería esto, pero sí saldrían lavados).

## Build 4148263 — atajo de volcado
- `platform/visionos/astro_core.mm` `astro_core_pad_state`: L1+R1 sujetos + L3 (sin R3) crea `<UserDir>/dump_render_targets` y escribe `DUMP: …` en el log; `vk_presenter.cpp` `PrepareHmdFrame` lo mira cada 120 frames de casco → `DumpGpuImages()` (PNG de cada imagen de color modificada por la GPU ≥64 px, ancho máx. `SHADPS4_DUMP_WIDTH`=640, en `<UserDir>/rt_dump`, convertidas a RGBA8 Unorm sin decodificar) + `Rasterizer::StartDrawTrace(3000)`.

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
- Ajustes: `Core/AstroSettings.swift` (`settings.txt` en Documents; `AstroSettings.write`; `environment` arma las variables), `Views/SettingsView.swift` (solo ajustes del jugador + «Modo diagnóstico»; lo medido va fijo en `environment`; nada se edita a mano). Diagnóstico del emulador: `src/common/diagnostics.h`.
- Juego: `Core/AppModel.swift` `findGame` (todas las carpetas con `eboot.bin` en VPS4/Juegos, VPS4, Documents, Documents/games → `games`; orden `game` → `game_folder` → CUSA12392 en VPS4 → …), `chooseGame`; `Views/HomeView.swift` tarjeta Juego con «Cambiar». Carpeta VPS4: `Core/GameFolder.swift` (bookmark).
- Visor: `Render/GameRenderer.swift` (reproyección, log `Headset:`), `Render/EdgeSmoother.swift` + `Render/SMAA/*` (SMAA), `Tracking/HeadsetTracking.swift` (manos), `Tracking/SenseTracking.swift` (mandos Sense).
- Mando: `Controller/PlayStationController.swift` (ejes del acelerómetro corregidos, vibración con `makePlayer` por asa como SDL, `handlesGameControllerEvents`).
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
