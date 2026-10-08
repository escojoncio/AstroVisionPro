# Bitácora — AstroVisionPro

Port de ASTRO BOT Rescue Mission (PSVR, CUSA12392 v1.00) a Apple Vision Pro (visionOS 27).
Base: shadPS4 ARM64 (`shadps4-arm64-main/`) + FEXCore (x86-64 → ARM64) + MoltenVK.
App visionOS en `visionos/` (SwiftUI + Compositor Services + ARKit + GameController).
JIT: arena RWX preparada por StikDebug (protocolo `brk #0xf00d` + universal.js); la app hace detach al terminar.

## Estado tras la última build (commit 749ad2e, release `visionos-latest`)

Funciona en el dispositivo:
- Arranque completo del juego bajo FEX: carga de módulos, main de ASOBI, salas, audio (se oye).
- Fotogramas del visor entregados a la escena inmersiva (`GameRenderer.swift`), con reproyección por pose.
- **Primer 3D visible** con el bypass experimental de GS: ojo derecho correcto, ojo izquierdo deforme.
- Sin bloqueos por bucles de fallos de página (causa raíz resuelta, ver abajo).

No funciona / pendiente:
- Ojo izquierdo deforme (GS no emulado; el bypass dibuja el ES como VS).
- Rendimiento: ~3 fps en la intro/carga, ~25 fps estable después; compositor baja a ~50 Hz. Audio petardea por falta de ritmo.
- Calibración del jugador (pantalla verde con silueta) no avanza: el juego espera el mando localizado.
- Borde azul provisional en `Shaders.metal` (diagnóstico; quitar cuando haya imagen correcta).

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
- Instalación de prueba: el IPA se reempaqueta con `CFBundleIdentifier=com.kdt.livecontainer` (plistlib conservando formato binario; `zip -qry -X`) y se instala con SideStoreRAM.

## Flujo de trabajo
- Logs: el usuario manda `consola-*.txt` (la app los guarda en Documents). Quitar ANSI con `sed 's/\x1b\[[0-9;]*m//g'`.
- Release: `gh api repos/<owner>/AstroVisionPro/releases/tags/visionos-latest` → asset `AstroQuest.ipa`.
- El remoto `origin` del clon local tiende a apuntar al nombre antiguo del repo: hacer push explícito a la URL de AstroVisionPro.

## Pendiente (orden recomendado)
1. **Emular el GS** (`max_vert_out 32`, entrada TriangleStrip, salida TriangleStrip): compute shader que ejecute ES+GS y escriba vértices en un buffer + VS de paso; o mesh shaders de Metal. Objetivo: ojo izquierdo correcto. Partir de `ring_access_elimination.cpp` (mapeo ES ring → atributos, `gs_copy_data.attr_map`).
2. **Rendimiento**: medir dónde se va el tiempo en la fase de 3 fps (sampleo nativo del watchdog bajo demanda, fallos de página por segundo, traducción FEX, GPU). Considerar `Log sync` desactivado.
3. **Calibración**: registrar en el log si ARKit entrega manos (`HeadsetTracking.swift`) y la pose del mando que recibe `vr_tracker.cpp`; revisar `sceVrTrackerRecalibrate` (stub).
4. Texturas BC6H/BC7 con uso Storage que MoltenVK no crea (`image.cpp:247`).
5. Quitar borde azul; activar caché de pipelines en disco.
6. Comprobación en la app de ficheros `sce_sys` (param.sfo obligatorio; playgo-chunk.dat, npbind.dat, nptitle.dat, icon0.png, pic0.png, pic1.png, trophy/trophy00.trp opcionales) en la pestaña Comprobación y en la tarjeta Juego.
7. Aviso de FEX "Failed to mprotect last page of code buffer" (inofensivo por ahora).
