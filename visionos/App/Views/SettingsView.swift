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
                        Text("2880 · PC VR").tag("2880")
                        Text("2160").tag("2160")
                        Text(L("1440 · consola", "1440 · console")).tag("1440")
                        Text(L("La que elija el juego", "The game's choice")).tag("game")
                    }
                    Toggle(L("Resolución dinámica", "Dynamic resolution"), isOn: flag("dynamic", \.dynamic))
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
                    Text(L("Los valores por defecto son los de la versión de PC VR.", "The defaults are those of the PC VR version."))
                }

                Section {
                    Picker(L("Driver de Vulkan", "Vulkan driver"), selection: text("vulkan_driver", \.vulkanDriver)) {
                        Text(L("KosmicKrisp · con geometry shaders", "KosmicKrisp · with geometry shaders")).tag("kosmickrisp")
                        Text(L("MoltenVK · el anterior", "MoltenVK · the previous one")).tag("moltenvk")
                    }
                    Toggle(L("Compilar shaders en segundo plano", "Compile shaders in the background"), isOn: flag("async_shaders", \.asyncShaders))
                } header: {
                    Text(L("Gráficos", "Graphics"))
                } footer: {
                    Text(L("KosmicKrisp dibuja los efectos y ambos ojos como en la consola. Si no arranca o va peor, vuelve a MoltenVK. Con los shaders en segundo plano no hay tirones: lo que aparece por primera vez tarda un instante en verse.", "KosmicKrisp draws the effects and both eyes as the console does. If it does not start or runs worse, go back to MoltenVK. With shaders in the background there are no stalls: what appears for the first time shows a moment late."))
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
