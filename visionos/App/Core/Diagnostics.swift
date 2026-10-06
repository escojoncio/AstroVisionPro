// SPDX-License-Identifier: GPL-2.0-or-later
//
// The launcher's check: whether this copy of the app got what the emulator needs from the way
// it was signed and installed, one thing at a time, so that it is clear which one is missing.
//
//   - Extra memory: the increased-memory-limit entitlement, and how much memory the system
//     really lets the app use (the PlayStation 4 has 8 GB).
//   - Address space: the extended-virtual-addressing entitlement, and how much address space
//     the app can really reserve (the emulator lays the console's 24 GB out in it).
//   - JIT: get-task-allow (without it StikDebug cannot attach), whether a debugger is attached,
//     and the JIT test itself (JITGate).

import Foundation

struct Diagnostics {
    enum Verdict {
        case ok, warning, missing
    }

    struct Item: Identifiable {
        let id: String
        let title: String
        let verdict: Verdict
        let detail: String
    }

    /// What the emulator lays out: 4 GB managed by the system, 4 GB reserved, 16 GB for the game.
    static let neededAddressSpaceGB: UInt32 = 24
    /// Below this, the game and the PC VR resolution are not going to fit.
    static let neededMemoryGB = 6.0

    let bundleIdentifier: String
    let teamIdentifier: String
    let entitlements: [String: Any]
    let entitlementsReadable: Bool
    let availableMemoryGB: Double
    let largestReservationGB: UInt32
    let debuggerAttached: Bool

    static func run() -> Diagnostics {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let length = buffer.withUnsafeMutableBytes { raw in
            astro_diag_entitlements(raw.baseAddress, UInt32(raw.count))
        }
        var entitlements: [String: Any] = [:]
        if length > 0,
           let parsed = try? PropertyListSerialization.propertyList(
               from: Data(buffer[0..<Int(length)]), options: [], format: nil) as? [String: Any] {
            entitlements = parsed
        }
        var team = entitlements["com.apple.developer.team-identifier"] as? String ?? ""
        if team.isEmpty, let applicationID = entitlements["application-identifier"] as? String,
           let dot = applicationID.firstIndex(of: ".") {
            team = String(applicationID[..<dot])
        }
        return Diagnostics(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "?",
            teamIdentifier: team,
            entitlements: entitlements,
            entitlementsReadable: !entitlements.isEmpty,
            availableMemoryGB: Double(astro_diag_available_memory()) / 1_073_741_824,
            largestReservationGB: astro_diag_largest_reservation_gb(64),
            debuggerAttached: astro_jit_process_is_debugged())
    }

    private func has(_ key: String) -> Bool {
        (entitlements[key] as? Bool) == true
    }

    func items(jit: JITGate.State) -> [Item] {
        var items: [Item] = []
        let gb = String(format: "%.1f GB", availableMemoryGB)

        // Extra memory.
        let increased = has("com.apple.developer.kernel.increased-memory-limit")
        let memoryVerdict: Verdict = availableMemoryGB >= Self.neededMemoryGB ? .ok
            : (increased ? .warning : .missing)
        items.append(Item(
            id: "memory", title: "Memoria extra (increased-memory-limit)",
            verdict: memoryVerdict,
            detail: (entitlementsReadable
                     ? (increased ? "Firmada con el permiso. " : "La firma NO incluye el permiso. ")
                     : "")
                + "Memoria que la app puede usar ahora: \(gb) (hacen falta unos \(Int(Self.neededMemoryGB)) GB)."))

        // Address space.
        let extended = has("com.apple.developer.kernel.extended-virtual-addressing")
        let spaceVerdict: Verdict = largestReservationGB >= Self.neededAddressSpaceGB ? .ok : .missing
        items.append(Item(
            id: "address", title: "Espacio de direcciones (extended-virtual-addressing)",
            verdict: spaceVerdict,
            detail: (entitlementsReadable
                     ? (extended ? "Firmada con el permiso. " : "La firma NO incluye el permiso. ")
                     : "")
                + "La app puede reservar \(largestReservationGB) GB seguidos (el emulador necesita \(Self.neededAddressSpaceGB) GB)."))

        // JIT.
        let taskAllow = has("get-task-allow")
        items.append(Item(
            id: "debuggable", title: "Se puede depurar (get-task-allow)",
            verdict: taskAllow || !entitlementsReadable ? (taskAllow ? .ok : .warning) : .missing,
            detail: taskAllow ? "StikDebug podrá conectarse a la app."
                : (entitlementsReadable ? "Sin este permiso StikDebug no puede conectarse: vuelve a instalarla con una herramienta que lo conserve."
                   : "No se pudo leer la firma.")))
        let jitVerdict: Verdict
        let jitDetail: String
        switch jit {
        case .ready(let megabytes):
            jitVerdict = .ok
            jitDetail = "JIT activo: \(megabytes) MB de memoria ejecutable, y la prueba de ejecutar código ha funcionado."
        case .failed(let reason):
            jitVerdict = .missing
            jitDetail = reason
        case .waitingForDebugger, .preparing:
            jitVerdict = .warning
            jitDetail = "En curso…"
        case .idle:
            jitVerdict = .warning
            jitDetail = debuggerAttached
                ? "Hay un depurador conectado; pulsa «Activar JIT con StikDebug» para probarlo."
                : "Aún sin probar: pulsa «Activar JIT con StikDebug»."
        }
        items.append(Item(id: "jit", title: "JIT (StikDebug)", verdict: jitVerdict, detail: jitDetail))
        return items
    }

    /// The whole check as text, to copy and send.
    func report(jit: JITGate.State) -> String {
        var lines = ["AstroQuest para Vision Pro: comprobación",
                     "Bundle ID: \(bundleIdentifier)",
                     "Team ID: \(teamIdentifier.isEmpty ? "?" : teamIdentifier)",
                     "visionOS: \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        for item in items(jit: jit) {
            let mark = switch item.verdict {
            case .ok: "OK"
            case .warning: "??"
            case .missing: "FALTA"
            }
            lines.append("[\(mark)] \(item.title): \(item.detail)")
        }
        let keys = entitlements.keys.sorted().joined(separator: ", ")
        lines.append("Permisos de la firma: \(keys.isEmpty ? "(no se pudieron leer)" : keys)")
        return lines.joined(separator: "\n")
    }
}
