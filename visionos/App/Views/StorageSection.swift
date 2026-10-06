// SPDX-License-Identifier: GPL-2.0-or-later
//
// What has been copied into the app's folder, with its size, and a way to delete it from the
// app (Storage.swift) - also what the Files app refuses to delete.

import SwiftUI

struct StorageSection: View {
    @Environment(AppModel.self) private var model
    @State private var items: [Storage.Item] = []
    @State private var sizes: [URL: Int64] = [:]
    @State private var toDelete: Storage.Item?
    @State private var working = false
    @State private var status: String?

    var body: some View {
        Section {
            if items.isEmpty {
                Text(L("No hay nada copiado en la carpeta de AstroQuest.", "Nothing has been copied to AstroQuest's folder."))
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                HStack(spacing: 14) {
                    Image(systemName: item.isFolder ? "folder.fill" : "doc.fill")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                        if let size = sizes[item.url] {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(role: .destructive) {
                        toDelete = item
                    } label: {
                        Label(L("Borrar", "Delete"), systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .disabled(working)
                }
            }
            Button {
                unlockAll()
            } label: {
                Label(L("Quitar «solo lectura» a todo", "Remove “read-only” from everything"), systemImage: "lock.open")
            }
            .disabled(working)
            if let status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L("Datos copiados", "Copied data"))
        } footer: {
            Text(L("Lo que copias en «En mi Apple Vision Pro › AstroQuest». Si Archivos no te deja borrar algo (error -5000), bórralo desde aquí. Al abrirse, la app también quita el «solo lectura» a todo lo que hay en su carpeta.", "What you copy to “On My Apple Vision Pro › AstroQuest”. If Files does not let you delete something (error -5000), delete it from here. When it opens, the app also removes “read-only” from everything in its folder."))
        }
        .onAppear(perform: reload)
        .confirmationDialog(toDelete.map { L("¿Borrar «\($0.name)»?", "Delete “\($0.name)”?") } ?? "",
                            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            titleVisibility: .visible) {
            Button(L("Borrar", "Delete"), role: .destructive) {
                if let item = toDelete {
                    delete(item)
                }
            }
            Button(L("Cancelar", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("Se borra del Vision Pro y no se puede deshacer.", "It is deleted from the Vision Pro and cannot be undone."))
        }
    }

    private func reload() {
        items = Storage.items()
        let current = items
        Task.detached {
            var found: [URL: Int64] = [:]
            for item in current {
                found[item.url] = Storage.size(of: item)
            }
            await MainActor.run {
                sizes = found
            }
        }
    }

    private func delete(_ item: Storage.Item) {
        working = true
        status = L("Borrando «\(item.name)»…", "Deleting “\(item.name)”…")
        Task.detached {
            let result: String
            do {
                try Storage.delete(item)
                result = L("«\(item.name)» borrado.", "“\(item.name)” deleted.")
                LogFiles.log("Deleted from the app's folder: \(item.name)")
            } catch {
                result = L("No se pudo borrar «\(item.name)»: \(error.localizedDescription)", "“\(item.name)” could not be deleted: \(error.localizedDescription)")
                LogFiles.log("Could not delete \(item.name): \(error)")
            }
            await MainActor.run {
                status = result
                working = false
                reload()
                model.findGame()
            }
        }
    }

    private func unlockAll() {
        working = true
        status = L("Revisando la carpeta…", "Checking the folder…")
        Task.detached {
            let changed = Storage.unlock()
            await MainActor.run {
                status = changed == 0 ? L("Todo se podía borrar ya.", "Everything could already be deleted.") : L("Desbloqueados \(changed) archivos y carpetas.", "Unlocked \(changed) files and folders.")
                working = false
            }
        }
    }
}
