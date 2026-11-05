import Foundation
import CryptoKit

/// Eigene Musikdaten: kein Zugriff auf Diktate, Kontakte oder TT-brAIn.
enum DiscoveryProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case apple, spotify, tidal
    var id: String { rawValue }
    var title: String {
        switch self { case .apple: return "Apple Music"; case .spotify: return "Spotify"; case .tidal: return "TIDAL" }
    }
    static let searchOrder: [Self] = [.apple, .spotify, .tidal]
}

struct DiscoverySong: Codable, Equatable, Sendable {
    var title: String
    var artist: String
    var shazamID: String? = nil
    var version: String? = nil
    var seconds: Int = 0

    static func recognized(title: String?, artist: String?, shazamID: String?) -> Self? {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artist = artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        return Self(title: title, artist: artist, shazamID: shazamID)
    }
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }
    func isSameRecording(as other: Self) -> Bool {
        if let id = shazamID, !id.isEmpty, id == other.shazamID { return true }
        return Self.normalized(title) == Self.normalized(other.title)
            && Self.normalized(artist) == Self.normalized(other.artist)
    }
}

struct DiscoveryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var song: DiscoverySong
    var candidates: [String: [ServiceTrackCandidate]] = [:]
    var messages: [String: String] = [:]
    var selected: [String: ServiceTrackCandidate] = [:]
    var preferred: DiscoveryProvider? = nil
    var skipped: Set<String> = []

    mutating func confirm(_ candidate: ServiceTrackCandidate, for provider: DiscoveryProvider) throws {
        guard candidates[provider.rawValue]?.contains(candidate) == true else { throw DiscoveryError.invalidSelection }
        selected[provider.rawValue] = candidate
        preferred = provider
        skipped.remove(provider.rawValue)
    }
    mutating func setResults(_ values: [ServiceTrackCandidate], message: String?, for provider: DiscoveryProvider) {
        candidates[provider.rawValue] = values
        messages[provider.rawValue] = message
        // Bestätigte Auswahl unabhängig von späteren Suchergebnissen erhalten.
    }
}

enum DiscoveryError: LocalizedError {
    case invalidSelection, invalidList, duplicateExport, storage, notConnected(String), noSelection, searchTimeout
    var errorDescription: String? {
        switch self {
        case .searchTimeout: return "Die Dienstsuche hat zu lange gedauert. Bitte später erneut versuchen."
        case .invalidSelection: return "Bitte einen angezeigten Treffer auswählen."
        case .invalidList: return "Die Musikliste ist nicht vollständig lesbar. Die Datei bleibt erhalten."
        case .duplicateExport: return "Dieser Stand wurde bereits übertragen oder sein Ergebnis ist unklar. Prüfe zuerst dein Dienstkonto."
        case .storage: return "Die Musikliste konnte nicht gespeichert werden. Bitte freien Speicher prüfen."
        case .notConnected(let service): return "\(service) ist nicht verbunden. Öffne die Musikdienste."
        case .noSelection: return "Für diesen Dienst fehlen noch bestätigte Titel."
        }
    }
}

struct DiscoveryReceipt: Codable, Identifiable, Equatable {
    enum State: String, Codable { case started, complete, uncertain, released }
    var id = UUID()
    var provider: DiscoveryProvider
    var fingerprint: String
    var state: State = .started
    var url: URL? = nil
    var message: String? = nil
    var date = Date()
}

struct DiscoveryList: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var entries: [DiscoveryEntry] = []
    var receipts: [DiscoveryReceipt] = []

    mutating func append(_ song: DiscoverySong) -> Bool {
        guard !entries.contains(where: { $0.song.isSameRecording(as: song) }) else { return false }
        entries.append(DiscoveryEntry(song: song)); return true
    }
    func confirmed(for provider: DiscoveryProvider) -> [ServiceTrackCandidate] {
        entries.compactMap { $0.selected[provider.rawValue] }
    }
    func pending(for provider: DiscoveryProvider) -> Int {
        entries.filter { $0.selected[provider.rawValue] == nil && !$0.skipped.contains(provider.rawValue) }.count
    }
    func fingerprint(for provider: DiscoveryProvider) -> String {
        // Ordnung, Position und Anbieter-ID sind Bestandteil des Exportstands.
        let values = [provider.rawValue, name] + entries.map {
            $0.id.uuidString + ":" + ($0.selected[provider.rawValue]?.id ?? ($0.skipped.contains(provider.rawValue) ? "skip" : "pending"))
        }
        let data = try! JSONEncoder().encode(values)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func blocksExport(for provider: DiscoveryProvider) -> Bool {
        receipts.contains { $0.provider == provider && $0.fingerprint == fingerprint(for: provider) && $0.state != .released }
    }
}

/// Ein Dokument pro Liste. Beschädigte Dokumente werden nicht überschrieben.
struct DiscoveryArchive {
    var directory: URL
    func load() throws -> (lists: [DiscoveryList], unreadable: Int) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([], 0) }
        var lists: [DiscoveryList] = [], unreadable = 0
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where file.pathExtension == "json" {
            do {
                let list = try JSONDecoder().decode(DiscoveryList.self, from: Data(contentsOf: file))
                guard file.deletingPathExtension().lastPathComponent == list.id.uuidString else { throw DiscoveryError.invalidList }
                try validate(list); lists.append(list)
            } catch { unreadable += 1 }
        }
        return (lists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, unreadable)
    }
    func save(_ list: DiscoveryList) throws {
        try validate(list)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(list.id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            let old = try JSONDecoder().decode(DiscoveryList.self, from: Data(contentsOf: file))
            guard old.id == list.id else { throw DiscoveryError.invalidList }
        }
        try JSONEncoder().encode(list).write(to: file, options: .atomic)
    }
    private func validate(_ list: DiscoveryList) throws {
        guard !list.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(list.entries.map(\.id)).count == list.entries.count,
              Set(list.receipts.map(\.id)).count == list.receipts.count,
              list.entries.allSatisfy({ !$0.song.title.isEmpty && !$0.song.artist.isEmpty }) else { throw DiscoveryError.invalidList }
    }
}

extension ServiceTrackCandidate {
    func link(provider: DiscoveryProvider) -> URL? {
        let value = provider == .spotify ? id.replacingOccurrences(of: "spotify:track:", with: "") : id
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        switch provider {
        case .apple: return URL(string: "https://music.apple.com/song/" + value)
        case .spotify: return URL(string: "https://open.spotify.com/track/" + value)
        case .tidal: return URL(string: "https://tidal.com/browse/track/" + value)
        }
    }
}
