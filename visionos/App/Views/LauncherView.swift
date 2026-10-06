// SPDX-License-Identifier: GPL-2.0-or-later
//
// The launcher: what is needed before the game can start, one line each, and the button that
// starts it.

import SwiftUI
import UIKit

struct LauncherView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("ASTRO BOT Rescue Mission en Apple Vision Pro, con tu propia copia del juego (CUSA12392, versión 1.00) y un mando de PlayStation.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(model.diagnostics.items(jit: model.jit.state)) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(item.title, systemImage: symbol(item.verdict))
                                .foregroundStyle(color(item.verdict))
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Bundle ID", value: model.diagnostics.bundleIdentifier)
                        .font(.caption)
                    HStack {
                        Button("Comprobar de nuevo") {
                            model.refreshDiagnostics()
                        }
                        Spacer()
                        Button("Probar reserva de 24 GB") {
                            model.testReservation()
                        }
                        Spacer()
                        Button("Copiar informe") {
                            UIPasteboard.general.string = model.diagnostics.report(jit: model.jit.state)
                            model.message = "Informe copiado."
                        }
                    }
                } header: {
                    Text("Comprobación")
                } footer: {
                    Text("Si falta la memoria extra o el espacio de direcciones, es la forma de instalar la app (los permisos de su App ID); si falla el JIT, es StikDebug.")
                }

                Section("1. Memoria ejecutable (JIT)") {
                    jitRow
                }

                Section("2. El juego") {
                    if let path = model.gamePath {
                        Label(path.lastPathComponent, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(path.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("No se encuentra el juego", systemImage: "xmark.circle")
                            .foregroundStyle(.orange)
                        Text("Copia la carpeta CUSA12392 (la que tiene eboot.bin, sce_sys y sce_module) en «En mi Apple Vision Pro › AstroQuest» con la app Archivos, por ejemplo desde una carpeta compartida de tu PC (Archivos › Conectarse a un servidor).")
                            .font(.callout)
                    }
                    Button("Buscar de nuevo") {
                        model.findGame()
                    }
                }

                Section("3. El mando") {
                    if let controller = model.controller {
                        Label(controller.name, systemImage: "gamecontroller.fill")
                            .foregroundStyle(controller.isPlayStation ? .green : .orange)
                        if controller.kind == .sense {
                            Text("Mandos PlayStation VR2 Sense: el mando del juego sigue la posición del mando derecho (o del izquierdo si el derecho no se ve). Sin cruceta ni panel táctil: el botón Create del mando izquierdo hace de panel táctil.")
                                .font(.callout)
                        } else if !controller.isPlayStation {
                            Text("No es un mando de PlayStation: faltarán el panel táctil y los sensores de movimiento con los que el juego coloca el mando.")
                                .font(.callout)
                        } else if !controller.hasMotion {
                            Text("El mando no informa de sus sensores de movimiento.")
                                .font(.callout)
                        }
                    } else {
                        Label("Ningún mando conectado", systemImage: "gamecontroller")
                            .foregroundStyle(.orange)
                        Text("Empareja un DualSense en Ajustes › Bluetooth (mantén Crear y el botón PS hasta que parpadee la barra de luz).")
                            .font(.callout)
                    }
                }

                Section("Ajustes") {
                    LabeledContent("Resolución por ojo", value: model.settings.resolution == "game" ? "la del juego" : "\(model.settings.resolution) (PC VR)")
                    LabeledContent("Imágenes por segundo", value: "\(model.settings.fps) como máximo")
                    LabeledContent("Renderizado foveado", value: model.settings.foveation ? "activado" : "desactivado")
                    LabeledContent("Calidad de renderizado", value: String(format: "%.2f", model.settings.renderQuality))
                    Text("Se cambian en settings.txt, en la carpeta de la app (app Archivos).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        Task {
                            if model.startGame() {
                                switch await openImmersiveSpace(id: AppModel.immersiveSpaceID) {
                                case .opened:
                                    model.immersiveOpen = true
                                    // Only the game in view: the launcher comes back when the
                                    // game's space closes.
                                    dismissWindow(id: AppModel.launcherID)
                                default:
                                    model.message = "No se pudo abrir el espacio inmersivo."
                                }
                            }
                        }
                    } label: {
                        Label("Jugar", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!model.canStart)
                    .buttonStyle(.borderedProminent)

                    if model.coreState != AstroCoreStateIdle && !model.immersiveOpen {
                        Button("Volver al juego") {
                            Task {
                                if case .opened = await openImmersiveSpace(id: AppModel.immersiveSpaceID) {
                                    model.immersiveOpen = true
                                    dismissWindow(id: AppModel.launcherID)
                                }
                            }
                        }
                    }
                    if let message = model.message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("AstroQuest")
        }
        .onAppear {
            model.openLauncher = openWindow
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.findGame()
                model.refreshDiagnostics()
            }
        }
    }

    private func symbol(_ verdict: Diagnostics.Verdict) -> String {
        switch verdict {
        case .ok: "checkmark.circle.fill"
        case .warning: "questionmark.circle"
        case .missing: "xmark.octagon.fill"
        }
    }

    private func color(_ verdict: Diagnostics.Verdict) -> Color {
        switch verdict {
        case .ok: .green
        case .warning: .orange
        case .missing: .red
        }
    }

    @ViewBuilder
    private var jitRow: some View {
        switch model.jit.state {
        case .idle:
            Text("El emulador traduce el código del juego mientras se ejecuta, y visionOS solo lo permite con un depurador conectado: StikDebug para visionOS.")
                .font(.callout)
            Button("Activar JIT con StikDebug") {
                model.jit.enable(arenaMegabytes: model.settings.jitArenaMB)
            }
            if !model.jit.stikDebugInstalled {
                Text("StikDebug para visionOS no parece instalado: github.com/rebelancap/StikDebug-visionos")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        case .waitingForDebugger:
            Label("Esperando a StikDebug…", systemImage: "hourglass")
            Text("StikDebug se abre y se conecta a esta app. Vuelve aquí cuando termine.")
                .font(.callout)
        case .preparing:
            Label("Preparando la memoria ejecutable…", systemImage: "gearshape.2")
        case .ready(let megabytes):
            Label("JIT activo (\(megabytes) MB)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let reason):
            Label("JIT no activo", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(reason)
                .font(.callout)
            Button("Volver a intentarlo") {
                model.jit.enable(arenaMegabytes: model.settings.jitArenaMB)
            }
        }
    }
}
