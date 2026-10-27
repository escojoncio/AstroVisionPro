# Mapa de funciones (AstroVisionPro)

## Cadena
- CPU del juego: FEX (JIT x86-64→ARM64), arena RWX de StikDebug (`brk #0xf00d` + universal.js). Parche `visionos/patches/fex-darwin.patch`; `fex_guest_engine.cpp` (SIGBUS Darwin, `kHostPageSize`).
- GPU: Liverpool (PM4, `video_core/amdgpu/liverpool.cpp`) → `VideoCore::RasterizerInterface` (`rasterizer_interface.h`) → `platform/visionos/vpkengine_renderer.{h,mm}` (VpkengineRenderer::Rasterizer, Present) → VPKEngine vp4 (`gpu/ps4/engine/{core,metal,ir,msl,gcn}` + `gpu/ps4` vpps4) fijado por `visionos/vpkengine-gpu.ref`.
- `gnmdriver.cpp` (`SHADPS4_VPKENGINE_ONLY`) crea Rasterizer + Presenter VPKEngine; `vpkengine_presenter.{h,cpp}` fachada para `videoout/driver.cpp`. Vulkan/MoltenVK sigue enlazado sin iniciarse.
- Ojos: `Present::ComposeEyes` → `openxr_host_visionos.mm` (`StartMetal`/`BeginMetalFrame`, ranuras RGBA8 sRGB, `NumSlots` 6) → `visionos/App/Render/GameRenderer.swift` (reproyección por pose, SMAA, log `Headset:`).
- Pantalla plana en el visor: `driver.cpp` `SubmitScreenToHeadset` (pantalla 70°, pose solo guiñada).

## Emulador (shadps4-arm64-main/src)
- HMD: `hmd/hmd_reprojection.cpp` (`frame_labels`, `SatisfyReprojectionLabelWait` con etiquetas vecinas <0x80, 100 ms), `sceHmdReprojectionStart2dVr`, `hmd_setup_dialog.cpp` (VrServiceDialog HLE → OK).
- Etiquetas: `liverpool.cpp` `WaitRegMem` → `PrepareLabelWait`/`IdleLabelWait` (gfx y ASC). `SendCommandAfterGfx` para frames de casco.
- VrTracker: `vr_tracker/vr_tracker.cpp` tolerante (solo rechaza bloque nulo).
- Memoria 16 KB: `address_space.cpp`, `page_manager.cpp`, `memory.cpp`. Watchdog `guest_watchdog.cpp` (`PACE`, `MEMORY`), `signals.cpp` (`ASTRO_CRASH`, `ASTRO_FAULT_LOOP`).
- Diagnóstico: `common/diagnostics.h` (`DiagBudget`, épocas al entrar en VR). Volcado shaders `SHADPS4_DUMP_SHADERS`.
- Audio PHASE (`spatial_audio_visionos.mm`), micro (`phase_audio_in.cpp`), `sdl_audio_out.cpp` `PaceByDevice`. Idioma `SHADPS4_CONSOLE_LANGUAGE`.
- Juegos: todo lo específico de ASTRO BOT exige CUSA12392 (`known_title.cpp`).

## Logs VPKEngine
- `VPKENGINE_GPU renderer on` (build nueva), `VPKENGINE_GPU cpu:` / `cpu bind phases (ms/s)` / `dma:` (~2 s), `vpps4.frame` (cada 120 frames), `gpu.err`, `vpps4.shader error`, `VPKENGINE_PRESENT eye N`, `EYE_STATS` (luma y % no negro por ojo), `VPKENGINE_GEOM`, `draws left out`.
- Volcados de shaders que cuelgan la GPU: `Registros/gpu-hang-<hash>.metal`.

## App (visionos/App)
- `Core/AstroSettings.swift` (`settings.txt`, `environment`), `Views/SettingsView.swift` (ajustes de jugador + «Modo diagnóstico»), `Core/AppModel.swift` (`findGame`), `Core/GameFolder.swift` (VPS4), `Core/LogFiles.swift`.
- Mando `Controller/PlayStationController.swift`; seguimiento `Tracking/*`.
- Ajustes VPKEngine: `msaa_samples`→`SHADPS4_MAX_MSAA` (1/2/4), `game_foveation`→`SHADPS4_GAME_FOVEATION`.

## CI
- `.github/workflows/visionos-app.yml`: `[build]` o dispatch; release `visionos-latest/AstroQuest.ipa`; logs en rama `ci-logs` (`git show FETCH_HEAD:<workflow>.txt`).
- `visionos-vpengine.yml` (`[build-vpkengine]`, release `visionos-vpengine`, «AstroQuest VPEngine»), `stikdebug-visionos.yml`.
- Comprobación local: `clang++ -std=c++23 -fsyntax-only` con `SHADPS4_VISIONOS ENABLE_OPENXR_HOST SHADPS4_VPKENGINE_ONLY`; los `.mm` solo compilan en CI macOS. Tests Linux (CMake mínimo): census, reg_audit, pm4_exec, liverpool_pm4.
- Commits: identidad `Claude`, email vacío.
