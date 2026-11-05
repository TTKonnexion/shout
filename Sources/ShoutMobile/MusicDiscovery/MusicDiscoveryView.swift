import SwiftUI

struct MusicDiscoveryView: View {
    @ObservedObject var engine: MobileEngine
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject var queue: FileTranscriptionQueue
    @ObservedObject var store: DiscoveryStore
    @ObservedObject var services: DiscoveryServices
    @ObservedObject var recognition: SongRecognitionService
    @StateObject private var workflow: DiscoveryWorkflow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [UUID] = []
    @State private var settings = false
    @State private var exportView = false
    @State private var name = ""

    init(engine: MobileEngine) {
        self.engine = engine; recorder = engine.meetingRecorder; queue = engine.fileQueue
        store = engine.musicLibrary; services = engine.musicServices
        recognition = engine.musicRecognition
        _workflow = StateObject(wrappedValue: DiscoveryWorkflow(store: engine.musicLibrary, services: engine.musicServices))
    }
    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Musikliste") {
                    if let list = store.active {
                        Menu(list.name) {
                            ForEach(store.lists) { item in
                                Button(item.name) { store.select(item.id); name = item.name }
                            }
                            Button("Neue Liste") { store.create(); name = store.active?.name ?? "" }
                        }
                        .disabled(recognition.listening || workflow.writing || workflow.searching)
                        TextField("Name der Playlist", text: $name)
                        Button("Name speichern") {
                            let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !value.isEmpty else { return }
                            store.update(list.id) { $0.name = value }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workflow.writing)
                    }
                    if let error = store.error { Text(error).foregroundStyle(.red) }
                }
                Section("Musik erkennen") {
                    Text("Lass Musik in deiner Umgebung laufen und starte die Erkennung. Ein akustischer Fingerabdruck wird mit Shazam abgeglichen; SHOUT speichert keine Aufnahme.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Die Erkennung kann die Musikwiedergabe auf diesem Gerät unterbrechen.")
                        .font(.caption).foregroundStyle(.secondary)
                    if recognition.listening {
                        ProgressView("Höre zu …")
                        Button("Erkennung stoppen") { recognition.cancel() }
                    } else {
                        Button { recognition.start(canStart: { engine.canRecognizeMusic }) } label: {
                            Label("Musik erkennen", systemImage: "waveform")
                        }
                        .disabled(!engine.canRecognizeMusic || workflow.writing)
                        if !engine.canRecognizeMusic {
                            Text("Beende zuerst die Aufnahme oder Verarbeitung.").font(.caption)
                        }
                    }
                    if let message = recognition.message { Text(message).foregroundStyle(.orange) }
                    if let song = recognition.song {
                        Text(song.title).font(.headline)
                        Text(song.artist)
                        if store.active?.entries.contains(where: { $0.song.isSameRecording(as: song) }) == true {
                            Label("Bereits in dieser Liste", systemImage: "checkmark.circle")
                        } else if let list = store.active {
                            Button("Titel bestätigen und speichern") {
                                if store.update(list.id, { _ = $0.append(song) }),
                                   let entry = store.active?.entries.last { path.append(entry.id) }
                            }
                            .disabled(recognition.listening || workflow.writing)
                        }
                    }
                }
                if let list = store.active, !list.entries.isEmpty {
                    Section("Gespeicherte Titel · \(list.entries.count)") {
                        ForEach(list.entries) { entry in
                            NavigationLink(value: entry.id) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.song.title)
                                    Text(entry.song.artist).font(.caption).foregroundStyle(.secondary)
                                    if let preferred = entry.preferred, let track = entry.selected[preferred.rawValue] {
                                        Text("Bestätigt bei \(preferred.title): \(track.title)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else { Text("Version auswählen").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                        Button { exportView = true } label: {
                            Label("Als Playlist übertragen", systemImage: "music.note.list")
                        }
                        .disabled(recognition.listening)
                    }
                }
                Section {
                    Button("Musikdienste verbinden") { recognition.cancel(); settings = true }
                }
            }
            .navigationTitle("Musik erkennen")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in
                if let list = store.active {
                    DiscoveryEntryView(store: store, workflow: workflow, listID: list.id, entryID: id)
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Schließen") { recognition.cancel(); dismiss() }.disabled(workflow.writing)
            } }
            .sheet(isPresented: $settings) { DiscoveryConnectionsView(services: services) }
            .sheet(isPresented: $exportView) {
                if let list = store.active {
                    DiscoveryExportView(store: store, workflow: workflow, listID: list.id)
                }
            }
            .task {
                if store.lists.isEmpty { store.create() }
                name = store.active?.name ?? ""
            }
            .onDisappear { recognition.cancel() }
            .onChange(of: scenePhase) { _, value in if value == .background { recognition.cancel() } }
            .interactiveDismissDisabled(recognition.listening || workflow.writing)
        }
        .tint(Color.shoutLive)
    }
}

struct DiscoveryEntryView: View {
    @ObservedObject var store: DiscoveryStore
    @ObservedObject var workflow: DiscoveryWorkflow
    let listID: UUID
    let entryID: UUID
    @State private var lookup: Task<Void, Never>?
    private var entry: DiscoveryEntry? {
        store.lists.first { $0.id == listID }?.entries.first { $0.id == entryID }
    }
    var body: some View {
        List {
            if let entry {
                Section {
                    Text(entry.song.title).font(.headline)
                    Text(entry.song.artist)
                    Text("Du bestimmst die richtige Version. Apple Music kommt zuerst; weitere Dienste nur bei Bedarf.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if workflow.searching { Section { ProgressView(workflow.progress ?? "Suche …") } }
                ForEach(DiscoveryProvider.searchOrder) { provider in
                    if entry.candidates[provider.rawValue] != nil || entry.selected[provider.rawValue] != nil {
                        Section(provider.title) {
                            if let chosen = entry.selected[provider.rawValue] {
                                Label("Bestätigt: \(chosen.title) – \(chosen.artist)", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(Color.shoutLive)
                            }
                            if let message = entry.messages[provider.rawValue] { Text(message).font(.footnote).foregroundStyle(.secondary) }
                            ForEach(entry.candidates[provider.rawValue] ?? []) { candidate in
                                Button {
                                    store.updateEntry(listID, entryID: entryID) { try $0.confirm(candidate, for: provider) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(candidate.title).font(.headline).foregroundStyle(.primary)
                                        Text(candidate.artist).foregroundStyle(.primary)
                                        if let album = candidate.album { Text(album).font(.caption).foregroundStyle(.secondary) }
                                        if let seconds = candidate.seconds {
                                            Text("\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Label(entry.selected[provider.rawValue] == candidate ? "Bestätigt" : "Diese Version auswählen",
                                              systemImage: entry.selected[provider.rawValue] == candidate ? "checkmark.circle.fill" : "circle")
                                            .font(.subheadline)
                                    }
                                    .padding(.vertical, 4)
                                }
                                .disabled(workflow.searching || workflow.writing)
                                if let url = candidate.link(provider: provider) { Link("Bei \(provider.title) öffnen", destination: url).font(.caption) }
                            }
                        }
                    }
                }
                Section {
                    if let next = DiscoveryProvider.searchOrder.first(where: { entry.candidates[$0.rawValue] == nil }) {
                        Button("Bei anderem Dienst suchen: \(next.title)") { start(next, only: false) }
                            .disabled(workflow.searching)
                    }
                    Menu("Suche bei einem Dienst wiederholen") {
                        ForEach(DiscoveryProvider.searchOrder) { provider in
                            Button(provider.title) { start(provider, only: true) }
                        }
                    }
                    .disabled(workflow.searching)
                    if workflow.searching { Button("Suche abbrechen") { lookup?.cancel() } }
                    if let error = store.error { Text(error).foregroundStyle(.red) }
                }
                .disabled(workflow.writing)
            }
        }
        .navigationTitle("Version auswählen")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let entry, entry.candidates.isEmpty && entry.selected.isEmpty {
                start(.apple, only: false)
            }
        }
        .onDisappear { lookup?.cancel() }
    }
    private func start(_ provider: DiscoveryProvider, only: Bool) {
        lookup?.cancel()
        lookup = Task { await workflow.search(listID: listID, entries: [entryID], startingAt: provider, only: only) }
    }
}
