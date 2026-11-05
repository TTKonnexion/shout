// Dienstanmeldung und Export aus DJ-Setpilot; eigener SHOUT-Speicher.
import Foundation
import AuthenticationServices
import UIKit

/// Oberfläche für Spotify: Einstellungen, Anmelden (ASWebAuthenticationSession) und Playlist-Import.
@MainActor
final class SpotifyService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published var clientID = StreamingClientConfiguration.clientID(bundled:Bundle.main.object(forInfoDictionaryKey:"ShoutSpotifyClientID") as? String,saved:UserDefaults.standard.string(forKey:"music.spotifyClientID")) {
        didSet {
            UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespaces), forKey: "music.spotifyClientID")
            if oldValue != clientID { disconnect() }
        }
    }
    @Published var redirectURI = UserDefaults.standard.string(forKey: "music.spotifyRedirectURI") ?? SpotifyConfig.defaultRedirect {
        didSet {
            UserDefaults.standard.set(redirectURI.trimmingCharacters(in: .whitespaces), forKey: "music.spotifyRedirectURI")
            if oldValue != redirectURI { disconnect() }
        }
    }
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false

    @Published private(set) var canExport = UserDefaults.standard.bool(forKey: "music.spotifyExportGranted")

    private var authSession: ASWebAuthenticationSession?

    var config: SpotifyConfig { SpotifyConfig(clientID: clientID.trimmingCharacters(in:.whitespacesAndNewlines), redirectURI: redirectURI.trimmingCharacters(in:.whitespacesAndNewlines)) }
    private var binding: String { config.clientID + "|" + config.redirectURI }
    var hasUsableConfiguration: Bool { config.isValid && config.redirectURI == SpotifyConfig.defaultRedirect }
    override init() {
        super.init()
        isConnected = KeychainSpotifyTokenStore().loadRefreshToken() != nil && UserDefaults.standard.string(forKey:"music.spotifySessionConfig") == binding
        canExport = canExport && isConnected
    }

    private var cachedService: (config: SpotifyConfig, service: SpotifyTokenService)?

    /// Ein Dienst pro Konfiguration, damit das Zugriffstoken im Speicher wiederverwendet wird.
    private var tokenService: SpotifyTokenService {
        if let c = cachedService, c.config == config { return c.service }
        let service = SpotifyTokenService(config: config)
        cachedService = (config, service)
        return service
    }

    func connect() async throws {
        
        guard !isConnecting else { throw SpotifyImportError.authentication("Eine Anmeldung läuft bereits.") }
        isConnecting = true
        defer { authSession = nil; isConnecting = false }
        let config = self.config
        guard hasUsableConfiguration, let scheme = config.callbackScheme else { throw SpotifyImportError.notConfigured }
        let verifier = SpotifyPKCE.randomString()
        let state = SpotifyPKCE.randomString(16)
        guard let url = SpotifyPKCE.authorizeURL(config: config, challenge: SpotifyPKCE.challenge(for: verifier), state: state) else {
            throw SpotifyImportError.notConfigured
        }
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { url, error in
                if let url { cont.resume(returning: url) }
                else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                    cont.resume(throwing: SpotifyImportError.authentication("Das Anmeldefenster wurde geschlossen oder der Rücksprung unterbrochen. Bitte erneut anmelden."))
                } else {
                    cont.resume(throwing: SpotifyImportError.authentication("Das Gerät konnte die Browser-Anmeldung nicht abschließen."))
                }
            }
            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = self
            authSession = session
            if !session.start() { cont.resume(throwing: SpotifyImportError.authentication("Das Anmeldefenster konnte nicht geöffnet werden.")) }
        }
        guard !Task.isCancelled else { throw SpotifyImportError.cancelled }
        let code = try SpotifyCallback.code(from: callback, redirectURI: config.redirectURI, state: state)
        guard config == self.config else { throw SpotifyImportError.sessionExpired }
        try await tokenService.exchange(code: code, verifier: verifier)
        guard config == self.config else { disconnect(); throw SpotifyImportError.sessionExpired }
        UserDefaults.standard.set(binding,forKey:"music.spotifySessionConfig")
        isConnected = true
        canExport = true
        UserDefaults.standard.set(true, forKey: "music.spotifyExportGranted")
    }

    func disconnect() {
        authSession?.cancel()
        UserDefaults.standard.removeObject(forKey:"music.spotifySessionConfig")
        KeychainSpotifyTokenStore().clear()
        cachedService = nil
        isConnected = false
        canExport = false
        UserDefaults.standard.removeObject(forKey: "music.spotifyExportGranted")
    }

    func prepareExport() async throws {
        
        if !isConnected || !canExport { try await connect() }
    }

    func playlistCandidates(for track: DiscoverySong) async throws -> [ServiceTrackCandidate] {
        
        guard isConnected, canExport else { throw SpotifyImportError.notSignedIn }
        return try await SpotifyPlaylistExportClient(http: URLSessionSpotifyHTTP(), tokens: tokenService).candidates(for: track)
    }

    @discardableResult
    func createReviewedPlaylist(name: String, trackIDs: [String]) async throws -> URL {
        
        guard isConnected, canExport else { throw SpotifyImportError.notSignedIn }
        let id = try await SpotifyPlaylistExportClient(http: URLSessionSpotifyHTTP(), tokens: tokenService).create(name: name, uris: trackIDs)
        return URL(string:"https://open.spotify.com/playlist/" + id)!
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}
