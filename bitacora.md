# Bitácora — AstroVisionPro

Port de ASTRO BOT Rescue Mission (PSVR, CUSA12392 v1.00) a Apple Vision Pro (visionOS 27).
Base: shadPS4 ARM64 (`shadps4-arm64-main/`) + FEXCore (x86-64 → ARM64) + MoltenVK.
App visionOS en `visionos/` (SwiftUI + Compositor Services + ARKit + GameController).
JIT: arena RWX preparada por StikDebug (protocolo `brk #0xf00d` + universal.js); la app hace detach al terminar.

## Estado tras la última build probada en el dispositivo (commit 749ad2e)

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

### KosmicKrisp en visionOS (commit siguiente a e838b6e)
- Motivo: KosmicKrisp (Mesa; el driver Vulkan-sobre-Metal de shadPS4 en macOS) declara `geometryShader`, `tessellationShader`, `multiViewport`, `shaderOutputLayer/ViewportIndex` (`src/kosmickrisp/vulkan/kk_physical_device.c`); emula GS por compute (`libkk/kk_geometry.cl`, `src/poly`). MoltenVK no tiene GS → con KK desaparece el bypass (`GS_BYPASS` ya no debería salir).
- `visionos/patches/kosmickrisp-visionos.patch` sobre `shadexternals/mesa` `b628375` (el commit que fija `mesa-kosmickrisp`):
  - `bridge/mtl_device.m`: fuera de macOS, `MTLCreateSystemDefaultDevice()` (exige `MTLGPUFamilyMetal4`).
  - `vulkan/kk_bo.c`: fuera de macOS, `mach_vm_*` → `vm_*` (sin `mach_vm.h`).
  - `vulkan/kk_image.c` + `kk_physical_device.c`: `VK_EXT_metal_objects` mínimo (`kk_ExportMetalObjectsEXT`: `mtlDevice`, `mtlTexture` de imagen o vista). Lo usa `openxr_host_visionos.mm` para entregar fotogramas al visor.
  - `meson.options` + `vulkan/meson.build`: opción `kosmickrisp-embedded` (enlaza Metal/Foundation/QuartzCore/IOSurface en vez de `-undefined dynamic_lookup`; install name `@rpath/KosmicKrisp.framework/KosmicKrisp`).
  - Regenerar: aplicar en un clon de Mesa, editar, `git diff > visionos/patches/kosmickrisp-visionos.patch`.
- `visionos/scripts/build-kosmickrisp.sh`: herramientas nativas (`mesa_clc`, `vtn_bindgen2`, `kk_clc`; brew llvm/spirv-llvm-translator/libclc) → cross a `arm64-apple-xros26.0` (crossfile generado) → `build/visionos/kosmickrisp/KosmicKrisp.framework` (Info.plist binario, id `org.mesa3d.kosmickrisp`). STAMP = commit + sha del patch + deployment target.
- CI (`visionos-app.yml`): caché `kosmickrisp-visionos-<hash patch+script>`; paso con `continue-on-error` (si falla, la app sale con MoltenVK); el framework se copia a `AstroQuest.app/Frameworks/` antes del zip; log `kosmickrisp.log` publicado en `ci-logs`. La clave de caché del core excluye el patch y el script de KK.
- `vk_platform.cpp` `LoadKosmicKrisp()` (visionOS): `dlopen(<dir del ejecutable>/Frameworks/KosmicKrisp.framework/KosmicKrisp)`, `vk_icdNegotiateLoaderICDInterfaceVersion(7)`, `vk_icdGetInstanceProcAddr` como entrada del dispatcher; si falta o `SHADPS4_VK_DRIVER=moltenvk`, MoltenVK enlazado. Log: `Vulkan driver: KosmicKrisp|MoltenVK`.
- App: ajuste `vulkan_driver=kosmickrisp|moltenvk` en `settings.txt` → `SHADPS4_VK_DRIVER`.
- Sin probar aún: compilación de Mesa para xros, carga del framework firmado por SideStore, creación de instancia sin loader.

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
- `.github/workflows/visionos-app.yml`: compila solo con `[build]` o dispatch; timeout 150 min; publica `visionos-latest` (`AstroQuest.ipa`).
- `.github/workflows/stikdebug-visionos.yml` + `.github/stikdebug/autoquit.patch`: StikDebug-visionOS (rama release, 8a7fc130) con `autoQuitAfterEnablingJIT = true`, ID `com.stik.stikdebug`; release `stikdebug-visionos`.
- Bundle ID: `visionos/project.yml` `PRODUCT_BUNDLE_IDENTIFIER: com.kdt.livecontainer` (el App ID ya registrado en la cuenta de firma; SideStore añade el sufijo del equipo). El IPA de la release sale ya con él; se instala con SideStoreRAM. Para reempaquetar a mano un IPA antiguo: plistlib conservando formato binario + `zip -qry -X`.

## Flujo de trabajo
- Logs: el usuario manda `consola-*.txt` (la app los guarda en Documents). Quitar ANSI con `sed 's/\x1b\[[0-9;]*m//g'`.
- Release: `gh api repos/<owner>/AstroVisionPro/releases/tags/visionos-latest` → asset `AstroQuest.ipa`.
- El remoto `origin` del clon local tiende a apuntar al nombre antiguo del repo: hacer push explícito a la URL de AstroVisionPro.

## Pendiente (orden recomendado)
1. **Probar build de esta sesión**: ¿pasa la pantalla de calibración? Recoger del log `GS_INFO`/`GS_CODE` y `PACE`/`PACE_SAMPLE`.
2. **GS con KosmicKrisp**: revisar `kosmickrisp.log` en `ci-logs` si no compila para xros; en el dispositivo, buscar `Vulkan driver:` y errores de instancia/dispositivo. Alternativa si KK no es viable: emulación propia por compute partiendo de `ring_access_elimination.cpp`.
3. **Rendimiento**: decidir con `PACE` si los tramos de 3 fps son CPU invitada (Game:*), procesador de comandos (GpuCommandProcessor) o GPU (ningún hilo ocupado). Considerar `Log sync` desactivado y bajar a DEBUG los `Kernel.Fs open/close`.
4. Texturas BC6H/BC7 con uso Storage que MoltenVK no crea (`image.cpp:247`).
5. Quitar borde azul; activar caché de pipelines en disco.
6. Comprobación en la app de ficheros `sce_sys` (param.sfo obligatorio; playgo-chunk.dat, npbind.dat, nptitle.dat, icon0.png, pic0.png, pic1.png, trophy/trophy00.trp opcionales) en la pestaña Comprobación y en la tarjeta Juego.
7. Aviso de FEX "Failed to mprotect last page of code buffer" (inofensivo por ahora).
