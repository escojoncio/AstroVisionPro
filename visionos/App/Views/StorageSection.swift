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
                Text("No hay nada copiado en la carpeta de AstroQuest.")
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
                        Label("Borrar", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .disabled(working)
                }
            }
            Button {
                unlockAll()
            } label: {
                Label("Quitar «solo lectura» a todo", systemImage: "lock.open")
            }
            .disabled(working)
            if let status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Datos copiados")
        } footer: {
            Text("Lo que copias en «En mi Apple Vision Pro › AstroQuest». Si Archivos no te deja borrar algo (error -5000), bórralo desde aquí. Al abrirse, la app también quita el «solo lectura» a todo lo que hay en su carpeta.")
        }
        .onAppear(perform: reload)
        .confirmationDialog(toDelete.map { "¿Borrar «\($0.name)»?" } ?? "",
                            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Borrar", role: .destructive) {
                if let item = toDelete {
                    delete(item)
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se borra del Vision Pro y no se puede deshacer.")
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
        status = "Borrando «\(item.name)»…"
        Task.detached {
            let result: String
            do {
                try Storage.delete(item)
                result = "«\(item.name)» borrado."
                LogFiles.log("Deleted from the app's folder: \(item.name)")
            } catch {
                result = "No se pudo borrar «\(item.name)»: \(error.localizedDescription)"
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
        status = "Revisando la carpeta…"
        Task.detached {
            let changed = Storage.unlock()
            await MainActor.run {
                status = changed == 0 ? "Todo se podía borrar ya." : "Desbloqueados \(changed) archivos y carpetas."
                working = false
            }
        }
    }
}
