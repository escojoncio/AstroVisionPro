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
                    Picker("Resolución por ojo", selection: text("resolution", \.resolution)) {
                        Text("2880 · PC VR").tag("2880")
                        Text("2160").tag("2160")
                        Text("1440 · consola").tag("1440")
                        Text("La que elija el juego").tag("game")
                    }
                    Toggle("Resolución dinámica", isOn: flag("dynamic", \.dynamic))
                    Picker("Imágenes por segundo", selection: number("fps", \.fps)) {
                        Text("60").tag(60)
                        Text("45").tag(45)
                        Text("30").tag(30)
                    }
                    LabeledContent("Campo de visión") {
                        Stepper("\(model.settings.fov) %", value: number("fov", \.fov), in: 70...100, step: 5)
                    }
                    LabeledContent("Nitidez") {
                        HStack {
                            Slider(value: sharpen, in: 0...1, step: 0.1)
                                .frame(width: 240)
                            Text(model.settings.sharpen)
                                .monospacedDigit()
                                .frame(width: 40)
                        }
                    }
                } header: {
                    Text("Imagen")
                } footer: {
                    Text("Los valores por defecto son los de la versión de PC VR.")
                }

                Section {
                    Toggle("Renderizado foveado", isOn: flag("foveation", \.foveation))
                    LabeledContent("Calidad de renderizado") {
                        HStack {
                            Slider(value: renderQuality, in: 0.1...1, step: 0.05)
                                .frame(width: 240)
                            Text(String(format: "%.2f", model.settings.renderQuality))
                                .monospacedDigit()
                                .frame(width: 48)
                        }
                    }
                    LabeledContent("Predicción de la cabeza") {
                        Stepper("\(model.settings.predictMs) ms", value: number("predict_ms", \.predictMs), in: 0...80, step: 5)
                    }
                } header: {
                    Text("Visor")
                }

                Section {
                    Toggle("Colocar el mando con las manos", isOn: flag("hands", \.hands))
                    Toggle("Ver mis manos durante el juego", isOn: flag("show_hands", \.showHands))
                    Toggle("Pausar al quitarse el visor", isOn: flag("pause", \.pause))
                } header: {
                    Text("Mando y manos")
                }

                Section {
                    Picker("Memoria ejecutable", selection: number("jit_arena_mb", \.jitArenaMB)) {
                        Text("256 MB").tag(256)
                        Text("512 MB").tag(512)
                        Text("1024 MB").tag(1024)
                    }
                } header: {
                    Text("JIT")
                } footer: {
                    Text("Los cambios se aplican la próxima vez que empieces el juego. El resto de ajustes están en settings.txt, en la carpeta de AstroQuest de la app Archivos.")
                }
            }
            .navigationTitle("Ajustes")
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
