// SPDX-License-Identifier: GPL-2.0-or-later
//
// The check (Diagnostics.swift): extra memory, address space, debugging and JIT, one row each,
// with the JIT's own steps and what to do when one of them fails.

import SwiftUI
import UIKit

struct CheckView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.diagnostics.items(jit: model.jit.state)) { item in
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: StatusStyle.symbol(item.verdict))
                                .foregroundStyle(StatusStyle.color(item.verdict))
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .font(.headline)
                                Text(item.detail)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } footer: {
                    Text(L("Si falta la memoria extra o el espacio de direcciones, depende de cómo se firmó la app (los permisos de su App ID). Si falla el JIT, depende de StikDebug.", "If the extra memory or the address space is missing, it depends on how the app was signed (its App ID's capabilities). If JIT fails, it depends on StikDebug."))
                }

                Section(L("JIT con StikDebug", "JIT with StikDebug")) {
                    jitDetail
                }

                Section(L("Juego", "Game")) {
                    if let path = model.gamePath {
                        Label(path.lastPathComponent, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(path.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label(L("No se encuentra el juego", "The game was not found"), systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                        Text(L("Copia la carpeta CUSA12392 (la que tiene eboot.bin, sce_sys y sce_module) en «En mi Apple Vision Pro › AstroQuest» con la app Archivos, por ejemplo desde una carpeta compartida de tu PC (Archivos › Conectarse a un servidor).", "Copy the CUSA12392 folder (the one with eboot.bin, sce_sys and sce_module) to “On My Apple Vision Pro › AstroQuest” with the Files app, for example from a shared folder on your PC (Files › Connect to Server)."))
                            .font(.callout)
                    }
                    Button(L("Buscar de nuevo", "Search again")) {
                        model.findGame()
                    }
                }

                Section(L("Mando", "Controller")) {
                    if let controller = model.controller {
                        Label(controller.name, systemImage: "gamecontroller.fill")
                            .foregroundStyle(controller.isPlayStation ? .green : .orange)
                        if controller.kind == .sense {
                            Text(L("Mandos PlayStation VR2 Sense: el mando del juego sigue la posición del mando derecho (o del izquierdo si el derecho no se ve). Sin cruceta ni panel táctil: el botón Create del mando izquierdo hace de panel táctil.", "PlayStation VR2 Sense controllers: the game's controller follows the right controller (or the left one when the right one is not seen). There is no D-pad or touchpad: the left controller's Create button stands in for the touchpad."))
                                .font(.callout)
                        } else if !controller.isPlayStation {
                            Text(L("No es un mando de PlayStation: faltarán el panel táctil y los sensores de movimiento con los que el juego coloca el mando.", "This is not a PlayStation controller: the touchpad and the motion sensors the game uses to place the controller will be missing."))
                                .font(.callout)
                        } else if !controller.hasMotion {
                            Text(L("El mando no informa de sus sensores de movimiento.", "The controller does not report its motion sensors."))
                                .font(.callout)
                        }
                    } else {
                        Label(L("Ningún mando conectado", "No controller connected"), systemImage: "gamecontroller")
                            .foregroundStyle(.orange)
                        Text(L("Empareja un DualSense en Ajustes › Bluetooth (mantén Crear y el botón PS hasta que parpadee la barra de luz).", "Pair a DualSense in Settings › Bluetooth (hold Create and the PS button until the light bar flashes)."))
                            .font(.callout)
                    }
                }

                Section {
                    LabeledContent("Bundle ID", value: model.diagnostics.bundleIdentifier)
                    LabeledContent("Team ID", value: model.diagnostics.teamIdentifier.isEmpty ? "—" : model.diagnostics.teamIdentifier)
                }
            }
            .navigationTitle(L("Comprobación", "Check"))
            .toolbar {
                ToolbarItemGroup(placement: .bottomOrnament) {
                    Button {
                        model.refreshDiagnostics()
                    } label: {
                        Label(L("Comprobar de nuevo", "Check again"), systemImage: "arrow.clockwise")
                    }
                    Button {
                        model.testReservation()
                    } label: {
                        Label(L("Probar reserva de 24 GB", "Test a 24 GB reservation"), systemImage: "memorychip")
                    }
                    Button {
                        UIPasteboard.general.string = model.diagnostics.report(jit: model.jit.state)
                        model.message = L("Informe copiado.", "Report copied.")
                    } label: {
                        Label(L("Copiar informe", "Copy report"), systemImage: "doc.on.doc")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var jitDetail: some View {
        switch model.jit.state {
        case .idle:
            Text(L("El emulador traduce el código del juego mientras se ejecuta, y visionOS solo lo permite con un depurador conectado: StikDebug para visionOS.", "The emulator translates the game's code as it runs, and visionOS only allows that with a debugger attached: StikDebug for visionOS."))
                .font(.callout)
            Button(L("Activar JIT con StikDebug", "Enable JIT with StikDebug")) {
                model.jit.enable(arenaMegabytes: model.settings.jitArenaMB)
            }
            if !model.jit.stikDebugInstalled {
                Text(L("StikDebug para visionOS no parece instalado: github.com/rebelancap/StikDebug-visionos", "StikDebug for visionOS does not seem to be installed: github.com/rebelancap/StikDebug-visionos"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        case .waitingForDebugger:
            Label(L("Esperando a StikDebug…", "Waiting for StikDebug…"), systemImage: "hourglass")
            Text(L("StikDebug se abre y se conecta a esta app. Vuelve aquí cuando termine.", "StikDebug opens and attaches to this app. Come back here when it is done."))
                .font(.callout)
        case .preparing:
            Label(L("Preparando la memoria ejecutable…", "Preparing executable memory…"), systemImage: "gearshape.2")
        case .ready(let megabytes):
            Label(L("JIT activo (\(megabytes) MB)", "JIT enabled (\(megabytes) MB)"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let reason):
            Label(L("JIT no activo", "JIT not enabled"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(reason)
                .font(.callout)
            Button(L("Volver a intentarlo", "Try again")) {
                model.jit.enable(arenaMegabytes: model.settings.jitArenaMB)
            }
        }
    }
}
