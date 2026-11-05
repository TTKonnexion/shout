import Foundation

/// Fehler beim Einlesen einer Spotify-Playlist. Die Texte sind für Thomas gedacht.
enum SpotifyImportError: LocalizedError, Equatable {
    case emptyInput, invalidLink
    case notConfigured, notSignedIn, sessionExpired
    case forbidden, notFound, rateLimited
    case http(Int, String?)
    case network, invalidResponse
    case incomplete(expected: Int, received: Int)
    case emptyPlaylist
    case cancelled
    case authentication(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            "Bitte den Link der Spotify-Playlist einfügen."
        case .invalidLink:
            "Das ist kein Spotify-Playlist-Link. Erwartet wird z. B. „https://open.spotify.com/playlist/…“ oder „spotify:playlist:…“. Kurzlinks (spotify.link) bitte im Browser öffnen und den langen Link verwenden."
        case .notConfigured:
            "Spotify ist noch nicht eingerichtet: Client-ID und Weiterleitung fehlen (Einstellungen › Spotify)."
        case .notSignedIn:
            "Du bist nicht bei Spotify angemeldet."
        case .sessionExpired:
            "Die Spotify-Anmeldung ist abgelaufen. Bitte neu anmelden und den Link noch einmal laden."
        case .forbidden:
            "Spotify gibt den Inhalt dieser Playlist nicht frei. Die Schnittstelle liefert Titel nur für Playlists, die dir gehören oder an denen du mitarbeitest. Kopiere die Kundenplaylist zuerst in dein Spotify-Konto (Playlist öffnen › „⋯“ › „Zu anderer Playlist hinzufügen“ › „Neue Playlist“) und füge den Link der Kopie ein. Alternativ ist dein Konto in der Spotify-App nicht freigeschaltet oder die Berechtigung fehlt – dann neu anmelden."
        case .notFound:
            "Spotify findet diese Playlist nicht. Der Link ist veraltet, die Playlist gelöscht oder privat."
        case .rateLimited:
            "Spotify bremst gerade (zu viele Anfragen). Bitte in ein paar Minuten noch einmal versuchen."
        case .http(let code, let text):
            "Spotify antwortet mit Fehler \(code)" + (text.map { ": \($0)" } ?? ".")
        case .network:
            "Keine Verbindung zu Spotify. Internet prüfen und noch einmal versuchen."
        case .invalidResponse:
            "Spotify hat eine unerwartete Antwort geliefert."
        case .incomplete(let expected, let received):
            "Die Playlist konnte nicht vollständig geladen werden (\(received) von \(expected) Titeln). Es wurde nichts übernommen – bitte noch einmal versuchen."
        case .emptyPlaylist:
            "Die Playlist enthält keine importierbaren Titel."
        case .authentication(let reason):
            "Spotify-Anmeldung fehlgeschlagen: \(reason)"
        case .cancelled:
            "Abgebrochen."
        }
    }
}

protocol SpotifyHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
struct URLSessionSpotifyHTTP: SpotifyHTTP {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SpotifyImportError.invalidResponse }
        return (data, response)
    }
}
protocol SpotifyTokenProviding: Sendable {
    func accessToken(forceRefresh: Bool) async throws -> String
}
