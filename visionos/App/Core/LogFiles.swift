// SPDX-License-Identifier: GPL-2.0-or-later
//
// The logs, where the player can reach them (Files app: On My Apple Vision Pro > AstroQuest >
// Registros) and send them from the launcher:
//   - consola-<date>.txt: everything written to standard output and error in a session - the
//     app's own lines, FEX's, and the emulator's crash reporter (signal and registers);
//   - emulador-<date>.txt: the emulator's log (shad_log.txt) of the previous session, copied
//     at the next start, since the emulator writes it in the app's Library and starts it anew
//     each time;
//   - comprobacion.txt: the launcher's check, written when the logs are shared.
// A game that was running when the app last ended (a crash, or the emulator ending the
// process) is noticed at the next start.

import Foundation

enum LogFiles {
    static var directory: URL {
        AstroSettings.documents.appendingPathComponent("Registros", isDirectory: true)
    }

    /// Present while a game runs; still there at the next start if the app ended meanwhile.
    private static var runningMarker: URL {
        directory.appendingPathComponent(".partida-en-curso")
    }

    /// The emulator's own log (common/path_util.cpp: ~/Library/Application Support/shadPS4/log).
    private static var emulatorLog: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shadPS4/log/shad_log.txt")
    }

    private(set) static var consolePath: String?
    /// When the game was running as the app last ended: the time it had started.
    private(set) static var previousSessionEndedUnexpectedly: Date?

    /// At the app's start: keeps what the last session left, and starts this session's console.
    static func begin() {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = Self.stamp(Date())
        if manager.fileExists(atPath: runningMarker.path) {
            let attributes = try? manager.attributesOfItem(atPath: runningMarker.path)
            previousSessionEndedUnexpectedly = (attributes?[.creationDate] as? Date) ?? Date()
            try? manager.removeItem(at: runningMarker)
        }
        if manager.fileExists(atPath: emulatorLog.path) {
            let modified = (try? manager.attributesOfItem(atPath: emulatorLog.path))?[.modificationDate] as? Date
            let target = directory.appendingPathComponent("emulador-\(Self.stamp(modified ?? Date())).txt")
            if !manager.fileExists(atPath: target.path) {
                try? manager.copyItem(at: emulatorLog, to: target)
            }
        }
        prune()
        consolePath = directory.path.withCString { astro_log_begin($0) }.map { String(cString: $0) }
        log("AstroQuest \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") "
            + "(\(Bundle.main.bundleIdentifier ?? "?")), \(ProcessInfo.processInfo.operatingSystemVersionString), "
            + "start \(stamp)")
        if let previous = previousSessionEndedUnexpectedly {
            log("The previous game (started \(Self.stamp(previous))) ended with the app")
        }
    }

    /// A line of the app's own in this session's console log.
    static func log(_ message: String) {
        message.withCString { astro_log($0) }
    }

    static func gameStarted() {
        FileManager.default.createFile(atPath: runningMarker.path, contents: nil)
    }

    static func gameStopped() {
        try? FileManager.default.removeItem(at: runningMarker)
    }

    /// The files to send: the newest console logs and emulator logs, and the check.
    static func filesToShare(report: String) -> [URL] {
        let check = directory.appendingPathComponent("comprobacion.txt")
        try? report.write(to: check, atomically: true, encoding: .utf8)
        var files = [check]
        files += newest(prefix: "consola-", count: 3)
        files += newest(prefix: "emulador-", count: 2)
        // The running game's log as it is now.
        if FileManager.default.fileExists(atPath: emulatorLog.path) {
            let current = directory.appendingPathComponent("emulador-actual.txt")
            try? FileManager.default.removeItem(at: current)
            if (try? FileManager.default.copyItem(at: emulatorLog, to: current)) != nil {
                files.append(current)
            }
        }
        return files
    }

    private static func newest(prefix: String, count: Int) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(count)
            .map { $0 }
    }

    /// Ten of each kind are kept.
    private static func prune() {
        for prefix in ["consola-", "emulador-"] {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            let old = files
                .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent != "emulador-actual.txt" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
                .dropFirst(10)
            for file in old {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }
}
