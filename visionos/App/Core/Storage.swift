// SPDX-License-Identifier: GPL-2.0-or-later
//
// What has been copied into the app's folder (Files app: On My Apple Vision Pro > AstroQuest).
//
// Files copied in from a computer can arrive read-only, or locked (the "immutable" flag a
// Windows read-only attribute or a Mac's "Locked" becomes): the Files app then cannot delete
// them (error -5000). The app owns its folder, so at every start it gives itself back the right
// to change and delete everything in it, and it can delete what was copied in itself.

import Foundation

enum Storage {
    struct Item: Identifiable, Hashable {
        let url: URL
        let isFolder: Bool
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    /// What the app keeps there itself, and is not offered for deleting.
    private static let ownNames: Set<String> = ["settings.txt", "Registros"]

    /// The top level of the app's folder, apart from the app's own files.
    static func items() -> [Item] {
        let documents = AstroSettings.documents
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: documents, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        return contents
            .filter { !ownNames.contains($0.lastPathComponent) && !$0.lastPathComponent.hasPrefix(".") }
            .map { url in
                let folder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return Item(url: url, isFolder: folder)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Makes everything under `root` changeable and deletable by the app (and so by the Files
    /// app): no lock, and write permission for the owner. Returns how many entries it changed.
    @discardableResult
    static func unlock(_ root: URL = AstroSettings.documents) -> Int {
        let manager = FileManager.default
        var changed = 0
        func fix(_ url: URL, folder: Bool) {
            guard let attributes = try? manager.attributesOfItem(atPath: url.path) else { return }
            var wanted: [FileAttributeKey: Any] = [:]
            if (attributes[.immutable] as? Bool) == true {
                wanted[.immutable] = false
            }
            if (attributes[.appendOnly] as? Bool) == true {
                wanted[.appendOnly] = false
            }
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let needed = folder ? 0o700 : 0o600
            if permissions & needed != needed {
                wanted[.posixPermissions] = NSNumber(value: permissions | needed)
            }
            if !wanted.isEmpty, (try? manager.setAttributes(wanted, ofItemAtPath: url.path)) != nil {
                changed += 1
            }
        }
        fix(root, folder: true)
        guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                              options: [], errorHandler: { _, _ in true }) else {
            return changed
        }
        for case let url as URL in walker {
            let folder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            // A locked folder has to be opened up before what is inside it can be reached.
            fix(url, folder: folder)
        }
        return changed
    }

    /// Deletes something copied into the app's folder, unlocking it first.
    static func delete(_ item: Item) throws {
        if item.isFolder {
            unlock(item.url)
        } else {
            let manager = FileManager.default
            try? manager.setAttributes([.immutable: false, .posixPermissions: NSNumber(value: 0o644)],
                                       ofItemAtPath: item.url.path)
        }
        // The folder it is in has to be writable too.
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: AstroSettings.documents.path)
        try FileManager.default.removeItem(at: item.url)
    }

    /// How much an item takes, in bytes (walks a folder: call it off the main thread).
    static func size(of item: Item) -> Int64 {
        guard item.isFolder else {
            return Int64((try? item.url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        var total: Int64 = 0
        let walker = FileManager.default.enumerator(at: item.url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                                    options: [], errorHandler: { _, _ in true })
        while let url = walker?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
