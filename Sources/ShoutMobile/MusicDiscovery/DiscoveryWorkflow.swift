import Foundation
import Combine

@MainActor
protocol DiscoveryMusicServing {
    func search(_ song: DiscoverySong, provider: DiscoveryProvider) async throws -> [ServiceTrackCandidate]
    func prepareExport(_ provider: DiscoveryProvider) async throws
    func create(name: String, provider: DiscoveryProvider, tracks: [ServiceTrackCandidate]) async throws -> URL?
}

/// Suche schreibt nie eine Playlist und bestätigt nie einen Treffer für den Nutzer.
@MainActor
final class DiscoveryWorkflow: ObservableObject {
    @Published private(set) var searching = false
    @Published private(set) var writing = false
    @Published private(set) var progress: String?
    @Published private(set) var message: String?
    private let store: DiscoveryStore
    private let services: any DiscoveryMusicServing
    private let searchTimeout: Duration
    init(store: DiscoveryStore, services: any DiscoveryMusicServing, searchTimeout: Duration = .seconds(25)) {
        self.store = store; self.services = services; self.searchTimeout = searchTimeout
    }
    private func candidates(_ song: DiscoverySong, provider: DiscoveryProvider) async throws -> [ServiceTrackCandidate] {
        let services = self.services, timeout = self.searchTimeout
        return try await withThrowingTaskGroup(of: [ServiceTrackCandidate].self) { group in
            group.addTask { @MainActor in try await services.search(song, provider: provider) }
            group.addTask { try await Task.sleep(for: timeout); throw DiscoveryError.searchTimeout }
            defer { group.cancelAll() }
            return try await group.next() ?? []
        }
    }

    func search(listID: UUID, entries: [UUID], startingAt provider: DiscoveryProvider = .apple, only: Bool = false) async {
        guard !searching, !writing else { return }
        searching = true; message = nil
        defer { searching = false; progress = nil }
        let index = DiscoveryProvider.searchOrder.firstIndex(of: provider)!
        let providers = only ? [provider] : Array(DiscoveryProvider.searchOrder[index...])
        for id in entries {
            guard let entry = store.lists.first(where: { $0.id == listID })?.entries.first(where: { $0.id == id }) else { continue }
            for service in providers {
                do {
                    try Task.checkCancellation()
                    progress = "Suche bei \(service.title): \(entry.song.title)"
                    let values = try await candidates(entry.song, provider: service)
                    try Task.checkCancellation()
                    guard store.updateEntry(listID, entryID: id, {
                        $0.setResults(values, message: values.isEmpty ? "Kein ausreichend passender Treffer." : nil, for: service)
                    }) else { return }
                    if !values.isEmpty { break }
                } catch is CancellationError { return }
                catch let error as URLError where error.code == .cancelled { return }
                catch {
                    guard !Task.isCancelled else { return }
                    guard store.updateEntry(listID, entryID: id, {
                        $0.setResults([], message: error.localizedDescription, for: service)
                    }) else { return }
                }
            }
        }
    }

    func export(listID: UUID, provider: DiscoveryProvider) async {
        guard !writing, !searching, let list = store.lists.first(where: { $0.id == listID }) else { return }
        writing = true; message = nil
        defer { writing = false }
        guard list.pending(for: provider) == 0, !list.confirmed(for: provider).isEmpty else {
            message = DiscoveryError.noSelection.localizedDescription; return
        }
        guard !list.blocksExport(for: provider) else { message = DiscoveryError.duplicateExport.localizedDescription; return }
        do { try await services.prepareExport(provider); try Task.checkCancellation() }
        catch { message = error.localizedDescription; return }
        let receipt = DiscoveryReceipt(provider: provider, fingerprint: list.fingerprint(for: provider))
        // Vor dem ersten POST persistieren. Bei Prozessabbruch bleibt der Stand gesperrt.
        guard store.update(listID, { current in
            guard current.fingerprint(for: provider) == receipt.fingerprint, !current.blocksExport(for: provider) else {
                throw DiscoveryError.duplicateExport
            }
            current.receipts.append(receipt)
        }) else { return }
        do {
            let url = try await services.create(name: list.name, provider: provider, tracks: list.confirmed(for: provider))
            let saved = store.update(listID) { current in
                guard let i = current.receipts.firstIndex(where: { $0.id == receipt.id }) else { throw DiscoveryError.storage }
                current.receipts[i].state = .complete; current.receipts[i].url = url
                current.receipts[i].message = "\(list.confirmed(for: provider).count) bestätigte Titel übertragen."
            }
            message = saved ? "Playlist bei \(provider.title) erstellt."
                : "Playlist erstellt, aber der Beleg konnte nicht gespeichert werden. Prüfe vor jedem weiteren Versuch dein Dienstkonto."
        } catch {
            _ = store.update(listID) { current in
                guard let i = current.receipts.firstIndex(where: { $0.id == receipt.id }) else { return }
                current.receipts[i].state = .uncertain
                current.receipts[i].message = error.localizedDescription
            }
            message = "Das Ergebnis ist nicht vollständig bestätigt. Es könnte bereits eine Playlist existieren. Bitte zuerst bei \(provider.title) nachsehen. " + error.localizedDescription
        }
    }
}
