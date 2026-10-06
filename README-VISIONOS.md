# AstroVisionPro: AstroQuest para Apple Vision Pro

ASTRO BOT Rescue Mission (PS4 / PlayStation VR, **CUSA12392 versión 1.00**) en Apple Vision Pro, como app nativa de visionOS. Es el port de AstroQuest de Quest 3 / PC: el mismo emulador (shadPS4 con FEXCore traduciendo el código x86-64 del juego a ARM64), con estos cambios para visionOS:

| | Quest 3 | Apple Vision Pro |
|---|---|---|
| App | Android + núcleo en Linux (Bachata) | App de visionOS (SwiftUI + Compositor Services); el núcleo es una librería estática dentro de la app |
| Gráficos | Vulkan (Turnip) | Vulkan sobre Metal (MoltenVK) |
| Casco | OpenXR | Compositor Services + ARKit |
| Resolución y ajustes | los de Quest | **los de PC VR** (2880 px por ojo, dinámica, nitidez 0.3, 60 fps, FOV del visor, predicción 20 ms) |
| Renderizado foveado | — | **activado** (`isFoveationEnabled`, mapa de tasas de rasterizado de visionOS) |
| JIT | nativo | **StikDebug para visionOS** |
| Mando | DualSense/DualShock 4 | DualSense/DualShock 4 vía GameController (`GCDualSenseGamepad` / `GCDualShockGamepad`) |

> [!CAUTION]
> **No se da ningún soporte a la piratería.** Se espera que uses tu propia copia del juego, sacada del original que has comprado. Las copias piratas no tienen soporte de ningún tipo. Si te gusta ASTRO BOT Rescue Mission, apoya a PlayStation y a Team ASOBI comprando sus juegos.

## Requisitos

- Apple Vision Pro con **visionOS 26.5 o posterior, incluido visionOS 27**. La app se compila con el SDK de visionOS 26.5 (Xcode 26.6) y se instala y abre también en visionOS 27. El mínimo es 26.5 porque MoltenVK (la capa Vulkan sobre Metal) viene compilado para esa versión.
- **Instalarla con la extensión de memoria (Increased Memory Limit).** Sin ella visionOS le da a la app muy poca memoria para el emulador (la PS4 tiene 8 GB). Fírmala con una herramienta que active la capacidad *Increased Memory Limit* en el App ID de la app, como [GetMoreRam](https://github.com/hugeBlack/GetMoreRam) o [iLoader-VisionPro](../../../iLoader-VisionPro/tree/visionos-windows) (rama `visionos-windows`), y que conserve `get-task-allow` (para StikDebug). La pestaña *Comprobación* de la app dice si la tiene. El espacio de direcciones ampliado (`extended-virtual-addressing`) también ayuda si la herramienta lo activa.
- **StikDebug para visionOS** (https://github.com/rebelancap/StikDebug-visionos) para activar el JIT, **con la imagen de disco de desarrollador de visionOS (DDI), que tienes que conseguir tú**: la carpeta `DDI` con `Image.dmg`, `Image.dmg.trustcache` y `BuildManifest.plist`, copiada en la carpeta de StikDebug (app Archivos: *En mi Apple Vision Pro › StikDebug › DDI*). Sin ella StikDebug no puede activar el JIT. Son archivos de Apple y no se pueden publicar aquí: vienen con Xcode en un Mac (uno compatible con tu versión de visionOS), en `Xcode.app/Contents/Resources/CoreDeviceDDIs/xrOS_DDI.dmg` o en `/Library/Developer/DeveloperDiskImages/xrOS_DDI` (carpeta `Restore`: la imagen personalizada y su trust cache que indica `BuildManifest.plist`).
- Un **mando de PlayStation**: DualSense (recomendado) o DualShock 4. El juego usa su panel táctil y sus sensores de movimiento.
- Tu propia copia del juego (carpeta `CUSA12392` con `eboot.bin`, `sce_sys` y `sce_module`), versión 1.00.

## 1. Conseguir la app

La compila GitHub Actions (flujo `visionos-app`, solo cuando se pide): el archivo `AstroQuest.ipa` sin firmar está en la release [`visionos-latest`](../../releases/tag/visionos-latest). También puedes compilarla en un Mac con Xcode 26:

```sh
git submodule update --init --depth 1
bash visionos/scripts/build-core.sh        # FEXCore, MoltenVK y el emulador
cd visionos && xcodegen generate && open AstroQuest.xcodeproj
```

En Xcode elige tu equipo de desarrollo en *Signing & Capabilities* y ejecuta en el Vision Pro.

## 2. Instalarla firmada con tu cuenta

Con el `.ipa` sin firmar, fírmalo e instálalo **con la extensión de memoria (Increased Memory Limit)**: con una herramienta que active esa capacidad en el App ID al firmar (GetMoreRam, [iLoader-VisionPro](../../../iLoader-VisionPro/tree/visionos-windows)) o con Xcode y la capacidad añadida. Comprueba que la firma conserve `get-task-allow` (sin él StikDebug no puede conectarse). Después, en la app, la pestaña *Comprobación* debe mostrar la memoria extra en verde.

## Comprobación al abrir la app

Al abrir AstroQuest, el apartado **Comprobación** dice por separado qué tiene esta copia de la app y qué le falta, antes de intentar jugar:

- **Memoria extra** (`increased-memory-limit`): si la firma incluye el permiso y cuánta memoria deja usar el sistema de verdad (hacen falta unos 6 GB).
- **Espacio de direcciones** (`extended-virtual-addressing`): si la firma incluye el permiso y cuántos GB seguidos se pueden reservar (el emulador necesita 24).
- **Se puede depurar** (`get-task-allow`): sin esto StikDebug no puede conectarse.
- **JIT**: el resultado de activar el JIT con StikDebug, incluida la prueba de ejecutar código.

También muestra el *Bundle ID* con el que quedó instalada, y **Copiar informe** copia todo el resultado como texto.

Los dos permisos de memoria dependen de las *capabilities* del App ID en tu cuenta de Apple: la herramienta con la que firmas la app tiene que activarlas en ese App ID.

## 3. JIT con StikDebug para visionOS

visionOS solo permite memoria ejecutable nueva a una app con un depurador conectado. AstroQuest lo resuelve con StikDebug para visionOS, que se conecta a la app y ejecuta el script `universal.js`:

1. Instala StikDebug para visionOS (release v1.0.0) y sigue su guía: importa tu fichero de emparejamiento (*RPPairing*, el `rp_pairing_file.plist` que genera SideStore/JitterbugPair) y activa LocalDevVPN.
2. Abre AstroQuest y pulsa **Activar JIT con StikDebug**. AstroQuest abre `stikjit://enable-jit?bundle-id=com.astroquest.visionpro&pid=…&script-name=universal.js`; StikDebug se conecta a AstroQuest (al proceso que ya está abierto) y ejecuta el script.
3. Vuelve a AstroQuest: comprueba que el depurador está conectado (`CS_DEBUGGED`), reserva la zona de memoria ejecutable (por defecto 512 MB, `jit_arena_mb`) con el protocolo de `universal.js` (`brk #0xf00d`, `x16 = 1` para preparar la región y `x16 = 0` para soltar el depurador) y hace una prueba escribiendo y ejecutando una instrucción. Cuando aparece **JIT activo** se puede jugar.

**visionOS 27:** StikDebug para visionOS declara compatibilidad con visionOS 26 y 27 y su código no tiene ninguna comprobación de versión que lo impida; usa el mismo mecanismo (depurador por la VPN local + TXM) que en 26. No lo he podido probar en un Vision Pro con 27: si en 27 falla, la app lo indica y se queda en «JIT no activo» sin arrancar el juego.

## 4. Copiar el juego

Con la app **Archivos** del Vision Pro, copia la carpeta `CUSA12392` a *En mi Apple Vision Pro › AstroQuest* (o a una subcarpeta `games`). Lo más cómodo es desde una carpeta compartida de tu PC/Mac (*Archivos › Conectarse a un servidor*). La app la encuentra sola; si tienes varias, la ruta se puede fijar con `game=` en `settings.txt`.

## 5. El mando

Empareja el DualSense en *Ajustes › Bluetooth* (mantén **Crear** + **PS** hasta que parpadee la barra de luz). Todo el control del juego pasa por el perfil de mando de PlayStation de GameController:

- Botones: Cruz, Círculo, Cuadrado, Triángulo, L1/R1, L2/R2 (analógicos), L3/R3, Options, cruceta, panel táctil (toque y clic) y botón PS.
- Sensores de movimiento: giroscopio y acelerómetro, con los mismos ejes que la versión de PC (SDL). Con ellos el juego coloca el mando en el espacio, como hace la cámara de PS4.
- Vibración (CoreHaptics, motor izquierdo y derecho) y color de la barra de luz los pone el juego.
- Los gestos del sistema del mando se desactivan dentro de la app para que el botón PS y Options lleguen al juego.

Si no es un mando de PlayStation, la app lo avisa: faltan panel táctil y sensores, y el juego no puede seguir el mando.

## 6. Ajustes (`settings.txt`)

Está en la carpeta de la app (app Archivos). Se crea con los valores de la versión de PC VR:

| Clave | Por defecto | Qué hace |
|---|---|---|
| `resolution` | `2880` | Anchura por ojo (la de PC VR). `game` deja que el juego elija entre los tamaños de la consola. |
| `dynamic` | `1` | Resolución dinámica, como en PC. |
| `fps` | `60` | Límite de imágenes por segundo. |
| `fov`, `fov_of` | `headset` | Campo de visión respecto al del visor. |
| `sharpen` | `0.3` | Nitidez (la de PC). |
| `msaa`, `antialias` | consola | Antialiasing. |
| `predict_ms` | `20` | Predicción de la posición de la cabeza. |
| `foveation` | `1` | **Renderizado foveado** de visionOS. |
| `render_quality` | `1.0` | Calidad de renderizado de Compositor Services (0.1–1.0). |
| `jit_arena_mb` | `512` | Memoria ejecutable que se pide a StikDebug. |
| `show_hands` | `0` | Mostrar tus manos sobre el juego. |
| `env` | — | Variables extra para el emulador (`env=NOMBRE=valor`). |

## Cómo está hecho

- `visionos/App`: la app. `Render/GameRenderer.swift` pide a Compositor Services capas con foveado y la máxima calidad, recibe cada imagen del juego (una textura Metal exportada desde Vulkan con `VK_EXT_metal_objects`) con la pose y el FOV con que se dibujó, y la reproyecta por rotación a la pose actual de cada ojo (`Shaders.metal`). `Tracking/HeadsetTracking.swift` da la cabeza y las manos (ARKit). `Controller/PlayStationController.swift` es el mando. `JIT/JITGate.swift` es StikDebug.
- `shadps4-arm64-main/src/platform/visionos`: la interfaz en C entre la app y el emulador (`astro_core.h`) y la memoria JIT (`jit_arena.c`).
- `shadps4-arm64-main/src/core/vr/openxr_host_visionos.mm`: el «host» de VR del PC, que en vez de a OpenXR entrega las imágenes a la app.
- `visionos/patches/fex-darwin.patch`: FEXCore en sistemas de Apple (esperas sin futex, características de CPU por `sysctl`, sin el registro x18, código escrito por una vista RW y ejecutado por otra RX).
- `visionos/scripts`: compilación de FEXCore, MoltenVK y el emulador.

## Estado

La app completa (FEXCore, MoltenVK, FFmpeg 7.1, el emulador y la app en Swift) **compila y enlaza en GitHub Actions** para visionOS y genera `AstroQuest.ipa` (sin firmar). **No se ha probado en un Apple Vision Pro**, así que puede haber problemas al ejecutarla: memoria, partes de Vulkan que MoltenVK no cubra o señales de FEX en Darwin. El registro del emulador se guarda en la carpeta de la app, y si el emulador termina la app indica dónde está.
