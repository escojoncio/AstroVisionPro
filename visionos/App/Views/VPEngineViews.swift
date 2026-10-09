// SPDX-License-Identifier: GPL-2.0-or-later
//
// The VPEngine build (scripts/vpengine-project.py): the game's code runs translated ahead of time
// instead of through FEX, so there is no JIT and no StikDebug. What the launcher shows for it: the
// engine card on the home tab (certificate, conversion, the game pack) and its section in the
// settings.

#if VPENGINE
import SwiftUI
import UniformTypeIdentifiers

/// Where the JIT card is in the FEX build: the state of the game's translated code.
struct EngineCard: View {
    @Environment(AppModel.self) private var model
    @State private var choosingCertificate = false
    @State private var certificateFile: URL?
    @State private var askingPassword = false
    @State private var password = ""

    var body: some View {
        let conversion = model.conversion
        StatusCard(title: "VPEngine", symbol: "cpu", verdict: verdict, detail: detail) {
            VStack(alignment: .leading, spacing: 8) {
                if model.certificate == nil {
                    Button(L("Importar de SideStore", "Import from SideStore")) {
                        model.importCertificateFromSideStore()
                    }
                    Button(L("Elegir .p12…", "Choose .p12…")) {
                        choosingCertificate = true
                    }
                } else if model.packLoaded == nil, let game = model.gamePath {
                    if conversion.isRunning {
                        if case .running(_, let done, let total) = conversion.state, total > 0 {
                            ProgressView(value: Double(done), total: Double(total))
                        }
                        Button(L("Pausar", "Pause")) {
                            conversion.requestStop(reason: "the player paused it")
                        }
                    } else {
                        Button(VPConversion.isStarted(game) ? L("Continuar", "Continue") : L("Convertir", "Convert")) {
                            model.convertGame()
                        }
                        if VPGamePack.packURL(in: game) != nil {
                            Button(L("Usar el del PC", "Use the PC's")) {
                                model.usePCPack()
                            }
                        }
                    }
                }
            }
        }
        .fileImporter(isPresented: $choosingCertificate, allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data, .data]) { result in
            switch result {
            case .success(let url):
                certificateFile = url
                // After the picker has finished closing: an alert asked for while it closes may
                // never show (and the flag, left on, would keep it from showing again).
                askingPassword = false
                LogFiles.log("VPEngine: certificate file chosen, asking for its password")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { askingPassword = true }
            case .failure(let error):
                model.message = error.localizedDescription
            }
        }
        // The file goes to the buttons as the alert's data: the alert clears its binding before
        // it runs a button, so a button reading certificateFile found nil and did nothing.
        .alert(L("Contraseña del certificado", "Certificate password"), isPresented: $askingPassword,
               presenting: certificateFile) { file in
            SecureField(L("Contraseña (puede estar vacía)", "Password (may be empty)"), text: $password)
            Button(L("Importar", "Import")) {
                model.importCertificate(file: file, password: password)
                password = ""
            }
            Button(L("Cancelar", "Cancel"), role: .cancel) {
                password = ""
            }
        }
    }

    private var verdict: Diagnostics.Verdict {
        if model.packLoaded != nil { return .ok }
        if model.certificate == nil { return .missing }
        switch model.conversion.state {
        case .failed: return .missing
        default: return .warning
        }
    }

    private var detail: String {
        if let pack = model.packLoaded {
            return L("Listo, sin JIT · \(pack.modules) módulos", "Ready, no JIT · \(pack.modules) modules")
        }
        guard let certificate = model.certificate else {
            return L("Falta tu certificado de SideStore", "Your SideStore certificate is missing")
        }
        switch model.conversion.state {
        case .failed(let message):
            return message
        case .running, .paused:
            return model.conversion.status
        default:
            break
        }
        guard let game = model.gamePath else {
            return L("Certificado \(certificate.team) · falta el juego", "Certificate \(certificate.team) · the game is missing")
        }
        if VPConversion.isStarted(game) {
            return L("Conversión a medias: sigue donde iba", "Conversion half done: it continues where it was")
        }
        return L("Sin convertir: la primera vez tarda unos minutos", "Not converted: the first time takes some minutes")
    }
}

/// The settings for it.
struct VPEngineSection: View {
    @Environment(AppModel.self) private var model
    @State private var choosingCertificate = false
    @State private var certificateFile: URL?
    @State private var askingPassword = false
    @State private var password = ""
    @State private var sharing = false

    var body: some View {
        Section {
            LabeledContent(L("Certificado", "Certificate")) {
                if let c = model.certificate {
                    Text("\(c.commonName) · \(c.team)")
                        .foregroundStyle(model.appTeam.isEmpty || model.appTeam == c.team ? Color.secondary : Color.red)
                } else {
                    Text(L("Ninguno", "None")).foregroundStyle(.secondary)
                }
            }
            if !model.appTeam.isEmpty, let c = model.certificate, c.team != model.appTeam {
                Text(L("La app está firmada por el equipo \(model.appTeam): importa el certificado de ese equipo.", "The app is signed by team \(model.appTeam): import that team's certificate."))
                    .foregroundStyle(.red)
            }
            // What the last import (or conversion step) said: also here, not only on the home tab.
            if let message = model.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            Button(L("Importar de SideStore", "Import from SideStore")) {
                model.importCertificateFromSideStore()
            }
            Button(L("Elegir un certificado (.p12)…", "Choose a certificate (.p12)…")) {
                choosingCertificate = true
            }
            LabeledContent(L("Piezas a la vez", "Pieces at once")) {
                Stepper("\(model.conversion.jobs)", value: Binding(
                    get: { model.conversion.jobs }, set: { model.conversion.jobs = $0 }), in: 1...8)
            }
            if let game = model.gamePath, VPConversion.isStarted(game) || VPConversion.isConverted(game) {
                Button(L("Convertir otra vez desde cero", "Convert again from scratch"), role: .destructive) {
                    model.resetConversion()
                }
                .disabled(model.conversion.isRunning)
            }
            Button(L("Compartir conversion.log", "Share conversion.log")) {
                sharing = true
            }
            .disabled(!FileManager.default.fileExists(atPath: ConversionLog.shared.url.path))
        } header: {
            Text("VPEngine")
        } footer: {
            Text(L("El juego se convierte una vez en el visor (traducido y compilado para su procesador) y se firma con tu certificado de SideStore: luego arranca sin JIT ni StikDebug. Con el visor quitado y cargando, visionOS puede ir avanzando la conversión a ratos; conversion.log, en Archivos, dice cuánto. Más piezas a la vez va más rápido mientras no falte memoria.",
                   "The game is converted once on the headset (translated and compiled for its processor) and signed with your SideStore certificate: then it starts with no JIT or StikDebug. With the headset off and charging, visionOS may move the conversion on now and then; conversion.log, in Files, says how much. More pieces at once is faster while memory lasts."))
        }
        .fileImporter(isPresented: $choosingCertificate, allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data, .data]) { result in
            switch result {
            case .success(let url):
                certificateFile = url
                // After the picker has finished closing: an alert asked for while it closes may
                // never show (and the flag, left on, would keep it from showing again).
                askingPassword = false
                LogFiles.log("VPEngine: certificate file chosen, asking for its password")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { askingPassword = true }
            case .failure(let error):
                model.message = error.localizedDescription
            }
        }
        // The file goes to the buttons as the alert's data: the alert clears its binding before
        // it runs a button, so a button reading certificateFile found nil and did nothing.
        .alert(L("Contraseña del certificado", "Certificate password"), isPresented: $askingPassword,
               presenting: certificateFile) { file in
            SecureField(L("Contraseña (puede estar vacía)", "Password (may be empty)"), text: $password)
            Button(L("Importar", "Import")) {
                model.importCertificate(file: file, password: password)
                password = ""
            }
            Button(L("Cancelar", "Cancel"), role: .cancel) {
                password = ""
            }
        }
        .sheet(isPresented: $sharing) {
            ShareSheet(items: [ConversionLog.shared.url])
        }
    }
}
#endif
