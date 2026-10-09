// SPDX-License-Identifier: GPL-2.0-or-later
//
// What the launcher shows and does: settings, the game's folder, executable memory, the
// controller, and starting the emulator.

import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class AppModel {
    /// First of all: this session's console log (LogFiles.swift), so that everything after is in it.
    private let logsStarted: Bool = {
        LogFiles.begin()
        return true
    }()
    /// The previous game ended with the app (a crash, or the emulator ending the process).
    let previousSessionCrashed = LogFiles.previousSessionEndedUnexpectedly != nil
    static let immersiveSpaceID = "game"

    var settings = AstroSettings.load()
    let jit = JITGate()
    var controller: PlayStationController.Status?
    var gamePath: URL? {
        didSet {
            if gamePath != oldValue {
                gameLanguageCodes = GameLanguages.codesInFiles(gamePath: gamePath)
            }
        }
    }
    /// The language codes in the game's files (GameLanguages.swift), read when the game is found.
    var gameLanguageCodes: [String] = []
    /// The VPS4 folder (GameFolder.swift), once chosen and reachable.
    var gameFolder: URL?
    var coreState: AstroCoreState = AstroCoreStateIdle
    var message: String?
    var immersiveOpen = false
    /// Opens the launcher window again (it is closed while the game is shown, so that nothing
    /// but the game is in view). Kept from the launcher's environment.
    var openLauncher: OpenWindowAction?
    /// The launcher was closed when the game's space opened (settings «close_launcher»): only
    /// then is it opened again when the space closes, or there would be two.
    var launcherClosed = false
    /// The launcher's check (Diagnostics.swift), redone when the app comes back to the front.
    var diagnostics = Diagnostics.run()

#if VPENGINE
    /// The game's code translated ahead of time (VPEngine): converted on the headset or made on
    /// a PC, signed with the player's SideStore certificate and loaded. No JIT.
    let conversion = VPConversion.shared
    var certificate: VPCertificate.Summary? = VPCertificate.current
    var packLoaded: VPGamePack.Loaded?
    /// The team SideStore signed this app with (a pack must be signed by the same).
    let appTeam: String = {
        guard let path = Bundle.main.executablePath else { return "" }
        var out = [CChar](repeating: 0, count: 64)
        return vp_codesign_file_team(path, &out, out.count) == 0 ? String(cString: out) : ""
    }()

    var engineReady: Bool { packLoaded != nil }

    func importCertificateFromSideStore() {
        guard let url = VPCertificate.sideStoreImportURL else { return }
        LogFiles.log("VPEngine: asking SideStore for the certificate")
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            if !opened {
                Task { @MainActor in
                    self?.message = L("No se pudo abrir SideStore. Elige el certificado (.p12) a mano en Ajustes.", "SideStore could not be opened. Choose the certificate (.p12) by hand in Settings.")
                }
            }
        }
    }

    /// A URL the app was opened with: SideStore's answer with the certificate.
    func handleOpenURL(_ url: URL) {
        // Every URL the app is opened with, without the values (a certificate and its password):
        // whether SideStore answers at all, and in what shape.
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = (parts?.queryItems ?? []).map { "\($0.name)(\($0.value?.count ?? -1) chars)" }
        LogFiles.log("VPEngine: opened with a URL: scheme \(url.scheme ?? "-"), host \(url.host ?? "-"), path of \(url.path.count) chars, parameters [\(items.joined(separator: ", "))], \(url.absoluteString.count) chars")
        guard let result = VPCertificate.handle(url: url) else {
            LogFiles.log("VPEngine: that URL is not a certificate from SideStore")
            return
        }
        switch result {
        case .success(let summary):
            certificate = summary
            message = L("Certificado importado: \(summary.commonName) (\(summary.team)).", "Certificate imported: \(summary.commonName) (\(summary.team)).")
            LogFiles.log("VPEngine: certificate imported from SideStore, team \(summary.team)")
            loadEngineIfReady()
        case .failure(let error):
            message = error.localizedDescription
            LogFiles.log("VPEngine: certificate import failed: \(error.localizedDescription)")
        }
    }

    func importCertificate(file: URL, password: String) {
        let accessing = file.startAccessingSecurityScopedResource()
        defer { if accessing { file.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: file)
            LogFiles.log("VPEngine: certificate file \(file.lastPathComponent), \(data.count) bytes, password \(password.isEmpty ? "empty" : "given")")
            let summary = try VPCertificate.store(p12: data, password: password)
            certificate = summary
            message = L("Certificado importado: \(summary.commonName) (\(summary.team)).", "Certificate imported: \(summary.commonName) (\(summary.team)).")
            LogFiles.log("VPEngine: certificate imported from a file, team \(summary.team); the app's team \(appTeam.isEmpty ? "unknown" : appTeam)")
            loadEngineIfReady()
        } catch {
            message = error.localizedDescription
            LogFiles.log("VPEngine: certificate file import failed: \(error.localizedDescription)")
        }
    }

    func convertGame() {
        guard let gamePath else { return }
        message = nil
        conversion.start(game: gamePath, reason: "the player pressed Convert")
    }

    func usePCPack() {
        guard let gamePath else { return }
        message = L("Firmando y cargando el paquete del PC…", "Signing and loading the PC's pack…")
        Thread.detachNewThread {
            let result = Result { try VPGamePack.load(gameFolder: gamePath) }
            Task { @MainActor [weak self] in
                switch result {
                case .success(let loaded):
                    self?.packLoaded = loaded
                    self?.message = L("Paquete del PC cargado: \(loaded.modules) módulos.", "PC pack loaded: \(loaded.modules) modules.")
                case .failure(let error):
                    self?.message = error.localizedDescription
                }
            }
        }
    }

    func resetConversion() {
        guard let gamePath, !conversion.isRunning else { return }
        VPConversion.reset(gamePath)
        message = packLoaded != nil
            ? L("Conversión borrada. Reinicia la app para convertir de nuevo.", "Conversion deleted. Restart the app to convert again.")
            : L("Conversión borrada.", "Conversion deleted.")
    }

    /// A game converted before (or a pack from the PC) is loaded as soon as the app starts.
    private func loadEngineIfReady() {
        guard certificate != nil, packLoaded == nil, let gamePath else { return }
        if VPConversion.isConverted(gamePath) {
            conversion.start(game: gamePath, reason: "app start: the game was converted before")
        }
    }
#endif

    init() {
#if VPENGINE
        VPGamePack.log = { LogFiles.log($0) }
        conversion.resolveGame = { [weak self] in self?.gamePath }
        conversion.onFinished = { [weak self] loaded in self?.packLoaded = loaded }
        packLoaded = VPGamePack.alreadyLoaded()
#endif
        // Files copied in read-only or locked could not be deleted from the Files app
        // (error -5000): the app gives itself back the right to change everything in its folder.
        Task.detached {
            let changed = Storage.unlock()
            if changed > 0 {
                LogFiles.log("Unlocked \(changed) files and folders in the app's folder")
            }
        }
        findGame()
        let controllers = PlayStationController.shared
        controllers.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.controller = status
            }
        }
        controllers.start()
        controller = controllers.status
#if VPENGINE
        LogFiles.log("VPEngine build: app signed by team \(appTeam.isEmpty ? "?" : appTeam), certificate \(certificate?.team ?? "none")")
        loadEngineIfReady()
#endif
    }

    /// Where the game is: the `game=` setting, else a folder with eboot.bin in the app's
    /// Documents (put there with the Files app), its "games" folder, or one level below either.
    /// The game's immersive space has closed (Digital Crown, or the system): back to the launcher.
    func immersiveEnded() {
        LogFiles.log("Immersive space closed")
        immersiveOpen = false
        if launcherClosed {
            launcherClosed = false
            openLauncher?(id: Self.launcherID)
        }
    }

    static let launcherID = "launcher"

    func refreshDiagnostics() {
        let tested = diagnostics.canReserveNeeded
        diagnostics = Diagnostics.run()
        diagnostics.canReserveNeeded = tested
    }

    /// Reserves the emulator's 24 GB of address space once and gives it back.
    func testReservation() {
        diagnostics.canReserveNeeded = astro_diag_can_reserve_gb(Diagnostics.neededAddressSpaceGB)
    }

    /// What the folder picker gave back when asked for the VPS4 folder.
    func folderChosen(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            switch GameFolder.choose(url) {
            case .chosen(let folder):
                gameFolder = folder
                findGame()
                message = gamePath != nil
                    ? L("Carpeta VPS4 lista: \(gamePath!.lastPathComponent).", "VPS4 folder ready: \(gamePath!.lastPathComponent).")
                    : L("Carpeta VPS4 lista. Mete el juego en VPS4 › Juegos.", "VPS4 folder ready. Put the game in VPS4 › Juegos.")
            case .wrongName(let name):
                message = L("Esa carpeta se llama «\(name)»: elige la que se llama VPS4.", "That folder is called “\(name)”: choose the one called VPS4.")
            case .failed(let reason):
                message = reason
            }
        case .failure(let error):
            message = L("No se pudo elegir la carpeta: \(error.localizedDescription)", "The folder could not be chosen: \(error.localizedDescription)")
        }
    }

    func findGame() {
        settings = AstroSettings.load()
        gameFolder = GameFolder.url()
        let manager = FileManager.default
        func isGame(_ url: URL) -> Bool {
            // What the emulator starts is eboot.bin (sce_sys is checked in the Check tab).
            manager.fileExists(atPath: url.appendingPathComponent("eboot.bin").path)
        }
        func preferred(_ url: URL) -> Bool {
            url.lastPathComponent.caseInsensitiveCompare("CUSA12392") == .orderedSame
        }
        if !settings.game.isEmpty {
            var url = URL(fileURLWithPath: settings.game)
            if url.lastPathComponent == "eboot.bin" {
                url.deleteLastPathComponent()
            }
            if isGame(url) {
                gamePath = url
                return
            }
        }
        // The VPS4 folder first (GameFolder.swift): its Juegos folder, and the folder itself.
        if let root = GameFolder.url() {
            var places: [URL] = []
            for folder in [root.appendingPathComponent("Juegos"), root] {
                let inside = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                places.append(contentsOf: inside.sorted { $0.lastPathComponent < $1.lastPathComponent })
            }
            if let found = places.first(where: { preferred($0) && isGame($0) }) ?? places.first(where: isGame) {
                gamePath = found
                return
            }
        }
        let documents = AstroSettings.documents
        var places = [documents, documents.appendingPathComponent("games")]
        for folder in [documents, documents.appendingPathComponent("games")] {
            let inside = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            places.append(contentsOf: inside.sorted { $0.lastPathComponent < $1.lastPathComponent })
        }
        // The European release the fixes are made for first, as the PC launcher prefers it.
        if let found = places.first(where: { preferred($0) && isGame($0) }) {
            gamePath = found
            return
        }
        gamePath = places.first(where: isGame)
    }

    var canStart: Bool {
#if VPENGINE
        engineReady && gamePath != nil && coreState == AstroCoreStateIdle
#else
        jit.isReady && gamePath != nil && coreState == AstroCoreStateIdle
#endif
    }

    /// Starts the emulator with the game. The immersive space is opened by the view.
    func startGame() -> Bool {
#if VPENGINE
        guard let gamePath, engineReady else {
            return false
        }
#else
        guard let gamePath, jit.isReady else {
            return false
        }
#endif
        let environment = settings.environment
        var pointers = environment.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        let result = pointers.withUnsafeMutableBufferPointer { buffer -> Int32 in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { base in
                astro_core_start(gamePath.path, base, Int32(buffer.count))
            }
        }
        if result != 0 {
            message = L("El emulador no pudo arrancar (error \(result)).", "The emulator could not start (error \(result)).")
            return false
        }
        coreState = astro_core_state()
        LogFiles.gameStarted()
        LogFiles.log("Game started: \(gamePath.path)")
        LogFiles.log("Settings: \(environment.joined(separator: " "))")
        let codes = gameLanguageCodes
        LogFiles.log("Game language: \(GameLanguages.tag(for: settings.gameLanguage)); language files in the game: \(codes.isEmpty ? "none found" : codes.joined(separator: " "))")
        watchCore()
        return true
    }

    private func watchCore() {
        Task { @MainActor [weak self] in
            while let self {
                self.coreState = astro_core_state()
                if self.coreState == AstroCoreStateStopped {
                    LogFiles.gameStopped()
                    LogFiles.log("The emulator ended with code \(astro_core_exit_code())")
                    self.message = L("El emulador terminó (código \(astro_core_exit_code())). Su registro: \(String(cString: astro_core_log_path()))", "The emulator ended (code \(astro_core_exit_code())). Its log: \(String(cString: astro_core_log_path()))")
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
