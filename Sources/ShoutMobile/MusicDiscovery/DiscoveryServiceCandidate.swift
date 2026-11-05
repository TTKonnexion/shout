// Suchfilter und Spotify-Export aus DJ-Setpilot; keine automatische Versionswahl.
import Foundation

/// Nur Titel mit lesbaren Metadaten anbieten; undurchsichtige IDs sind kein bestätigbarer Treffer.
struct ServiceTrackCandidate: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let title: String
    let artist: String
    let album: String?
    let seconds: Double?
    init(id: String, title: String, artist: String, album: String? = nil, seconds: Double? = nil) {
        self.id = id; self.title = title; self.artist = artist; self.album = album; self.seconds = seconds
    }

    private static func duration(_ value: String?) -> Double? {
        guard let value, let pattern = try? NSRegularExpression(pattern: "^PT(?:(\\d+(?:\\.\\d+)?)H)?(?:(\\d+(?:\\.\\d+)?)M)?(?:(\\d+(?:\\.\\d+)?)S)?$"),
              let match = pattern.firstMatch(in:value,range:NSRange(value.startIndex...,in:value)) else { return nil }
        var total = 0.0, found = false
        for (group,factor) in [(1,3600.0),(2,60.0),(3,1.0)] {
            if let range = Range(match.range(at:group),in:value), let number = Double(value[range]) { total += number * factor; found = true }
        }
        return found && total > 0 && total.isFinite ? total : nil
    }

    static func tidalTracks(in json: [String: Any]) -> [ServiceTrackCandidate] {
        let data = (json["data"] as? [[String: Any]]) ?? (json["data"] as? [String: Any]).map { [$0] } ?? []
        let included = json["included"] as? [[String: Any]] ?? []
        let objects = data + included
        var seen = Set<String>()
        return objects.compactMap { object in
            guard object["type"] as? String == "tracks", let id = object["id"] as? String,
                  let attributes = object["attributes"] as? [String: Any],
                  let title = attributes["title"] as? String, !title.isEmpty else { return nil }
            let relations = object["relationships"] as? [String: Any] ?? [:]
            let artistData = (relations["artists"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
            let artistIDs = artistData.compactMap { $0["id"] as? String }
            let names = artistIDs.compactMap { artistID -> String? in
                let artist = objects.first { $0["type"] as? String == "artists" && $0["id"] as? String == artistID }
                return (artist?["attributes"] as? [String: Any])?["name"] as? String
            }
            // Ohne Künstler keine sichere Freigabe einer Aufnahme.
            guard !names.isEmpty, seen.insert(id).inserted else { return nil }
            let version = attributes["version"] as? String ?? ""
            let display = version.isEmpty ? title : title + " (" + version + ")"
            let albumData = (relations["albums"] as? [String:Any])?["data"] as? [[String:Any]] ?? []
            let albumIDs = albumData.compactMap { $0["id"] as? String }
            let album = objects.first { $0["type"] as? String == "albums" && albumIDs.contains($0["id"] as? String ?? "") }
            let albumName = (album?["attributes"] as? [String:Any])?["title"] as? String
            return Self(id: id, title: display, artist: names.joined(separator: ", "),album:albumName,seconds:duration(attributes["duration"] as? String))
        }
    }
}

/// Offizielle Spotify-Endpunkte; Schreibzugriffe werden nie automatisch wiederholt.
struct SpotifyPlaylistExportClient {
    let http: SpotifyHTTP
    let tokens: SpotifyTokenProviding

    func candidates(for track: DiscoverySong) async throws -> [ServiceTrackCandidate] {
        var url = URLComponents(string: "https://api.spotify.com/v1/search")!
        url.queryItems = [.init(name: "q", value: [track.title, track.version ?? "", track.artist].filter { !$0.isEmpty }.joined(separator: " ")), .init(name: "type", value: "track"), .init(name: "limit", value: "10")]
        let data = try await request(url.url!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = json["tracks"] as? [String: Any], let items = tracks["items"] as? [[String: Any]] else { throw SpotifyImportError.invalidResponse }
        var seen = Set<String>()
        let candidates: [ServiceTrackCandidate] = items.compactMap { item in
            guard let uri = item["uri"] as? String, Self.validURI(uri),
                  let title = item["name"] as? String, !title.isEmpty,
                  let artists = item["artists"] as? [[String: Any]], item["is_playable"] as? Bool != false,
                  item["is_local"] as? Bool != true else { return nil }
            let names = artists.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
            guard !names.isEmpty, seen.insert(uri).inserted else { return nil }
            return ServiceTrackCandidate(id: uri, title: title, artist: names.joined(separator: ", "), album:(item["album"] as? [String:Any])?["name"] as? String, seconds:(item["duration_ms"] as? Double).map { $0 / 1000 })
        }
        return ServiceTrackCandidate.relevant(for:track,in:candidates)
    }

    func create(name: String, uris: [String]) async throws -> String {
        guard !uris.isEmpty, uris.allSatisfy(Self.validURI) else { throw SpotifyImportError.invalidResponse }
        let data = try await request(URL(string: "https://api.spotify.com/v1/me/playlists")!, body: ["name": String(name.prefix(100)), "public": false])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String, !id.isEmpty,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw SpotifyImportError.invalidResponse }
        var added = 0
        do {
            for start in stride(from: 0, to: uris.count, by: 100) {
                let batch = Array(uris[start..<min(start + 100, uris.count)])
                let written = try await request(URL(string: "https://api.spotify.com/v1/playlists/\(id)/items")!, body: ["uris": batch])
                guard let confirmation = try JSONSerialization.jsonObject(with:written) as? [String:Any],
                      let snapshot = confirmation["snapshot_id"] as? String, !snapshot.isEmpty else { throw SpotifyImportError.invalidResponse }
                added += batch.count
            }
        } catch {
            throw SpotifyImportError.authentication("Spotify-Playlist \(id) wurde angelegt; \(added) Titel sicher bestätigt. Weitere Titel könnten bereits angekommen sein. Bitte im Konto prüfen, bevor du erneut exportierst.")
        }
        return id
    }

    private static func validURI(_ uri: String) -> Bool {
        let parts = uri.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "spotify" && parts[1] == "track" && !parts[2].isEmpty
            && parts[2].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private func request(_ url: URL, body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for attempt in 0...1 {
            try Task.checkCancellation()
            request.setValue("Bearer \(try await tokens.accessToken(forceRefresh: attempt == 1))", forHTTPHeaderField: "Authorization")
            let (data, response): (Data, HTTPURLResponse)
            do { (data, response) = try await http.send(request) }
            catch {
                if body != nil { throw SpotifyImportError.authentication("Spotify konnte den Schreibvorgang nicht bestätigen. Die Playlist könnte bereits angelegt sein. Bitte im Konto prüfen, bevor du erneut exportierst.") }
                throw error
            }
            if response.statusCode == 401 && attempt == 0 && body == nil { continue }
            guard (200..<300).contains(response.statusCode) else {
                throw SpotifyImportError.http(response.statusCode, response.statusCode == 403 ? "Zugriff fehlt: Konto im Spotify-Pilot freischalten und erneut verbinden" : nil)
            }
            return data
        }
        throw SpotifyImportError.sessionExpired
    }
}

extension ServiceTrackCandidate {
    /// Dienstsuche ist oft breit (etwa nur „Afro House“). Nur Aufnahmen mit passendem
    /// eigentlichem Titelnamen anbieten; Interpret und Versionsangaben bestimmen die Rangfolge.
    static func relevant(for track: DiscoverySong, in candidates: [Self], limit: Int = 10) -> [Self] {
        let wantedTitle = titleWords(track.title)
        guard !wantedTitle.isEmpty, limit > 0 else { return [] }
        let wantedArtist = words(track.artist)
        let wantedVersion = versions(track.title + " " + (track.version ?? ""))
        var seen = Set<String>()
        let ranked: [(candidate:Self, score:Int, position:Int)] = candidates.enumerated().compactMap { index,candidate in
            guard seen.insert(candidate.id).inserted else { return nil }
            let offeredTitle = titleWords(candidate.title)
            guard !offeredTitle.isEmpty else { return nil }
            let exactTitle = wantedTitle == offeredTitle
            let artist = words(candidate.artist)
            let artistMatch = !wantedArtist.isEmpty && (artist == wantedArtist || wantedArtist.isSubset(of:artist))
            // Ein bloß gemeinsames Genre-/Mixwort darf keinen fremden Song passieren lassen.
            let overlap = wantedTitle.intersection(offeredTitle).count
            let titleCoverage = Double(overlap) / Double(max(wantedTitle.count,offeredTitle.count))
            guard exactTitle || (artistMatch && wantedTitle.count >= 2 && titleCoverage >= 0.8) else { return nil }
            // Sehr kurze/generische Titel brauchen zusätzlich den passenden Interpreten.
            if !artistMatch && !wantedTitle.contains(where: { $0.count >= 4 }) { return nil }
            let offeredVersion = versions(candidate.title)
            // Bekannte gegensätzliche Aufnahmetypen nicht als normale Alternative anbieten.
            for marker in ["live", "karaoke", "instrumental", "acoustic"] {
                if wantedVersion.contains(marker) != offeredVersion.contains(marker) { return nil }
            }
            if wantedVersion.contains("extended") && offeredVersion.contains("radio") { return nil }
            if wantedVersion.contains("radio") && offeredVersion.contains("extended") { return nil }
            let fullTitleMatch = DiscoverySong.normalized(track.title) == DiscoverySong.normalized(candidate.title)
            let versionMatch = wantedVersion == offeredVersion
            let durationMatch = track.seconds > 0 && candidate.seconds.map { abs(Double(track.seconds) - $0) <= 2 } == true
            let score = (exactTitle ? 100 : 60) + (artistMatch ? 50 : 0) + (fullTitleMatch ? 20 : 0)
                + (versionMatch ? 15 : 0) + (durationMatch ? 5 : 0)
            return (candidate,score,index)
        }
        return ranked.sorted { $0.score == $1.score ? $0.position < $1.position : $0.score > $1.score }
            .prefix(limit).map(\.candidate)
    }

    private static func words(_ text:String) -> Set<String> {
        let normalized = text.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX"))
        return Set(normalized.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
    private static func titleWords(_ text:String) -> Set<String> {
        var core = text.replacingOccurrences(of:"\\([^)]*\\)|\\[[^]]*\\]",with:" ",options:.regularExpression)
        // Nur erkennbare Versionszusätze nach Gedanken-/Bindestrich abtrennen.
        for separator in [" – ", " — ", " - "] {
            if let range = core.range(of:separator), !versions(String(core[range.upperBound...])).isEmpty {
                core = String(core[..<range.lowerBound]); break
            }
        }
        let all = words(core)
        let generic: Set<String> = ["the","a","an","la","el","los","las","de","del","and","feat","ft","featuring"]
        let specific = all.subtracting(generic)
        return specific.isEmpty ? all : specific
    }
    private static func versions(_ text:String) -> Set<String> {
        words(text).intersection(["live","karaoke","instrumental","acoustic","remix","mix","edit","extended","radio","remaster","remastered","afro","house"])
    }
}
