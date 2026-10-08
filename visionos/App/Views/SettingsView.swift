// SPDX-License-Identifier: GPL-2.0-or-later
//
// The settings that matter most, changed in place. Each change is written to settings.txt
// (AstroSettings.write), which keeps the rest (and the less common settings, still changed in
// the file itself); a game started afterwards uses them.

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

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
                    Picker(L("Resolución por ojo", "Resolution per eye"), selection: text("resolution", \.resolution)) {
                        Text(L("1440 · consola", "1440 · console")).tag("1440")
                        Text(L("2160 · más nítida, más memoria", "2160 · sharper, more memory")).tag("2160")
                        Text(L("2880 · PC VR, la más nítida", "2880 · PC VR, the sharpest")).tag("2880")
                        Text(L("La que elija el juego", "The game's choice")).tag("game")
                    }
                    Picker(L("Antialiasing (muestras por píxel)", "Antialiasing (samples per pixel)"), selection: text("msaa", \.msaa)) {
                        Text(L("Como la consola (4)", "As on the console (4)")).tag("")
                        Text(L("2 · más rápido", "2 · faster")).tag("2")
                        Text(L("1 · el más rápido, con dientes de sierra", "1 · fastest, jagged edges")).tag("1")
                    }
                    Toggle(L("Suavizar bordes (FXAA)", "Smooth edges (FXAA)"), isOn: flag("edge_smoothing", \.edgeSmoothing))
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
                    Text(L("Los píxeles cuestan poco al visor: más resolución se ve más nítida y suaviza los bordes casi sin perder rendimiento. El límite es la memoria: si al entrar en un mundo la app se cierra sin aviso, baja un paso.", "Pixels cost the headset little: a larger size looks sharper and smooths the edges at almost no cost in speed. The limit is memory: if the app closes without a word on entering a world, go one step down."))
                }

                Section {
                    Picker(L("Driver de Vulkan", "Vulkan driver"), selection: text("vulkan_driver", \.vulkanDriver)) {
                        Text(L("KosmicKrisp · con geometry shaders", "KosmicKrisp · with geometry shaders")).tag("kosmickrisp")
                        Text(L("MoltenVK · el anterior", "MoltenVK · the previous one")).tag("moltenvk")
                    }
                    Toggle(L("Compilar shaders en segundo plano", "Compile shaders in the background"), isOn: flag("async_shaders", \.asyncShaders))
                    Toggle(L("Geometry shaders sin cortar la pasada", "Geometry shaders without breaking the pass"), isOn: flag("gs_in_pass", \.gsInPass))
                } header: {
                    Text(L("Gráficos", "Graphics"))
                } footer: {
                    Text(L("KosmicKrisp dibuja los efectos y ambos ojos como en la consola. Si no arranca o va peor, vuelve a MoltenVK. Con los shaders en segundo plano no hay tirones: lo que aparece por primera vez tarda un instante en verse. Si los efectos o partículas se ven mal, desactiva «Geometry shaders sin cortar la pasada».", "KosmicKrisp draws the effects and both eyes as the console does. If it does not start or runs worse, go back to MoltenVK. With shaders in the background there are no stalls: what appears for the first time shows a moment late. If effects or particles look wrong, turn off «Geometry shaders without breaking the pass»."))
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
