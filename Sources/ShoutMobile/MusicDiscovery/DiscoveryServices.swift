import Foundation
import MusicKit
import Combine

@MainActor
final class DiscoveryServices: ObservableObject, DiscoveryMusicServing {
    let spotify = SpotifyService()
    let tidal = TidalService()
    @Published private(set) var appleAuthorized = MusicAuthorization.currentStatus == .authorized
    private var appleSongs: [String: Song] = [:]

    func connectApple() async throws {
        appleAuthorized = await MusicAuthorization.request() == .authorized
        guard appleAuthorized else { throw DiscoveryError.notConnected("Apple Music") }
        do { _ = try await MusicDataRequest.tokenProvider.developerToken(options: .ignoreCache) }
        catch { throw DiscoveryError.notConnected("Apple Music – die MusicKit-Freigabe für SHOUT fehlt möglicherweise") }
    }
    func search(_ song: DiscoverySong, provider: DiscoveryProvider) async throws -> [ServiceTrackCandidate] {
        try Task.checkCancellation()
        switch provider {
        case .apple:
            if !appleAuthorized { try await connectApple() }
            var request = MusicCatalogSearchRequest(term: song.artist + " " + song.title, types: [Song.self])
            request.limit = 10
            let songs = Array(try await request.response().songs)
            for song in songs { appleSongs[song.id.rawValue] = song }
            return ServiceTrackCandidate.relevant(for: song, in: songs.map {
                ServiceTrackCandidate(id: $0.id.rawValue, title: $0.title, artist: $0.artistName,
                                      album: $0.albumTitle, seconds: $0.duration)
            })
        case .spotify:
            guard spotify.isConnected else { throw DiscoveryError.notConnected("Spotify") }
            return try await spotify.playlistCandidates(for: song)
        case .tidal:
            guard tidal.isConnected else { throw DiscoveryError.notConnected("TIDAL") }
            return try await tidal.playlistCandidates(for: song)
        }
    }
    /// Prüfen, bevor ein Exportbeleg geschrieben wird oder eine Playlist angelegt wird.
    func prepareExport(_ provider: DiscoveryProvider) async throws {
        switch provider {
        case .apple:
            try await connectApple()
            guard try await MusicSubscription.current.canPlayCatalogContent else {
                throw DiscoveryError.notConnected("Apple Music mit aktivem Abo")
            }
        case .spotify:
            guard spotify.isConnected else { throw DiscoveryError.notConnected("Spotify") }
        case .tidal:
            guard tidal.isConnected else { throw DiscoveryError.notConnected("TIDAL") }
        }
    }
    func create(name: String, provider: DiscoveryProvider, tracks: [ServiceTrackCandidate]) async throws -> URL? {
        guard !tracks.isEmpty else { throw DiscoveryError.noSelection }
        switch provider {
        case .apple:
            var songs: [Song] = []
            for track in tracks {
                if let song = appleSongs[track.id] { songs.append(song); continue }
                let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(track.id))
                guard let song = try await request.response().items.first else { throw DiscoveryError.invalidSelection }
                songs.append(song)
            }
            try Task.checkCancellation()
            let playlist = try await MusicLibrary.shared.createPlaylist(name: name,
                description: "In SHOUT erkannte und von dir bestätigte Titel", authorDisplayName: "SHOUT", items: songs)
            return playlist.url
        case .spotify:
            return try await spotify.createReviewedPlaylist(name: name, trackIDs: tracks.map(\.id))
        case .tidal:
            return try await tidal.createReviewedPlaylist(name: name, trackIDs: tracks.map(\.id))
        }
    }
}
