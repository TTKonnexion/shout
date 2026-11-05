// Dienstanmeldung und Export aus DJ-Setpilot; eigener SHOUT-Speicher.
import Foundation
import AuthenticationServices
import UIKit
import Security

/// Anmeldung und testbarer TIDAL-Export mit derselben Trefferprüfung wie Spotify.
@MainActor
final class TidalService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static var redirectURI: String {
        let scheme = "shout-music"
        return scheme + "://tidal"
    }
    @Published var clientID = StreamingClientConfiguration.clientID(bundled:Bundle.main.object(forInfoDictionaryKey:"ShoutTidalClientID") as? String,saved:UserDefaults.standard.string(forKey:"music.tidalClientID")) {
        didSet {
            UserDefaults.standard.set(clientID.trimmingCharacters(in:.whitespacesAndNewlines),forKey:"music.tidalClientID")
            if oldValue != clientID { disconnect() }
        }
    }
    @Published var countryCode = UserDefaults.standard.string(forKey:"music.tidalCountry") ?? "DE" {
        didSet { UserDefaults.standard.set(countryCode,forKey:"music.tidalCountry") }
    }
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var lookupErrors: [String] = []
    private var authSession: ASWebAuthenticationSession?
    private var cached: (TidalConfig,TidalTokenService)?
    private var config: TidalConfig { TidalConfig(clientID:clientID.trimmingCharacters(in:.whitespacesAndNewlines),redirectURI:Self.redirectURI) }
    private var binding: String { config.clientID + "|" + config.redirectURI }
    private var country: String {
        let code = countryCode.trimmingCharacters(in:.whitespacesAndNewlines).uppercased()
        return code.count == 2 && code.allSatisfy({ $0.isASCII && $0.isLetter }) ? code : "DE"
    }
    override init() {
        super.init()
        isConnected = DiscoveryKeychain.read("tidal.refresh") != nil && UserDefaults.standard.string(forKey:"music.tidalSessionConfig") == binding
    }
    private var tokens: TidalTokenService {
        if let cached, cached.0 == config { return cached.1 }
        let service = TidalTokenService(config:config); cached = (config,service); return service
    }
    private var client: TidalPlaylistClient { TidalPlaylistClient(http:URLSessionSpotifyHTTP(),tokens:tokens,country:country) }

    func connect() async throws {
        
        guard !isConnecting else { throw TidalAPIError.authentication }
        guard config.isValid else { throw TidalAPIError.notConfigured }
        isConnecting = true
        let config = self.config
        defer { isConnecting = false; authSession = nil }
        let verifier = SpotifyPKCE.randomString(), state = SpotifyPKCE.randomString(32)
        let url = try config.authorizationURL(verifier:verifier,state:state)
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url:url,callbackURLScheme:URL(string:config.redirectURI)?.scheme) { url,_ in
                if let url { continuation.resume(returning:url) }
                else { continuation.resume(throwing:TidalAPIError.authentication) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            authSession = session
            if !session.start() { continuation.resume(throwing:TidalAPIError.authentication) }
        }
        try Task.checkCancellation()
        guard config == self.config else { throw TidalAPIError.authentication }
        try await tokens.exchange(code:config.code(from:callback,state:state),verifier:verifier)
        guard config == self.config else { disconnect(); throw TidalAPIError.authentication }
        UserDefaults.standard.set(binding,forKey:"music.tidalSessionConfig")
        isConnected = true
    }
    func disconnect() {
        authSession?.cancel()
        KeychainTidalTokenStore().clear(); cached = nil; isConnected = false
        UserDefaults.standard.removeObject(forKey:"music.tidalSessionConfig")
    }
    func prepareExport() async throws {
        
        if !isConnected { try await connect() }
    }
    func playlistCandidates(for track: DiscoverySong) async throws -> [ServiceTrackCandidate] {
        
        guard isConnected else { throw TidalAPIError.notConnected }
        do { return try await client.candidates(for:track) }
        catch TidalAPIError.notConnected { disconnect(); throw TidalAPIError.notConnected }
    }
    @discardableResult
    func createReviewedPlaylist(name: String, trackIDs: [String]) async throws -> URL {
        
        guard isConnected else { throw TidalAPIError.notConnected }
        let id = try await client.create(name:name,trackIDs:trackIDs)
        return URL(string:"https://tidal.com/browse/playlist/" + id)!
    }
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor() }
    }
}

