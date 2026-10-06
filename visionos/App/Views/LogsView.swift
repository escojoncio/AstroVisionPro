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
                        Label(L("La última partida se cerró de forma inesperada. Comparte los registros para ver qué pasó.", "The last game closed unexpectedly. Share the logs to see what happened."),
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    Button {
                        shareFiles = LogFiles.filesToShare(report: model.diagnostics.report(jit: model.jit.state))
                    } label: {
                        Label(L("Compartir registros", "Share logs"), systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text(L("La comprobación, la consola de las últimas sesiones (la app, FEX y el emulador) y los registros del emulador, por AirDrop, Mail o Guardar en Archivos.", "The check, the console of the last sessions (the app, FEX and the emulator) and the emulator's logs, by AirDrop, Mail or Save to Files."))
                }
                Section(L("Dónde están", "Where they are")) {
                    Label(L("Archivos › En mi Apple Vision Pro › AstroQuest › Registros", "Files › On My Apple Vision Pro › AstroQuest › Registros"), systemImage: "folder")
                    Label(L("Si la app se cierra de golpe, visionOS guarda además un informe en Ajustes › Privacidad y seguridad › Análisis y mejoras › Datos de análisis (el que empieza por «AstroQuest»).", "If the app closes suddenly, visionOS also keeps a report in Settings › Privacy & Security › Analytics & Improvements › Analytics Data (the one starting with “AstroQuest”)."),
                          systemImage: "exclamationmark.bubble")
                        .font(.callout)
                }
            }
            .navigationTitle(L("Registros", "Logs"))
        }
        .sheet(isPresented: Binding(get: { shareFiles != nil }, set: { if !$0 { shareFiles = nil } })) {
            ShareSheet(items: shareFiles ?? [])
        }
    }
}
