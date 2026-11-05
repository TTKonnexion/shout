import Foundation
import Combine
import Security

@MainActor
final class DiscoveryStore: ObservableObject {
    @Published private(set) var lists: [DiscoveryList] = []
    @Published var activeID: UUID?
    @Published private(set) var error: String?
    private let archive: DiscoveryArchive
    private let defaults: UserDefaults
    private var readable = true

    init(directory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MusicLists", isDirectory: true), defaults: UserDefaults = .standard) {
        self.defaults = defaults
        archive = DiscoveryArchive(directory: directory)
        do {
            let loaded = try archive.load(); lists = loaded.lists
            if loaded.unreadable > 0 { error = "\(loaded.unreadable) Musiklisten sind nicht lesbar. Ihre Dateien bleiben erhalten." }
        } catch { readable = false; self.error = "Musiklisten konnten nicht geöffnet werden. Die Dateien bleiben erhalten." }
        activeID = defaults.string(forKey: "music.activeList").flatMap(UUID.init(uuidString:))
        if !lists.contains(where: { $0.id == activeID }) { activeID = lists.first?.id }
    }
    var active: DiscoveryList? { lists.first { $0.id == activeID } }
    func select(_ id: UUID) { activeID = id; defaults.set(id.uuidString, forKey: "music.activeList") }
    func create() {
        let list = DiscoveryList(name: "Erkannte Titel " + Date().formatted(date: .numeric, time: .shortened))
        if save(list) { select(list.id) }
    }
    @discardableResult func save(_ list: DiscoveryList) -> Bool {
        guard readable else { return false }
        do {
            try archive.save(list)
            if let index = lists.firstIndex(where: { $0.id == list.id }) { lists[index] = list }
            else { lists.append(list) }
            error = nil; return true
        } catch { self.error = "Musikliste nicht gespeichert: " + error.localizedDescription; return false }
    }
    @discardableResult func update(_ id: UUID, _ change: (inout DiscoveryList) throws -> Void) -> Bool {
        guard var list = lists.first(where: { $0.id == id }) else { return false }
        do { try change(&list); return save(list) }
        catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult func updateEntry(_ listID: UUID, entryID: UUID,
                                        _ change: (inout DiscoveryEntry) throws -> Void) -> Bool {
        update(listID) { list in
            guard let index = list.entries.firstIndex(where: { $0.id == entryID }) else { throw DiscoveryError.invalidSelection }
            try change(&list.entries[index])
        }
    }
}

/// Separater Schlüsselbund-Dienst; niemals Diktat-Gerätewörter oder DJ-Setpilot-Token verwenden.
enum DiscoveryKeychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "de.thull24.shout.music", kSecAttrAccount as String: key]
    }
    static func save(_ key: String, _ value: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(key); item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw DiscoveryError.storage }
        } else if status != errSecSuccess { throw DiscoveryError.storage }
    }
    static func read(_ key: String) -> String? {
        var item = query(key); item[kSecReturnData as String] = true; item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func delete(_ key: String) { SecItemDelete(query(key) as CFDictionary) }
}
