import SwiftUI

struct DiscoveryExportView: View {
    @ObservedObject var store: DiscoveryStore
    @ObservedObject var workflow: DiscoveryWorkflow
    let listID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var provider: DiscoveryProvider = .apple
    @State private var confirm = false
    @State private var retry: UUID?
    @State private var showRetry = false
    @State private var lookup: Task<Void, Never>?
    private var list: DiscoveryList? { store.lists.first { $0.id == listID } }

    var body: some View {
        NavigationStack {
            List {
                if let list {
                    Section {
                        Text(list.name).font(.headline)
                        Picker("Zieldienst", selection: $provider) {
                            ForEach(DiscoveryProvider.allCases) { Text($0.title).tag($0) }
                        }
                        .disabled(workflow.writing || workflow.searching)
                        Text("\(list.confirmed(for: provider).count) bestätigt · \(list.pending(for: provider)) noch zu prüfen · \(list.entries.filter { $0.skipped.contains(provider.rawValue) }.count) übersprungen")
                            .font(.footnote)
                        Text("Eine Playlist enthält nur Aufnahmen dieses Dienstes. Treffer eines anderen Dienstes müssen hier erneut zugeordnet werden.")
                            .font(.caption).foregroundStyle(.secondary)
                        if list.pending(for: provider) > 0 {
                            Button("Offene Titel bei \(provider.title) suchen") {
                                let ids = list.entries.filter { $0.selected[provider.rawValue] == nil && !$0.skipped.contains(provider.rawValue) }.map(\.id)
                                lookup = Task { await workflow.search(listID: listID, entries: ids, startingAt: provider, only: true) }
                            }
                            .disabled(workflow.searching || workflow.writing)
                        }
                        if workflow.searching {
                            ProgressView(workflow.progress ?? "Suche …")
                            Button("Suche abbrechen") { lookup?.cancel() }
                        }
                    }
                    Section("Titel für \(provider.title) prüfen") {
                        ForEach(list.entries) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                NavigationLink {
                                    DiscoveryEntryView(store: store, workflow: workflow, listID: listID, entryID: entry.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.song.title)
                                        Text(entry.song.artist).font(.caption).foregroundStyle(.secondary)
                                        if let chosen = entry.selected[provider.rawValue] {
                                            Label("\(chosen.title) – \(chosen.artist)", systemImage: "checkmark.circle.fill")
                                                .font(.caption).foregroundStyle(Color.shoutLive)
                                        } else {
                                            Text(entry.skipped.contains(provider.rawValue) ? "Wird übersprungen" : "Bitte Version auswählen")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .disabled(workflow.writing || workflow.searching)
                                if entry.selected[provider.rawValue] == nil {
                                    Button(entry.skipped.contains(provider.rawValue) ? "Wieder prüfen" : "Für diesen Dienst überspringen") {
                                        store.updateEntry(listID, entryID: entry.id) {
                                            if $0.skipped.contains(provider.rawValue) { $0.skipped.remove(provider.rawValue) }
                                            else { $0.skipped.insert(provider.rawValue) }
                                        }
                                    }
                                    .font(.caption)
                                    .disabled(workflow.writing || workflow.searching)
                                }
                            }
                        }
                    }
                    Section {
                        Text("Erstellt eine neue Playlist bei \(provider.title). Bestehende Dienst-Playlists bleiben erhalten.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Playlist bei \(provider.title) erstellen") { confirm = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(workflow.writing || workflow.searching || list.pending(for: provider) > 0
                                      || list.confirmed(for: provider).isEmpty || list.blocksExport(for: provider))
                        if workflow.writing { ProgressView("Playlist wird erstellt …") }
                        if let message = workflow.message { Text(message).font(.footnote) }
                        if let error = store.error { Text(error).foregroundStyle(.red) }
                    }
                    if !list.receipts.isEmpty {
                        Section("Übertragungen") {
                            ForEach(list.receipts.reversed()) { receipt in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(receipt.provider.title).font(.headline)
                                    Text(receipt.date, style: .date).font(.caption)
                                    Text(receipt.state == .complete ? "Erstellt" : receipt.state == .released ? "Weiterer Versuch ausdrücklich freigegeben" : "Ergebnis unklar – bitte im Dienstkonto prüfen")
                                        .font(.subheadline)
                                    if let message = receipt.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                                    if let url = receipt.url { Link("Playlist öffnen", destination: url) }
                                    if receipt.state == .uncertain || receipt.state == .started {
                                        Button("Nach Kontoprüfung neuen Versuch freigeben") { retry = receipt.id; showRetry = true }
                                            .disabled(workflow.writing)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Playlist übertragen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Fertig") { dismiss() }.disabled(workflow.writing)
            } }
            .confirmationDialog("Playlist wirklich erstellen?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Jetzt bei \(provider.title) erstellen") { Task { await workflow.export(listID: listID, provider: provider) } }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                if let list { Text("„\(list.name)“ mit \(list.confirmed(for: provider).count) bestätigten Titeln. Übersprungene Titel werden nicht übertragen.") }
            }
            .confirmationDialog("Dienstkonto geprüft?", isPresented: $showRetry, titleVisibility: .visible) {
                Button("Ja, weiteren Versuch freigeben") {
                    if let id = retry { store.update(listID) { list in
                        if let i = list.receipts.firstIndex(where: { $0.id == id }) { list.receipts[i].state = .released }
                    } }
                    retry = nil
                }
                Button("Abbrechen", role: .cancel) { retry = nil }
            } message: { Text("Ein erneuter Versuch kann eine zusätzliche Playlist erzeugen. Prüfe vorher beim Musikdienst, ob die erste bereits angelegt wurde.") }
            .interactiveDismissDisabled(workflow.writing)
            .onDisappear { lookup?.cancel() }
        }
        .tint(Color.shoutLive)
    }
}
