// SPDX-License-Identifier: GPL-2.0-or-later
//
// What the launcher shows and does: settings, the game's folder, executable memory, the
// controller, and starting the emulator.

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    static let immersiveSpaceID = "game"

    var settings = AstroSettings.load()
    let jit = JITGate()
    var controller: PlayStationController.Status?
    var gamePath: URL?
    var coreState: AstroCoreState = AstroCoreStateIdle
    var message: String?
    var immersiveOpen = false
    /// Opens the launcher window again (it is closed while the game is shown, so that nothing
    /// but the game is in view). Kept from the launcher's environment.
    var openLauncher: OpenWindowAction?
    /// The launcher's check (Diagnostics.swift), redone when the app comes back to the front.
    var diagnostics = Diagnostics.run()

    init() {
        findGame()
        let controllers = PlayStationController.shared
        controllers.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.controller = status
            }
        }
        controllers.start()
        controller = controllers.status
    }

    /// Where the game is: the `game=` setting, else a folder with eboot.bin in the app's
    /// Documents (put there with the Files app), its "games" folder, or one level below either.
    /// The game's immersive space has closed (Digital Crown, or the system): back to the launcher.
    func immersiveEnded() {
        immersiveOpen = false
        openLauncher?(id: Self.launcherID)
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

    func findGame() {
        settings = AstroSettings.load()
        let manager = FileManager.default
        func isGame(_ url: URL) -> Bool {
            manager.fileExists(atPath: url.appendingPathComponent("eboot.bin").path)
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
        let documents = AstroSettings.documents
        var places = [documents, documents.appendingPathComponent("games")]
        for folder in [documents, documents.appendingPathComponent("games")] {
            let inside = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            places.append(contentsOf: inside.sorted { $0.lastPathComponent < $1.lastPathComponent })
        }
        // The European release the fixes are made for first, as the PC launcher prefers it.
        if let preferred = places.first(where: { $0.lastPathComponent == "CUSA12392" && isGame($0) }) {
            gamePath = preferred
            return
        }
        gamePath = places.first(where: isGame)
    }

    var canStart: Bool {
        jit.isReady && gamePath != nil && coreState == AstroCoreStateIdle
    }

    /// Starts the emulator with the game. The immersive space is opened by the view.
    func startGame() -> Bool {
        guard let gamePath, jit.isReady else {
            return false
        }
        let environment = settings.environment
        var pointers = environment.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        let result = pointers.withUnsafeMutableBufferPointer { buffer -> Int32 in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { base in
                astro_core_start(gamePath.path, base, Int32(buffer.count))
            }
        }
        if result != 0 {
            message = "El emulador no pudo arrancar (error \(result))."
            return false
        }
        coreState = astro_core_state()
        watchCore()
        return true
    }

    private func watchCore() {
        Task { @MainActor [weak self] in
            while let self {
                self.coreState = astro_core_state()
                if self.coreState == AstroCoreStateStopped {
                    self.message = "El emulador terminó (código \(astro_core_exit_code())). Su registro: \(String(cString: astro_core_log_path()))"
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
