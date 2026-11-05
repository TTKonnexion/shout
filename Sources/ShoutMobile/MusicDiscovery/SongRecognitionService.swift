import Foundation
import AVFAudio
import ShazamKit

/// SHManagedSession-Ablauf aus DJ-Setpilot mit SHOUT-Mikrofonsperre.
@MainActor
final class SongRecognitionService: ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var song: DiscoverySong?
    @Published private(set) var message: String?
    private var session: SHManagedSession?
    private var operation: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var attempt: UUID?
    private var audioSettings: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

    func start(canStart: @escaping @MainActor () -> Bool) {
        guard !listening else { return }
        guard canStart() else { message = "Beende zuerst die laufende Aufnahme oder Verarbeitung."; return }
        cancel()
        let id = UUID(); attempt = id; listening = true; song = nil; message = nil
        operation = Task { [weak self] in
            let allowed = await AVAudioApplication.requestRecordPermission()
            guard let self, self.attempt == id, !Task.isCancelled else { return }
            guard allowed else { self.finish(id, message: "Bitte das Mikrofon in den Geräteeinstellungen für SHOUT erlauben."); return }
            guard canStart() else { self.finish(id, message: "Eine andere Aufnahme oder Verarbeitung läuft bereits."); return }
            let audio = AVAudioSession.sharedInstance()
            self.audioSettings = (audio.category, audio.mode, audio.categoryOptions)
            let session = SHManagedSession(); self.session = session
            self.timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                self?.finish(id, message: "Innerhalb von 20 Sekunden keinen Titel erkannt. Versuche es näher an der Musik erneut.")
            }
            switch await session.result() {
            case .match(let match):
                guard self.attempt == id, !Task.isCancelled else { return }
                self.song = match.mediaItems.compactMap {
                    DiscoverySong.recognized(title: $0.title, artist: $0.artist, shazamID: $0.shazamID)
                }.first
                self.finish(id, message: self.song == nil ? "Der Treffer enthält keinen vollständigen Titel und Interpreten." : nil)
            case .noMatch: self.finish(id, message: "Keinen Titel erkannt. Bitte erneut versuchen.")
            case .error: self.finish(id, message: "Shazam ist nicht erreichbar. Prüfe die Verbindung und die ShazamKit-Freigabe für SHOUT.")
            @unknown default: self.finish(id, message: "Die Erkennung konnte nicht abgeschlossen werden.")
            }
        }
    }
    func cancel() {
        attempt = nil; session?.cancel(); session = nil
        operation?.cancel(); operation = nil; timeout?.cancel(); timeout = nil
        listening = false
        if let settings = audioSettings {
            audioSettings = nil
            let audio = AVAudioSession.sharedInstance()
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            try? audio.setCategory(settings.0, mode: settings.1, options: settings.2)
        }
    }
    private func finish(_ id: UUID, message: String?) {
        guard attempt == id else { return }; self.message = message; cancel()
    }
}
