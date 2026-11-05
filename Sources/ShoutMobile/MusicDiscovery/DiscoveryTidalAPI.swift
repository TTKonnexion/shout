// Testbarer TIDAL-Client aus DJ-Setpilot.
import Foundation

enum StreamingClientConfiguration {
    static func clientID(bundled: String?, saved: String?) -> String {
        // Eine freigegebene Produktkennung darf nicht durch alte lokale Testeinstellungen verdrängt werden.
        let value = (bundled ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        return value.isEmpty ? (saved ?? "").trimmingCharacters(in:.whitespacesAndNewlines) : value
    }
}

struct TidalConfig: Equatable {
    let clientID: String
    let redirectURI: String
    static let scopes = "playlists.read playlists.write search.read"
    var isValid: Bool { !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && URL(string: redirectURI)?.scheme != nil }

    func authorizationURL(verifier: String, state: String) throws -> URL {
        guard isValid else { throw TidalAPIError.notConfigured }
        var url = URLComponents(string: "https://login.tidal.com/authorize")!
        url.queryItems = ["response_type": "code", "client_id": clientID, "redirect_uri": redirectURI,
                          "scope": Self.scopes, "code_challenge_method": "S256",
                          "code_challenge": SpotifyPKCE.challenge(for: verifier), "state": state]
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }

    func code(from callback: URL, state: String) throws -> String {
        // Gemeinsame strenge Prüfung: Ziel, einmaliger State/Code, keine Benutzerinfos oder Fragmente.
        do { return try SpotifyCallback.code(from: callback, redirectURI: redirectURI, state: state) }
        catch { throw TidalAPIError.authentication }
    }
}

enum TidalAPIError: LocalizedError, Equatable {
    case notConfigured, notConnected, authentication, invalidResponse, network
    case http(Int), partial(id: String, confirmed: Int)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "TIDAL ist noch nicht eingerichtet. Bitte die Verbindung in den Einstellungen prüfen."
        case .notConnected: return "Die TIDAL-Anmeldung ist abgelaufen. Bitte erneut verbinden."
        case .authentication: return "TIDAL-Anmeldung nicht bestätigt. Bitte erneut verbinden und die hinterlegte Weiterleitung prüfen."
        case .invalidResponse: return "TIDAL hat keine vollständige, prüfbare Antwort geliefert."
        case .network: return "Die Antwort von TIDAL fehlt. Bei einem Export könnte bereits eine Playlist angelegt worden sein. Bitte zuerst im Konto prüfen."
        case .http(401): return "TIDAL hat die Anmeldung abgelehnt. Bitte erneut verbinden."
        case .http(403): return "TIDAL gibt diesen Zugriff nicht frei. Bitte neu verbinden; der Anbieter muss das Konto und die Playlist-Berechtigung zulassen."
        case .http(429): return "TIDAL begrenzt gerade die Anfragen. Bitte später erneut versuchen."
        case .http(let status): return "TIDAL antwortet mit Fehler \(status). Bitte später erneut versuchen."
        case .partial(let id, let count): return "TIDAL-Playlist \(id) wurde angelegt; \(count) Titel sind bestätigt. Weitere Titel wurden übersprungen oder ihr Ergebnis ist unklar. Bitte zuerst in TIDAL prüfen. Es wird nicht automatisch erneut geschrieben."
        }
    }
}

struct KeychainTidalTokenStore: SpotifyTokenStore {
    func loadRefreshToken() -> String? { DiscoveryKeychain.read("tidal.refresh") }
    func saveRefreshToken(_ token: String) throws { try DiscoveryKeychain.save("tidal.refresh", token) }
    func clear() { DiscoveryKeychain.delete("tidal.refresh") }
}

/// Testbarer PKCE-Tokenaustausch. Keine Dienstpasswörter und keine Token in Ausgaben.
actor TidalTokenService: SpotifyTokenProviding {
    let config: TidalConfig
    let http: SpotifyHTTP
    let store: SpotifyTokenStore
    var access: String?
    var expiry = Date.distantPast
    init(config: TidalConfig, http: SpotifyHTTP = URLSessionSpotifyHTTP(), store: SpotifyTokenStore = KeychainTidalTokenStore()) {
        self.config = config; self.http = http; self.store = store
    }
    func exchange(code: String, verifier: String) async throws {
        try await token(["grant_type":"authorization_code", "client_id":config.clientID, "code":code,
                         "redirect_uri":config.redirectURI, "code_verifier":verifier])
    }
    func accessToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let access, Date() < expiry { return access }
        guard let refresh = store.loadRefreshToken() else { throw TidalAPIError.notConnected }
        try await token(["grant_type":"refresh_token", "client_id":config.clientID, "refresh_token":refresh])
        guard let access else { throw TidalAPIError.invalidResponse }; return access
    }
    private func token(_ form: [String:String]) async throws {
        guard config.isValid else { throw TidalAPIError.notConfigured }
        var request = URLRequest(url: URL(string: "https://auth.tidal.com/v1/oauth2/token")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = SpotifyTokenService.encode(form)
        let (data,response) = try await http.send(request)
        if response.statusCode == 400 || response.statusCode == 401 {
            access = nil; expiry = .distantPast
            if form["grant_type"] == "refresh_token" { store.clear() }
            throw TidalAPIError.notConnected
        }
        guard (200..<300).contains(response.statusCode) else { throw TidalAPIError.http(response.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String:Any],
              let token = json["access_token"] as? String, !token.isEmpty,
              let seconds = json["expires_in"] as? Double, seconds > 0 else { throw TidalAPIError.invalidResponse }
        access = token; expiry = Date().addingTimeInterval(max(0, seconds - 60))
        if let refresh = json["refresh_token"] as? String, !refresh.isEmpty { try store.saveRefreshToken(refresh) }
    }
}

/// Offizielle JSON:API. POST wird auch bei Verbindungsabbruch niemals automatisch wiederholt.
struct TidalPlaylistClient {
    let http: SpotifyHTTP
    let tokens: SpotifyTokenProviding
    var country = "DE"
    var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }

    func candidates(for track: DiscoverySong) async throws -> [ServiceTrackCandidate] {
        let query = [track.artist, track.title, track.version ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        guard !query.isEmpty else { return [] }
        let json = try await request("GET", "searchResults", query: ["filter[query]":String(query.prefix(256)), "include":"tracks,tracks.artists", "countryCode":country])
        var result = ServiceTrackCandidate.tidalTracks(in: json)
        // Manche Antworten enthalten nur Track-Verweise oder lassen verschachtelte Künstler aus.
        let roots = (json["data"] as? [[String:Any]]) ?? (json["data"] as? [String:Any]).map { [$0] } ?? []
        var ids: [String] = []
        for root in roots {
            let rel = root["relationships"] as? [String:Any]
            let tracks = rel?["tracks"] as? [String:Any]
            ids += (tracks?["data"] as? [[String:Any]] ?? []).compactMap { $0["id"] as? String }
        }
        for id in ids.prefix(10) where !result.contains(where: { $0.id == id }) {
            guard Self.validID(id) else { continue }
            let detail = try await request("GET", "tracks/" + id, query: ["countryCode":country,"include":"artists"])
            for candidate in ServiceTrackCandidate.tidalTracks(in: detail) where !result.contains(where: { $0.id == candidate.id }) { result.append(candidate) }
        }
        return ServiceTrackCandidate.relevant(for:track,in:result)
    }

    func create(name: String, trackIDs: [String]) async throws -> String {
        guard !trackIDs.isEmpty, trackIDs.allSatisfy(Self.validID) else { throw TidalAPIError.invalidResponse }
        let title = String(name.prefix(250))
        let json = try await request("POST", "playlists", body: ["data":["type":"playlists","attributes":["name":title,"accessType":"UNLISTED"]]])
        guard let data = json["data"] as? [String:Any], let id = data["id"] as? String, Self.validID(id) else { throw TidalAPIError.invalidResponse }
        var confirmed = 0
        do {
            for start in stride(from: 0, to: trackIDs.count, by: 50) {
                let chunk = Array(trackIDs[start..<min(start + 50, trackIDs.count)])
                let result = try await request("POST", "playlists/\(id)/relationships/items", body: ["data":chunk.map { ["id":$0,"type":"tracks"] }, "meta":["onDuplicates":"ADD"]])
                let skipped = ((result["meta"] as? [String:Any])?["skipped"] as? [[String:Any]]) ?? []
                let written = result["data"] as? [[String:Any]]
                // Die API bestätigt jede angehängte Wiederholung. Kein stummes Zählen des Requests als Erfolg.
                let actualIDs = written?.compactMap { $0["type"] as? String == "tracks" ? $0["id"] as? String : nil }
                guard skipped.isEmpty, actualIDs == chunk else {
                    throw TidalAPIError.partial(id:id, confirmed:confirmed)
                }
                confirmed += chunk.count
            }
        } catch { throw TidalAPIError.partial(id:id, confirmed:confirmed) }
        return id
    }

    static func validID(_ id: String) -> Bool { !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }
    private func request(_ method: String, _ path: String, query: [String:String] = [:], body: [String:Any]? = nil) async throws -> [String:Any] {
        var url = URLComponents(string: "https://openapi.tidal.com/v2/" + path)!
        if !query.isEmpty { url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name:$0.key,value:$0.value) } }
        var request = URLRequest(url:url.url!); request.httpMethod = method
        request.setValue("application/vnd.api+json", forHTTPHeaderField:"Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject:body)
            request.setValue("application/vnd.api+json", forHTTPHeaderField:"Content-Type")
        }
        var refreshed = false
        for attempt in 0..<3 {
            try Task.checkCancellation()
            request.setValue("Bearer \(try await tokens.accessToken(forceRefresh:refreshed))", forHTTPHeaderField:"Authorization")
            let data: Data, response: HTTPURLResponse
            do { (data,response) = try await http.send(request) }
            catch is CancellationError { throw CancellationError() }
            catch { throw TidalAPIError.network }
            if method == "GET", response.statusCode == 401, !refreshed { refreshed = true; continue }
            if method == "GET", (response.statusCode == 429 || response.statusCode >= 500), attempt < 2 {
                let retry = Double(response.value(forHTTPHeaderField:"Retry-After") ?? "") ?? Double(attempt + 1)
                try await sleep(min(15,max(0,retry.isFinite ? retry : 1))); continue
            }
            guard (200..<300).contains(response.statusCode) else { throw TidalAPIError.http(response.statusCode) }
            guard let json = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw TidalAPIError.invalidResponse }
            return json
        }
        throw TidalAPIError.notConnected
    }
}
