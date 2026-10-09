// SPDX-License-Identifier: GPL-2.0-or-later
//
// The settings that matter most, changed in place. Each change is written to settings.txt
// (AstroSettings.write), which keeps the rest (and the less common settings, still changed in
// the file itself); a game started afterwards uses them.

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// The rumble test's step now («Probar vibración»), "" when it is not running.
    @State private var rumbleStep = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L("Idioma", "Language"), selection: Binding(
                        get: { Language.shared.choice },
                        set: { Language.shared.choice = $0 })) {
                        Text(L("El del sistema", "System")).tag(AppLanguage.system)
                        Text("Español").tag(AppLanguage.spanish)
                        Text("English").tag(AppLanguage.english)
                    }
                } header: {
                    Text(L("Idioma", "Language"))
                }

                Section {
                    GameLanguagePicker()
                    Toggle(L("Tiempo real", "Real time"), isOn: flag("real_time", \.realTime))
                    Button(L("Probar vibración del mando (5 pruebas)", "Test the controller's rumble (5 tries)")) {
                        PlayStationController.shared.testRumble { step in
                            rumbleStep = step
                        }
                    }
                    .disabled(!rumbleStep.isEmpty)
                    if !rumbleStep.isEmpty {
                        Text(rumbleStep)
                            .font(.headline)
                            .foregroundStyle(.orange)
                    }
                    Toggle(L("El mando es de la app (para la vibración)", "The controller is the app's (for rumble)"), isOn: flag("controller_to_app", \.controllerToApp))
                    Toggle(L("Cerrar el lanzador al jugar", "Close the launcher while playing"), isOn: flag("close_launcher", \.closeLauncher))
                    Toggle(L("Audio 3D como PlayStation VR", "3D audio as on PlayStation VR"), isOn: flag("spatial_audio", \.spatialAudio))
                } header: {
                    Text(L("Juego", "Game"))
                } footer: {
                    Text([
                        gameLanguageFooter,
                        L("«Tiempo real»: el juego avanza al ritmo del reloj aunque dibuje menos de 60 imágenes por segundo. Desactivado, cada imagen avanza 1/60 s (cámara lenta cuando va lento); sirve para comprobar si los fallos de física, como atravesar paredes, vienen de pasos de tiempo largos.", "«Real time»: the game moves at the clock's pace even when it draws fewer than 60 frames a second. Off, every frame moves it 1/60 s (slow motion when it runs slow); it shows whether physics faults, like going through walls, come from long time steps."),
                        L("«Probar vibración»: hace 5 pruebas seguidas, cada una dice en pantalla cuál es; apoya los dedos en L2 y R2 para la 5 (gatillos). Dime en cuáles notaste algo. «El mando es de la app»: la ventana recibe el mando por GameController, como pide Apple en visionOS; se aplica al abrir la app.", "«Test rumble»: 5 tries in a row, each says on screen which it is; rest your fingers on L2 and R2 for the 5th (triggers). Tell which ones you felt. «The controller is the app's»: the window takes the controller through GameController, as Apple asks on visionOS; it applies when the app opens."),
                        L("«Cerrar el lanzador al jugar» desactivado: la ventana sigue abierta durante la partida (prueba de si la vibración se pierde al quedarse la app sin ventanas).", "«Close the launcher while playing» off: the window stays open during the game (a test of whether rumble is lost when the app is left without windows)."),
                        L("«Audio 3D como PlayStation VR»: cada sonido 3D del juego y cada altavoz del 7.1 suena desde su dirección con el audio espacial de Apple, girando con el juego como en el visor de PS4.", "«3D audio as on PlayStation VR»: every 3D sound of the game and every 7.1 speaker is heard from its direction through Apple's spatial audio, turning with the game as in the PS4 headset."),
                    ].joined(separator: " "))
                }

                Section {
                    Picker(L("Resolución por ojo", "Resolution per eye"), selection: text("resolution", \.resolution)) {
                        Text(L("1440 · consola", "1440 · console")).tag("1440")
                        Text(L("2160 · más nítida, más memoria", "2160 · sharper, more memory")).tag("2160")
                        Text(L("2880 · PC VR, la más nítida", "2880 · PC VR, the sharpest")).tag("2880")
                        Text(L("La que elija el juego", "The game's choice")).tag("game")
                    }
                    Toggle(L("Antialiasing SMAA", "SMAA antialiasing"), isOn: flag("smaa", \.edgeSmoothing))
                    Toggle(L("Suavizado del juego al resolver", "The game's smoothing on resolve"), isOn: flag("antialias", \.antialias))
                    Picker(L("Imágenes por segundo", "Frames per second"), selection: number("fps", \.fps)) {
                        Text("60").tag(60)
                        Text("45").tag(45)
                        Text("30").tag(30)
                    }
                    LabeledContent(L("Campo de visión", "Field of view")) {
                        Stepper("\(model.settings.fov) %", value: number("fov", \.fov), in: 70...100, step: 5)
                    }
                    LabeledContent(L("Nitidez", "Sharpness")) {
                        HStack {
                            Slider(value: sharpen, in: 0...1, step: 0.1)
                                .frame(width: 240)
                            Text(model.settings.sharpen)
                                .monospacedDigit()
                                .frame(width: 40)
                        }
                    }
                } header: {
                    Text(L("Imagen", "Picture"))
                } footer: {
                    Text(L("Los píxeles cuestan poco al visor: más resolución se ve más nítida y suaviza los bordes casi sin perder rendimiento. El límite es la memoria: si al entrar en un mundo la app se cierra sin aviso, baja un paso. «Suavizado del juego al resolver»: donde la consola usaría MSAA, el emulador suaviza los bordes al copiar la imagen (4 pasadas por imagen); desactivado (lo normal) se copia tal cual y el SMAA del visor sigue suavizando. Se aplica al abrir el juego, no a mitad de partida.", "Pixels cost the headset little: a larger size looks sharper and smooths the edges at almost no cost in speed. The limit is memory: if the app closes without a word on entering a world, go one step down. «The game's smoothing on resolve»: where the console would use MSAA, the emulator smooths the edges as it copies the picture (4 passes a frame); off (the usual), it is copied as it is and the headset's SMAA still smooths it. It applies when the game opens, not midway."))
                }

                Section {
                    Picker(L("Driver de Vulkan", "Vulkan driver"), selection: text("vulkan_driver", \.vulkanDriver)) {
                        Text(L("KosmicKrisp · con geometry shaders", "KosmicKrisp · with geometry shaders")).tag("kosmickrisp")
                        Text(L("MoltenVK · el anterior", "MoltenVK · the previous one")).tag("moltenvk")
                    }
                    Toggle(L("Compilar shaders en segundo plano", "Compile shaders in the background"), isOn: flag("async_shaders", \.asyncShaders))
                    Toggle(L("Guardar y precargar shaders", "Keep and preload shaders"), isOn: flag("shader_cache", \.shaderCache))
                    Toggle(L("Geometry shaders sin cortar la pasada", "Geometry shaders without breaking the pass"), isOn: flag("gs_in_pass", \.gsInPass))
                    Toggle(L("Memoria de geometry shaders entre pasadas", "Geometry shader memory between passes"), isOn: flag("heap_between_passes", \.heapBetweenPasses))
                    Toggle(L("Juntar pasadas", "Merge passes"), isOn: flag("merge_passes", \.mergePasses))
                    Toggle(L("Pasadas solapadas (experimental)", "Overlapping passes (experimental)"), isOn: flag("light_barriers", \.lightBarriers))
                    Toggle(L("Diagnóstico de pasadas en el registro", "Pass diagnostics in the log"), isOn: flag("pass_diagnostics", \.passDiagnostics))
                    Toggle(L("Primitive restart en listas", "Primitive restart on lists"), isOn: flag("list_restart", \.listRestart))
                    Toggle(L("Constantes como uniform buffers (experimental)", "Constants as uniform buffers (experimental)"), isOn: flag("constant_ubo", \.constantUbo))
                    Picker(L("Prueba de GPU con L3 + R3", "GPU test with L3 + R3"), selection: Binding(get: { model.settings.gpuTest == "stages" ? "stages" : "shaders" }, set: { save("gpu_test", $0) })) {
                        Text(L("Por shader · ~1 min", "By shader · ~1 min")).tag("shaders")
                        Text(L("Por etapas · ~2 min", "By stages · ~2 min")).tag("stages")
                    }
                    Picker(L("Reloj de GPU que ve el juego", "GPU clock the game sees"), selection: text("gpu_clock_scale", \.gpuClockScale)) {
                        Text(L("Automático · se ajusta en cada imagen", "Automatic · adjusted every frame")).tag("auto")
                        Text(L("Real", "Real")).tag("1")
                        Text(L("×0,5 · la GPU parece el doble de rápida", "×0.5 · the GPU looks twice as fast")).tag("0.5")
                        Text(L("×0,25 · cuatro veces más rápida", "×0.25 · four times as fast")).tag("0.25")
                    }
                } header: {
                    Text(L("Gráficos", "Graphics"))
                } footer: {
                    Text(L("KosmicKrisp dibuja los efectos y ambos ojos como en la consola. Si no arranca o va peor, vuelve a MoltenVK. Con los shaders en segundo plano no hay tirones: lo que aparece por primera vez tarda un instante en verse. Si los efectos o partículas se ven mal, desactiva «Geometry shaders sin cortar la pasada». «Memoria de geometry shaders entre pasadas» evita cortar la pasada en el primer efecto de cada una (unas 6 por imagen); si los efectos o partículas parpadean o se rompen, desactívalo. L3 + R3 a la vez dentro del juego: prueba de GPU (quédate quieto; partes de la imagen desaparecen mientras dura). «Por shader» (~1 min) mide cuánto cuesta cada shader de la escena quitándolos uno a uno; «Por etapas» (~2 min) es la prueba anterior. Se aplica al abrir el juego. «Juntar pasadas» evita cortar la pasada cuando un dibujo usa menos destinos que ella (menos memoria movida por frame); si ves sombras o capas mal, desactívalo. «Pasadas solapadas» deja que cada pasada empiece antes de que acabe la anterior: más rápido, pero si ves parpadeos o imágenes rotas, desactívalo. «Reloj de GPU que ve el juego»: el juego quita sombras y efectos cuando mide su GPU lenta. «Automático» (lo normal) la hace parecer tan rápida como haga falta para que tenga todo el detalle, y vuelve a la hora real al acabar cada imagen (sin desfase). ×0,5 y ×0,25 son fijos, para comparar; si el juego se cuelga o va raro, prueba Real. Dentro del juego, L1 + R1 sujetos y pulsar R3: marca en el registro el momento en que ves las sombras. «Primitive restart en listas» desactivado (lo normal, como en shadPS4 con KosmicKrisp): KosmicKrisp no rehace cada dibujo con una pasada de cálculo; si ves geometría rota, actívalo. «Constantes como uniform buffers»: los shaders leen sus constantes (luces, matrices) por la vía rápida de Metal; si ves luces, colores o geometría raros, desactívalo. Se aplica al abrir el juego.", "KosmicKrisp draws the effects and both eyes as the console does. If it does not start or runs worse, go back to MoltenVK. With shaders in the background there are no stalls: what appears for the first time shows a moment late. If effects or particles look wrong, turn off «Geometry shaders without breaking the pass». «Geometry shader memory between passes» avoids cutting a pass at its first effect (about 6 a frame); if effects or particles flicker or break, turn it off. L3 + R3 together in the game: a GPU test (keep still; parts of the picture vanish while it runs). «By shader» (~1 min) measures what each of the scene's shaders costs by leaving them out one at a time; «By stages» (~2 min) is the older test. It applies when the game opens. «Merge passes» keeps the pass going when a draw uses fewer of its targets (less memory moved a frame); turn it off if shadows or layers look wrong. «Overlapping passes» lets each pass start before the one before it ends: faster, but turn it off if you see flicker or broken pictures. «GPU clock the game sees»: the game leaves shadows and effects out when it finds its GPU slow. «Automatic» (the usual) makes it look as fast as needed for full detail and puts it back on real time at the end of every frame (no drift). ×0.5 and ×0.25 are fixed, to compare; if the game hangs or acts oddly, try Real. In the game, hold L1 + R1 and press R3: marks in the log the moment you see the shadows. «Primitive restart on lists» off (the usual, as shadPS4 has it with KosmicKrisp): KosmicKrisp does not redo each such draw with a compute pass; turn it on if geometry looks broken. «Constants as uniform buffers»: the shaders read their constants (lights, matrices) through Metal's fast path; turn it off if lights, colours or geometry look odd. It applies when the game opens."))
                }

                Section {
                    Toggle(L("Renderizado foveado", "Foveated rendering"), isOn: flag("foveation", \.foveation))
                    LabeledContent(L("Calidad de renderizado", "Render quality")) {
                        HStack {
                            Slider(value: renderQuality, in: 0.1...1, step: 0.05)
                                .frame(width: 240)
                            Text(String(format: "%.2f", model.settings.renderQuality))
                                .monospacedDigit()
                                .frame(width: 48)
                        }
                    }
                    LabeledContent(L("Predicción de la cabeza", "Head prediction")) {
                        Stepper("\(model.settings.predictMs) ms", value: number("predict_ms", \.predictMs), in: 0...80, step: 5)
                    }
                } header: {
                    Text(L("Visor", "Headset"))
                }

                Section {
                    Toggle(L("Colocar el mando con las manos", "Place the controller with the hands"), isOn: flag("hands", \.hands))
                    Toggle(L("Ver mis manos durante el juego", "See my hands while playing"), isOn: flag("show_hands", \.showHands))
                    Toggle(L("Pausar al quitarse el visor", "Pause when the headset is taken off"), isOn: flag("pause", \.pause))
                } header: {
                    Text(L("Mando y manos", "Controller and hands"))
                }

#if VPENGINE
                VPEngineSection()
#endif
                StorageSection()

                Section {
                    Picker(L("Memoria ejecutable", "Executable memory"), selection: number("jit_arena_mb", \.jitArenaMB)) {
                        Text("256 MB").tag(256)
                        Text("512 MB").tag(512)
                        Text("1024 MB").tag(1024)
                    }
                } header: {
                    Text("JIT")
                } footer: {
                    Text(L("Los cambios se aplican la próxima vez que empieces el juego. El resto de ajustes están en settings.txt, en la carpeta de AstroQuest de la app Archivos.", "Changes apply the next time you start the game. The other settings are in settings.txt, in AstroQuest's folder in the Files app."))
                }
            }
            .navigationTitle(L("Ajustes", "Settings"))
        }
    }

    private var gameLanguageFooter: String {
        let codes = model.gameLanguageCodes
        let base = L("El juego usa el idioma que le dé la consola si lo tiene; si no, inglés.",
                     "The game plays in the console's language when it has it; English otherwise.")
        if codes.isEmpty {
            return base
        }
        return base + " " + L("Idiomas en los archivos de tu copia: ", "Languages in your copy's files: ")
            + codes.joined(separator: ", ") + "."
    }

    // MARK: - Bindings that write settings.txt

    private func save(_ key: String, _ value: String) {
        AstroSettings.write(key, value)
        model.settings = AstroSettings.load()
    }

    private func flag(_ key: String, _ path: KeyPath<AstroSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: path] },
                set: { save(key, $0 ? "1" : "0") })
    }

    private func number(_ key: String, _ path: KeyPath<AstroSettings, Int>) -> Binding<Int> {
        Binding(get: { model.settings[keyPath: path] },
                set: { save(key, String($0)) })
    }

    private func text(_ key: String, _ path: KeyPath<AstroSettings, String>) -> Binding<String> {
        Binding(get: { model.settings[keyPath: path] },
                set: { save(key, $0) })
    }

    private var sharpen: Binding<Double> {
        Binding(get: { Double(model.settings.sharpen) ?? 0.3 },
                set: { save("sharpen", String(format: "%.1f", $0)) })
    }

    private var renderQuality: Binding<Float> {
        Binding(get: { model.settings.renderQuality },
                set: { save("render_quality", String(format: "%.2f", $0)) })
    }
}

/// The language the game is played in, as a menu: the headset's, or one of the game's. The ones
/// the copy's files show it has come first.
struct GameLanguagePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let available = GameLanguages.available(codes: model.gameLanguageCodes)
        let current = model.settings.gameLanguage
        let inCopy = GameLanguages.all.filter { available.contains($0.tag) }
        let others = GameLanguages.all.filter { !available.contains($0.tag) }
        Picker(L("Idioma del juego", "Language of the game"), selection: Binding(
            get: { model.settings.gameLanguage },
            set: {
                AstroSettings.write("game_language", $0)
                model.settings = AstroSettings.load()
            })) {
            Text(L("El del visor", "The headset's")).tag("system")
            if current != "system" && !GameLanguages.all.contains(where: { $0.tag == current }) {
                Text(current).tag(current)
            }
            if !inCopy.isEmpty {
                Section(L("En tu copia", "In your copy")) {
                    ForEach(inCopy) { Text(GameLanguages.name(of: $0.tag)).tag($0.tag) }
                }
                Section(L("Otros (si tu copia no lo tiene, inglés)", "Others (English if your copy does not have it)")) {
                    ForEach(others) { Text(GameLanguages.name(of: $0.tag)).tag($0.tag) }
                }
            } else {
                ForEach(GameLanguages.all) { Text(GameLanguages.name(of: $0.tag)).tag($0.tag) }
            }
        }
        .pickerStyle(.menu)
    }
}
