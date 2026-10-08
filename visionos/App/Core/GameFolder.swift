// SPDX-License-Identifier: GPL-2.0-or-later
//
// The VPS4 folder: a folder of the player's own, named VPS4, anywhere the Files app reaches
// ("On My Apple Vision Pro" at the top is the place meant). Unlike the app's own folder it is not
// deleted with the app, so games, saves and the shader cache outlive a reinstall.
//
// An app may only look into a folder outside its own once the player has pointed at it with the
// system's folder picker: the permission is kept as a bookmark, both in the app's defaults (gone
// with the app) and in the keychain (which outlives it; whether visionOS still honours that
// bookmark after the app was deleted and installed again is tried, and when it does not, the
// app asks for the folder again).
//
// Inside it the app keeps:
//   Juegos/    the games, one folder each (with sce_sys/param.sfo or eboot.bin); games put in
//              VPS4 itself are found too
//   Partidas/  the emulator's home folder: users and saves
//   Cachés/    what the Vulkan driver translated, so that it is not translated again

import Foundation
import Security

enum GameFolder {
    static let name = "VPS4"

    enum Choice {
        case chosen(URL)
        case wrongName(String)
        case failed(String)
    }

    private static let defaultsKey = "vps4FolderBookmark"
    private static let keychainService = "astroquest.vps4"
    private static let keychainAccount = "folder-bookmark"
    private static let lock = NSLock()
    /// The folder, with access to it started (and kept for as long as the app runs).
    private static var current: URL?

    /// The VPS4 folder, when it was chosen and can be reached.
    static func url() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let current {
            return current
        }
        let stored: [(String, Data?)] = [("defaults", UserDefaults.standard.data(forKey: defaultsKey)),
                                         ("keychain", keychainData())]
        for (source, data) in stored {
            guard let data else { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                                     bookmarkDataIsStale: &stale) else {
                LogFiles.log("VPS4: the folder kept in the \(source) could not be found again")
                continue
            }
            let accessing = url.startAccessingSecurityScopedResource()
            guard accessing || FileManager.default.isReadableFile(atPath: url.path) else {
                LogFiles.log("VPS4: no access to \(url.path) any more (kept in the \(source))")
                continue
            }
            if stale || source != "defaults" {
                store(url)
            }
            current = url
            prepare(url)
            LogFiles.log("VPS4: \(url.path) (kept in the \(source))")
            return url
        }
        return nil
    }

    /// The player chose `url` in the folder picker.
    static func choose(_ url: URL) -> Choice {
        guard url.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame else {
            return .wrongName(url.lastPathComponent)
        }
        let accessing = url.startAccessingSecurityScopedResource()
        guard accessing || FileManager.default.isReadableFile(atPath: url.path) else {
            return .failed(L("No hay permiso para entrar en la carpeta.", "There is no permission to enter the folder."))
        }
        guard store(url) else {
            return .failed(L("No se pudo recordar la carpeta.", "The folder could not be remembered."))
        }
        lock.lock()
        if let previous = current, previous != url {
            previous.stopAccessingSecurityScopedResource()
        }
        current = url
        lock.unlock()
        prepare(url)
        moveSavesIn(url)
        LogFiles.log("VPS4: chosen \(url.path)")
        return .chosen(url)
    }

    static var games: URL? {
        url()?.appendingPathComponent("Juegos", isDirectory: true)
    }

    static var saves: URL? {
        url()?.appendingPathComponent("Partidas", isDirectory: true)
    }

    static var caches: URL? {
        url()?.appendingPathComponent("Cachés", isDirectory: true)
    }

    private static func prepare(_ root: URL) {
        for folder in ["Juegos", "Partidas", "Cachés"] {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(folder, isDirectory: true),
                                                     withIntermediateDirectories: true)
        }
    }

    /// The saves made before there was a VPS4 folder (in the app's own Application Support)
    /// go into Partidas, when it is still empty.
    private static func moveSavesIn(_ root: URL) {
        let manager = FileManager.default
        let target = root.appendingPathComponent("Partidas", isDirectory: true)
        let existing = (try? manager.contentsOfDirectory(atPath: target.path))?.filter { !$0.hasPrefix(".") } ?? []
        guard existing.isEmpty,
              let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let home = support.appendingPathComponent("shadPS4/home", isDirectory: true)
        let items = (try? manager.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        var copied = 0
        for item in items where !item.lastPathComponent.hasPrefix(".") {
            if (try? manager.copyItem(at: item, to: target.appendingPathComponent(item.lastPathComponent))) != nil {
                copied += 1
            }
        }
        if copied > 0 {
            LogFiles.log("VPS4: \(copied) items of the saves copied into Partidas")
        }
    }

    @discardableResult
    private static func store(_ url: URL) -> Bool {
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return false
        }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        storeInKeychain(data)
        return true
    }

    // MARK: - Keychain

    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: keychainAccount]
    }

    private static func keychainData() -> Data? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    private static func storeInKeychain(_ data: Data) {
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(keychainQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = keychainQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            LogFiles.log("VPS4: the keychain did not keep the folder (\(status))")
        }
    }
}
