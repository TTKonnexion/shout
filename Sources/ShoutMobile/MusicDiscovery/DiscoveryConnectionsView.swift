import SwiftUI
import MusicKit

struct DiscoveryConnectionsView: View {
    @ObservedObject var services: DiscoveryServices
    @ObservedObject var spotify: SpotifyService
    @ObservedObject var tidal: TidalService
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var appleConnecting = false

    init(services: DiscoveryServices) {
        self.services = services; spotify = services.spotify; tidal = services.tidal
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Apple Music · erster Suchdienst") {
                    Label(services.appleAuthorized ? "Zugriff erlaubt" : "Noch nicht freigegeben",
                          systemImage: services.appleAuthorized ? "checkmark.circle" : "music.note")
                    Button(appleConnecting ? "Verbinde …" : "Apple Music freigeben") {
                        appleConnecting = true
                        Task {
                            defer { appleConnecting = false }
                            do { try await services.connectApple(); message = "Apple-Music-Zugriff bestätigt." }
                            catch { message = error.localizedDescription }
                        }
                    }
                    .disabled(appleConnecting)
                    Text("Die Suche beginnt bei Apple Music. Zum Erstellen einer Playlist benötigst du die Freigabe deiner Mediathek und ein aktives Apple-Music-Abo.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Spotify · weitere Suchmöglichkeit") {
                    Label(spotify.isConnected ? "Verbunden" : "Nicht verbunden", systemImage: spotify.isConnected ? "checkmark.circle" : "link")
                    if spotify.isConnected {
                        Button("Spotify trennen", role: .destructive) { spotify.disconnect() }
                    } else {
                        Button(spotify.isConnecting ? "Verbinde …" : "Mit Spotify verbinden") {
                            Task { do { try await spotify.connect(); message = "Spotify verbunden." } catch { message = error.localizedDescription } }
                        }
                        .disabled(spotify.isConnecting || !spotify.hasUsableConfiguration)
                    }
                    DisclosureGroup("Einmalige App-Einrichtung") {
                        TextField("Öffentliche Client-ID", text: $spotify.clientID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("Weiterleitung im Spotify-Entwicklerkonto:").font(.caption)
                        Text(SpotifyConfig.defaultRedirect).font(.footnote).textSelection(.enabled)
                        Text("Verwende eine für SHOUT eingerichtete Anmeldung. Hier wird kein Spotify-Passwort eingetragen.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .disabled(spotify.isConnecting)
                }
                Section("TIDAL · weitere Suchmöglichkeit") {
                    Label(tidal.isConnected ? "Verbunden" : "Nicht verbunden", systemImage: tidal.isConnected ? "checkmark.circle" : "link")
                    if tidal.isConnected {
                        Button("TIDAL trennen", role: .destructive) { tidal.disconnect() }
                    } else {
                        Button(tidal.isConnecting ? "Verbinde …" : "Mit TIDAL verbinden") {
                            Task { do { try await tidal.connect(); message = "TIDAL verbunden." } catch { message = error.localizedDescription } }
                        }
                        .disabled(tidal.isConnecting || tidal.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    DisclosureGroup("Einmalige App-Einrichtung") {
                        TextField("Öffentliche Client-ID", text: $tidal.clientID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("Weiterleitung im TIDAL-Entwicklerkonto:").font(.caption)
                        Text(TidalService.redirectURI).font(.footnote).textSelection(.enabled)
                        TextField("Ländercode", text: $tidal.countryCode).textInputAutocapitalization(.characters)
                    }
                    .disabled(tidal.isConnecting)
                }
                if let message { Section { Text(message).font(.footnote) } }
            }
            .navigationTitle("Musikdienste")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() }
                .disabled(appleConnecting || spotify.isConnecting || tidal.isConnecting) } }
            .interactiveDismissDisabled(appleConnecting || spotify.isConnecting || tidal.isConnecting)
        }
        .tint(Color.shoutLive)
    }
}
