// SPDX-License-Identifier: GPL-2.0-or-later
//
// Executable memory for the emulator (FEX translates the game's x86-64 code into ARM64 code
// that has to run), which visionOS only lets a process have through a debugger: StikDebug
// for visionOS (https://github.com/rebelancap/StikDebug-visionos). The app checks whether a
// debugger is attached, asks StikDebug to attach through its URL scheme when it is not, and
// once it is, asks it for the memory (JIT26PrepareRegion) and lets it go (JIT26Detach) - see
// shadps4-arm64-main/src/platform/visionos/jit_arena.c.

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class JITGate {
    enum State: Equatable {
        /// Nobody asked yet.
        case idle
        /// StikDebug was asked to attach; waiting for it.
        case waitingForDebugger
        /// Attached: the memory is being prepared.
        case preparing
        /// There is executable memory, and code written to it runs.
        case ready(megabytes: Int)
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet {
            LogFiles.log("JIT: \(state)")
        }
    }
    private var polling: Task<Void, Never>?

    /// A self-test that never came back means the memory was not executable after all: the
    /// system ended the app on the spot.
    nonisolated private static var crashMarker: URL {
        AstroSettings.documents.appendingPathComponent(".jit-self-test")
    }

    var isReady: Bool {
        if case .ready = state {
            return true
        }
        return false
    }

    init() {
        if FileManager.default.fileExists(atPath: Self.crashMarker.path) {
            try? FileManager.default.removeItem(at: Self.crashMarker)
            state = .failed(L("La última prueba de JIT cerró la app: la memoria no se pudo ejecutar. Comprueba que StikDebug usa el script universal.js y que su VPN y su emparejamiento funcionan.", "The last JIT test closed the app: the memory could not be executed. Check that StikDebug uses the universal.js script and that its VPN and pairing work."))
        }
    }

    /// Whether StikDebug is installed (its URL scheme answers).
    var stikDebugInstalled: Bool {
        guard let url = URL(string: "stikjit://") else {
            return false
        }
        return UIApplication.shared.canOpenURL(url)
    }

    /// Checks for a debugger, asks StikDebug for one if there is none, and prepares the memory.
    func enable(arenaMegabytes: Int) {
        if isReady {
            return
        }
        if astro_jit_process_is_debugged() {
            prepare(arenaMegabytes: arenaMegabytes)
            return
        }
        guard let url = Self.stikDebugURL() else {
            state = .failed(L("No se pudo formar el enlace para StikDebug.", "The link for StikDebug could not be made."))
            return
        }
        state = .waitingForDebugger
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            Task { @MainActor in
                guard let self else { return }
                if !opened {
                    self.state = .failed(L("No se pudo abrir StikDebug. Instálalo (StikDebug para visionOS) y vuelve a intentarlo.", "StikDebug could not be opened. Install it (StikDebug for visionOS) and try again."))
                    return
                }
                self.waitForDebugger(arenaMegabytes: arenaMegabytes)
            }
        }
    }

    /// stikjit://enable-jit?bundle-id=...&pid=...&script-name=universal.js. The script has to be
    /// named: StikDebug only picks one by itself for the apps it knows, and without it the
    /// debugger attaches and lets go at once, with nobody to answer brk #0xf00d.
    static func stikDebugURL() -> URL? {
        var components = URLComponents()
        components.scheme = "stikjit"
        components.host = "enable-jit"
        components.queryItems = [
            URLQueryItem(name: "bundle-id", value: Bundle.main.bundleIdentifier ?? "com.astroquest.visionpro"),
            URLQueryItem(name: "pid", value: String(getpid())),
            URLQueryItem(name: "script-name", value: "universal.js"),
        ]
        return components.url
    }

    private func waitForDebugger(arenaMegabytes: Int) {
        polling?.cancel()
        polling = Task { @MainActor [weak self] in
            // StikDebug names a stalled handshake after 20 s and gives a script 120 s.
            let deadline = Date().addingTimeInterval(120)
            while !Task.isCancelled, Date() < deadline {
                if astro_jit_process_is_debugged() {
                    self?.prepare(arenaMegabytes: arenaMegabytes)
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            if let self, case .waitingForDebugger = self.state {
                self.state = .failed(L("StikDebug no se conectó en dos minutos. Abre StikDebug, comprueba que el túnel está conectado (Ajustes → Tunnel Diagnostics) y vuelve a intentarlo.", "StikDebug did not attach within two minutes. Open StikDebug, check that the tunnel is connected (Settings → Tunnel Diagnostics) and try again."))
            }
        }
    }

    private func prepare(arenaMegabytes: Int) {
        state = .preparing
        let bytes = arenaMegabytes << 20
        let marker = Self.crashMarker.path
        // The brk stops this thread until the debugger has done its part: not the main thread.
        Thread.detachNewThread { [weak self] in
            let prepared = astro_jit_prepare_arena(bytes)
            var result: State
            if prepared != 0 {
                result = .failed(L("StikDebug no preparó la memoria ejecutable (error \(prepared)).", "StikDebug did not prepare the executable memory (error \(prepared))."))
            } else {
                // If the memory cannot run code after all, the system ends the app right here:
                // the marker tells the next start.
                FileManager.default.createFile(atPath: marker, contents: nil)
                let tested = astro_jit_self_test()
                try? FileManager.default.removeItem(atPath: marker)
                result = tested == 0
                    ? .ready(megabytes: arenaMegabytes)
                    : .failed(L("La memoria ejecutable no respondió a la prueba (error \(tested)).", "The executable memory failed the test (error \(tested))."))
            }
            Task { @MainActor in
                self?.state = result
            }
        }
    }
}
