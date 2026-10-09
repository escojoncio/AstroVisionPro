// SPDX-License-Identifier: GPL-2.0-or-later
//
// The settings, kept like the PC's (pc-vr/settings.txt): one key=value a line in settings.txt,
// in the app's Documents folder (reachable from the Files app). They start at what the PC VR
// build uses, not the Quest's (apart from the resolution, which the headset cannot afford),
// and become for the emulator exactly the environment variables pc-vr/launch.ps1 makes of them.

import Foundation

struct AstroSettings {
    // As on the PC (pc-vr/settings.txt and pc-vr/launch.ps1).
    /// Width of each eye's picture: 1440 is the console's largest; 2880 = 2880x3072 (the PC's
    /// default); "game" lets the game choose among the console's sizes. Pixels cost the headset
    /// little (log 2026-10-09: the scene took the same GPU time at 1440x1536 as at 816x870);
    /// what limits larger sizes is memory.
    var resolution = "1440"
    /// The emulator's dynamic resolution is never used: the GPU's time goes to draws and passes,
    /// not to pixels, so drawing smaller only blurs the picture.
    let dynamic = false
    /// The most frames a second.
    var fps = 60
    /// How much of the headset's field of view the game draws, in percent.
    var fov = 100
    /// What fov is a percent of: "headset" or "psvr".
    var fovOf = "headset"
    /// Sharpening of the picture on its way to the headset, 0 to 1.
    var sharpen = "0.3"
    /// The most samples a pixel gets; empty: as the console draws it (4).
    var msaa = ""
    var antialias = true
    /// The hands holding the controller place it in the game.
    var hands = true
    /// How far beyond the next picture the head position is predicted, in milliseconds.
    var predictMs = 20
    var stickTouchpad = true
    var surround = true
    var realTime = true
    /// The game waits while nobody looks at it.
    var pause = true
    var game = ""
    var extraEnvironment: [String] = []

    // Apple Vision Pro only.
    /// Foveated rendering (where the eyes look is drawn at the drawable's full resolution).
    var foveation = true
    /// Compositor Services' render quality, 0 to 1 (1: the largest drawables the system offers).
    var renderQuality: Float = 1.0
    /// How much MetalFX enlarges each eye of the game's picture before it is shown: always 1 (not
    /// at all); it did not make the picture better.
    let upscale: Float = 1.0
    /// Executable memory asked of StikDebug, in megabytes.
    var jitArenaMB = 512
    /// Show the hands (and the controller in them) in front of the game.
    var showHands = false
    /// The Vulkan driver: "kosmickrisp" (Mesa's, with geometry shaders; the default when the app
    /// carries it) or "moltenvk" (no geometry shaders).
    var vulkanDriver = "kosmickrisp"
    /// Pipelines are made on threads of their own: no stalls while Metal compiles, at the cost
    /// of what they draw appearing a moment late the first time.
    var asyncShaders = true
    /// KosmicKrisp runs the geometry shaders' work inside the render pass (as vertex-only draws)
    /// instead of breaking the pass for a compute pass on every such draw.
    var gsInPass = true
    /// Experimental: KosmicKrisp lets the next render pass start its vertex work while the one
    /// before is still drawing, instead of waiting for all of it (KK_LIGHT_BARRIERS).
    var lightBarriers = false
    /// The headset's 3D audio, as PlayStation VR renders it: each of the title's 3D sounds and
    /// surround speakers rendered by Apple's PHASE, head-locked (SHADPS4_SPATIAL_AUDIO).
    var spatialAudio = true
    /// The edges of the game's picture smoothed (FXAA) before it is shown.
    var edgeSmoothing = false
    /// The language the game is played in: "system" (the headset's) or a language tag
    /// (GameLanguages.swift).
    var gameLanguage = "system"

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var fileURL: URL {
        documents.appendingPathComponent("settings.txt")
    }

    /// Reads settings.txt, writing it with the defaults first if it is not there.
    static func load() -> AstroSettings {
        var settings = AstroSettings()
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? defaultFile.write(to: url, atomically: true, encoding: .utf8)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return settings
        }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            guard let equals = line.firstIndex(of: "=") else {
                continue
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            settings.apply(key: key, value: value)
        }
        return settings
    }

    /// Sets one setting in settings.txt (the line that has it, or the commented-out line for it,
    /// or a new line at the end), leaving the rest of the file as it is.
    static func write(_ key: String, _ value: String) {
        _ = load()
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")
        func matches(_ line: String, commented: Bool) -> Bool {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if commented {
                guard trimmed.hasPrefix("#") else { return false }
                trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            guard let equals = trimmed.firstIndex(of: "=") else { return false }
            return trimmed[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == key
        }
        let line = "\(key)=\(value)"
        if let index = lines.firstIndex(where: { matches($0, commented: false) }) {
            lines[index] = line
        } else if let index = lines.firstIndex(where: { matches($0, commented: true) }) {
            lines[index] = line
        } else {
            lines.append(line)
        }
        try? lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private mutating func apply(key: String, value: String) {
        let flag = value != "0"
        switch key {
        case "resolution": resolution = value
        case "fps": fps = Int(value) ?? fps
        case "fov": fov = Int(value) ?? fov
        case "fov_of": fovOf = value
        case "sharpen": sharpen = value
        case "msaa": msaa = value
        case "antialias": antialias = flag
        case "hands": hands = flag
        case "predict_ms": predictMs = Int(value) ?? predictMs
        case "stick_touchpad": stickTouchpad = flag
        case "surround": surround = flag
        case "real_time": realTime = flag
        case "pause": pause = flag
        case "game": game = value
        case "env": extraEnvironment.append(value)
        case "foveation": foveation = flag
        case "render_quality": renderQuality = min(max(Float(value) ?? renderQuality, 0.1), 1.0)
        case "jit_arena_mb": jitArenaMB = min(max(Int(value) ?? jitArenaMB, 64), 2048)
        case "show_hands": showHands = flag
        case "vulkan_driver": vulkanDriver = value.lowercased()
        case "async_shaders": asyncShaders = flag
        case "gs_in_pass": gsInPass = flag
        case "light_barriers": lightBarriers = flag
        case "spatial_audio": spatialAudio = flag
        case "game_language": gameLanguage = value
        default: break
        }
    }

    /// What the emulator is given, as pc-vr/launch.ps1 does ("What the settings mean to the
    /// emulator").
    var environment: [String] {
        var env: [String] = []
        if resolution == "game" {
            env.append("SHADPS4_TITLE_RESOLUTION=title")
        } else {
            var width = Int(resolution) ?? 1440
            // (The console's other sizes, 816 to 1200, as they were offered before.)
            let smaller = [816: "3", 960: "4", 1200: "5"]
            if let size = smaller[width] {
                env.append("SHADPS4_TITLE_RESOLUTION=\(size)")
            } else {
                width = max(1440, min(4320, Int((Double(width) / 8.0).rounded()) * 8))
                if width > 1440 {
                    env.append("SHADPS4_TITLE_EYE_WIDTH=\(width)")
                }
                // Left to choose, the emulator draws smaller where the GPU falls behind.
                if !dynamic {
                    env.append("SHADPS4_TITLE_RESOLUTION=6")
                }
            }
        }
        env.append("SHADPS4_VR_SHARPEN=\(sharpen)")
        if !msaa.isEmpty {
            env.append("SHADPS4_MAX_MSAA=\(msaa)")
        }
        if !antialias {
            env.append("SHADPS4_RESOLVE_AA=0")
        }
        if !hands {
            env.append("SHADPS4_XR_HANDS=0")
        }
        env.append("SHADPS4_XR_PREDICT_MS=\(predictMs)")
        if !stickTouchpad {
            env.append("SHADPS4_STICK_TOUCHPAD=0")
        }
        if !surround {
            env.append("SHADPS4_VIRTUAL_SURROUND=0")
        }
        if !realTime {
            env.append("SHADPS4_TITLE_TIMESTEP=0")
        }
        if fov != 100 {
            env.append("SHADPS4_VR_FOV=\(fov)")
        }
        if fovOf != "psvr" {
            env.append("SHADPS4_VR_FOV_OF=headset")
        }
        env.append("SHADPS4_VR_FPS_CAP=\(fps)")
        if !pause {
            env.append("SHADPS4_XR_PAUSE=0")
        }
        // The headset is the app's: it is there from the start.
        env.append("SHADPS4_XR_WAIT=0")
        env.append("SHADPS4_VK_DRIVER=\(vulkanDriver)")
        env.append("SHADPS4_ASYNC_PIPELINES=\(asyncShaders ? 1 : 0)")
        env.append("KK_GS_IN_PASS=\(gsInPass ? 1 : 0)")
        env.append("KK_LIGHT_BARRIERS=\(lightBarriers ? 1 : 0)")
        env.append("SHADPS4_SPATIAL_AUDIO=\(spatialAudio ? 1 : 0)")
        env.append("SHADPS4_CONSOLE_LANGUAGE=\(GameLanguages.tag(for: gameLanguage))")
        // KosmicKrisp keeps what it translated (Mesa's shader cache) where the app may write:
        // the VPS4 folder when there is one (it outlives the app), else the app's caches.
        let caches = (GameFolder.caches ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("mesa_shader_cache")
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        env.append("MESA_SHADER_CACHE_DIR=\(caches.path)")
        // The users and their saves, in the VPS4 folder when there is one.
        if let saves = GameFolder.saves {
            env.append("SHADPS4_HOME_DIR=\(saves.path)")
        }
        env.append(contentsOf: extraEnvironment)
        return env
    }

    static let defaultFile = """
    # Ajustes de AstroQuest para Apple Vision Pro, una clave=valor por línea. Las líneas que
    # empiezan por # no cuentan. Son los mismos ajustes que la versión de PC VR
    # (pc-vr/settings.txt), con la resolución adaptada al visor, y algunos propios de él.

    # El ancho de la imagen de cada ojo: 1440 es el máximo de la consola; 2160 y 2880 (= 2880x3072,
    # el valor de PC VR) se ven más nítidos y piden más memoria al juego. game: los tamaños de la
    # consola, elegidos por el propio juego.
    resolution=1440

    # Imágenes por segundo como máximo. Una imagen dura un número entero de refrescos de la
    # pantalla del visor (90 Hz: 45 o 30; 120 Hz: 60).
    fps=60

    # Qué parte del campo de visión del visor dibuja el juego, en porcentaje (70 a 100).
    fov=100
    # De qué es porcentaje fov: headset (el visor) o psvr (el de PlayStation VR).
    fov_of=headset

    # Nitidez de la imagen camino del visor, de 0 a 1.
    sharpen=0.3

    # Muestras por píxel (1, 2, 4, 8). Sin poner: como la consola (4).
    #msaa=4
    #antialias=1

    # 0: las manos no colocan el mando en el juego.
    hands=1

    # Cuánto se adelanta la posición de la cabeza que se da al juego, en milisegundos (0 a 80).
    predict_ms=20

    #stick_touchpad=1
    #surround=1
    #real_time=1

    # 0: el juego no espera mientras nadie lo mira.
    #pause=1

    # Dónde está el juego si no está en la carpeta Documents de la app (su eboot.bin o su carpeta).
    #game=

    # --- Solo Apple Vision Pro ---

    # Renderizado foveado: donde miran los ojos se dibuja a la máxima resolución del visor.
    foveation=1
    # Idioma del juego: system (el del visor) o una etiqueta de idioma (es-ES, en-US, fr-FR…).
    game_language=system
    # Calidad de renderizado de Compositor Services, de 0.1 a 1 (1: la máxima que da el sistema).
    render_quality=1.0
    # Memoria ejecutable que se pide a StikDebug, en megabytes.
    jit_arena_mb=512
    # 1: se ven las manos (y el mando en ellas) delante del juego.
    show_hands=0
    # Driver de Vulkan: kosmickrisp (Mesa, con geometry shaders) o moltenvk (sin ellos).
    vulkan_driver=kosmickrisp
    # 1: los shaders se compilan en segundo plano (sin tirones; lo nuevo aparece un instante tarde).
    async_shaders=1
    # 1: KosmicKrisp hace el trabajo de los geometry shaders dentro de la pasada de render.
    gs_in_pass=1
    # 1 (experimental): cada pasada de render empieza sus vértices sin esperar a que acabe la anterior.
    light_barriers=0
    # 1: audio 3D como el de PlayStation VR (cada sonido y altavoz con el HRTF de Apple, PHASE).
    spatial_audio=1

    # Variables de entorno extra para el emulador, tantas líneas como hagan falta.
    #env=NOMBRE=valor
    """
}
