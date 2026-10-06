// SPDX-License-Identifier: GPL-2.0-or-later
//
// The logs (LogFiles.swift): a notice when the last game ended with the app, and the files to
// send.

import SwiftUI

struct LogsView: View {
    @Environment(AppModel.self) private var model
    @State private var shareFiles: [URL]?

    var body: some View {
        NavigationStack {
            List {
                if model.previousSessionCrashed {
                    Section {
                        Label("La última partida se cerró de forma inesperada. Comparte los registros para ver qué pasó.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    Button {
                        shareFiles = LogFiles.filesToShare(report: model.diagnostics.report(jit: model.jit.state))
                    } label: {
                        Label("Compartir registros", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("La comprobación, la consola de las últimas sesiones (la app, FEX y el emulador) y los registros del emulador, por AirDrop, Mail o Guardar en Archivos.")
                }
                Section("Dónde están") {
                    Label("Archivos › En mi Apple Vision Pro › AstroQuest › Registros", systemImage: "folder")
                    Label("Si la app se cierra de golpe, visionOS guarda además un informe en Ajustes › Privacidad y seguridad › Análisis y mejoras › Datos de análisis (el que empieza por «AstroQuest»).",
                          systemImage: "exclamationmark.bubble")
                        .font(.callout)
                }
            }
            .navigationTitle("Registros")
        }
        .sheet(isPresented: Binding(get: { shareFiles != nil }, set: { if !$0 { shareFiles = nil } })) {
            ShareSheet(items: shareFiles ?? [])
        }
    }
}
