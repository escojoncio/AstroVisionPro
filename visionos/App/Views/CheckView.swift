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
                    Text("Si falta la memoria extra o el espacio de direcciones, depende de cómo se firmó la app (los permisos de su App ID). Si falla el JIT, depende de StikDebug.")
                }

                Section("JIT con StikDebug") {
                    jitDetail
                }

                Section {
                    LabeledContent("Bundle ID", value: model.diagnostics.bundleIdentifier)
                    LabeledContent("Team ID", value: model.diagnostics.teamIdentifier.isEmpty ? "—" : model.diagnostics.teamIdentifier)
                }
            }
            .navigationTitle("Comprobación")
            .toolbar {
                ToolbarItemGroup(placement: .bottomOrnament) {
                    Button {
                        model.refreshDiagnostics()
                    } label: {
                        Label("Comprobar de nuevo", systemImage: "arrow.clockwise")
                    }
                    Button {
                        model.testReservation()
                    } label: {
                        Label("Probar reserva de 24 GB", systemImage: "memorychip")
                    }
                    Button {
                        UIPasteboard.general.string = model.diagnostics.report(jit: model.jit.state)
                        model.message = "Informe copiado."
                    } label: {
                        Label("Copiar informe", systemImage: "doc.on.doc")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var jitDetail: some View {
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
