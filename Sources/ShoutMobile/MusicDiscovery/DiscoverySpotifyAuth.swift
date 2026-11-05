// PKCE- und Tokenkern aus DJ-Setpilot, für SHOUT isoliert.
import Foundation
import CryptoKit
import Security

/// Spotify-Anmeldung per Authorization Code mit PKCE (kein Client-Secret in der App).
/// Client-ID und Weiterleitung trägt Thomas lokal in den Einstellungen ein; es ist keine Registrierung eingebaut.
struct SpotifyConfig: Equatable {
    var clientID: String
    var redirectURI: String

    static var defaultRedirect: String {
        let scheme = "shout-music"
        return scheme + "://spotify"
    }
    /// Lesen eigener Playlists und Anlegen nicht öffentlicher Playlists.
    static let scopes = "playlist-read-private playlist-read-collaborative playlist-modify-private"

    var isValid: Bool {
        !clientID.trimmingCharacters(in: .whitespaces).isEmpty && callbackScheme != nil
    }

    var callbackScheme: String? {
        guard let u = URLComponents(string: redirectURI.trimmingCharacters(in: .whitespaces)),
              let s = u.scheme, !s.isEmpty else { return nil }
        return s
    }
}

enum SpotifyPKCE {
    /// 64 Zeichen aus dem erlaubten Alphabet (RFC 7636), kryptografisch zufällig.
    static func randomString(_ length: Int = 64) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { chars[Int($0) % chars.count] })
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func authorizeURL(config: SpotifyConfig, challenge: String, state: String) -> URL? {
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: config.clientID.trimmingCharacters(in: .whitespaces)),
            .init(name: "redirect_uri", value: config.redirectURI.trimmingCharacters(in: .whitespaces)),
            .init(name: "scope", value: SpotifyConfig.scopes),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
        ]
        return c.url
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Speicher für das Refresh-Token. Produktiv der Schlüsselbund, in Tests im Speicher.
protocol SpotifyTokenStore: Sendable {
    func loadRefreshToken() -> String?
    func saveRefreshToken(_ token: String) throws
    func clear()
}

struct KeychainSpotifyTokenStore: SpotifyTokenStore {
    private static let key = "spotify.refresh"
    func loadRefreshToken() -> String? { DiscoveryKeychain.read(Self.key) }
    func saveRefreshToken(_ token: String) throws { try DiscoveryKeychain.save(Self.key, token) }
    func clear() { DiscoveryKeychain.delete(Self.key) }
}

/// Tauscht den Code gegen Token und erneuert das Zugriffstoken. Das Zugriffstoken bleibt nur im Speicher,
/// das Refresh-Token nur im Schlüsselbund. Nichts davon wird protokolliert.
actor SpotifyTokenService: SpotifyTokenProviding {
    private let config: SpotifyConfig
    private let http: SpotifyHTTP
    private let store: SpotifyTokenStore
    private let now: @Sendable () -> Date
    private var access: String?
    private var expiry = Date.distantPast

    init(config: SpotifyConfig, http: SpotifyHTTP = URLSessionSpotifyHTTP(), store: SpotifyTokenStore = KeychainSpotifyTokenStore(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        self.http = http
        self.store = store
        self.now = now
    }

    var isSignedIn: Bool { store.loadRefreshToken() != nil }

    func exchange(code: String, verifier: String) async throws {
        try await requestToken(form: [
            "grant_type": "authorization_code", "code": code,
            "redirect_uri": config.redirectURI.trimmingCharacters(in: .whitespaces),
            "client_id": config.clientID.trimmingCharacters(in: .whitespaces),
            "code_verifier": verifier,
        ])
    }

    func accessToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let access, now() < expiry { return access }
        guard let refresh = store.loadRefreshToken() else { throw SpotifyImportError.notSignedIn }
        try await requestToken(form: [
            "grant_type": "refresh_token", "refresh_token": refresh,
            "client_id": config.clientID.trimmingCharacters(in: .whitespaces),
        ])
        guard let access else { throw SpotifyImportError.sessionExpired }
        return access
    }

    func signOut() {
        access = nil
        expiry = .distantPast
        store.clear()
    }

    private struct TokenResponse: Decodable {
        let access_token: String?
        let expires_in: Double?
        let refresh_token: String?
    }

    private func requestToken(form: [String: String]) async throws {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.encode(form)
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await http.send(req)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SpotifyImportError.network
        }
        switch response.statusCode {
        case 200..<300:
            guard let t = try? JSONDecoder().decode(TokenResponse.self, from: data), let token = t.access_token else {
                throw SpotifyImportError.invalidResponse
            }
            access = token
            expiry = now().addingTimeInterval((t.expires_in ?? 3600) - 60)
            // Spotify darf das Refresh-Token rotieren; bleibt es aus, gilt das alte weiter.
            if let r = t.refresh_token, !r.isEmpty { try store.saveRefreshToken(r) }
        case 400, 401:
            // Refresh-Token widerrufen/abgelaufen (invalid_grant) oder Client-ID falsch.
            access = nil
            if form["grant_type"] == "refresh_token" {
                store.clear()
                throw SpotifyImportError.sessionExpired
            }
            throw SpotifyImportError.http(response.statusCode, "Anmeldung abgelehnt – Client-ID und Weiterleitung prüfen")
        case 429, 500..<600:
            throw SpotifyImportError.http(response.statusCode, nil)
        default:
            throw SpotifyImportError.http(response.statusCode, nil)
        }
    }

    static func encode(_ form: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)!
    }
}

/// Prüft nur den Rücksprung; weder URL noch Anmeldecode werden protokolliert.
enum SpotifyCallback {
    static func code(from callback: URL, redirectURI: String, state: String) throws -> String {
        guard let expected = URLComponents(string: redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)),
              callback.scheme?.lowercased() == expected.scheme?.lowercased(),
              callback.host?.lowercased() == expected.host?.lowercased(),
              (callback.path == expected.path || (["", "/"].contains(callback.path) && ["", "/"].contains(expected.path))),
              callback.user == nil, callback.password == nil, callback.fragment == nil, callback.port == expected.port else {
            // Nur Schema und Host anzeigen, niemals Query, Fragment oder Anmeldecode.
            let received = (callback.scheme ?? "?") + "://" + (callback.host ?? "?")
            throw SpotifyImportError.authentication("Rücksprungadresse stimmt nicht (Ziel: \(received)). In Spotify und SHOUT muss dieselbe Redirect URI stehen.")
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state else {
            throw SpotifyImportError.authentication("Sicherheitsprüfung des Rücksprungs fehlgeschlagen. Bitte neu verbinden.")
        }
        if let error = items.first(where: { $0.name == "error" })?.value {
            switch error {
            case "access_denied": throw SpotifyImportError.authentication("Spotify hat den Zugriff abgelehnt. Premium-Konto und Freischaltung unter Users and Access prüfen.")
            case "invalid_scope": throw SpotifyImportError.authentication("Spotify akzeptiert die angefragten Berechtigungen nicht.")
            default: throw SpotifyImportError.authentication("Spotify hat keine Freigabe erteilt. Kontofreischaltung und App-Einstellungen prüfen.")
            }
        }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw SpotifyImportError.authentication("Spotify hat keinen Anmeldecode zurückgegeben.")
        }
        return code
    }
}
