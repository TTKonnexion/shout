import Foundation

/// Ziele nach der Aufnahme: Ein Diktat kann außer als Text auch an einen
/// selbst betriebenen Dienst im eigenen Netz gehen — als **Handlung**
/// („Termin Montag 14 Uhr …“) oder als **Frage**, auf die eine Antwort kommt.
///
/// Der Dienst nimmt `POST /sprache` an und liefert das Ergebnis über
/// `GET /sprache/<id>` (lange gehalten, ~55 s). Drei Festlegungen:
///
/// 1. **Die `id` entsteht beim ersten Versuch** und bleibt bei jeder
///    Wiederholung dieselbe. Der Dienst erkennt sie wieder und verarbeitet
///    nichts doppelt — deshalb darf die Warteschlange ruhig zu oft senden.
/// 2. **Nichts geht verloren:** Was nicht angekommen ist, bleibt `wartet`, bis
///    es angekommen ist. Gekürzt wird der Verlauf nur bei erledigten Einträgen.
/// 3. **Kein Gerätewort im Klartext:** Es liegt in der Keychain und steht weder
///    im Protokoll noch in der Ablage.
enum DictationTarget: String, Codable, CaseIterable, Sendable {
    /// Wie bisher: nur Text (Zwischenablage, Tastatur). Geht nie ans Netz.
    case text
    /// Der Dienst soll etwas erledigen (Termin, Erinnerung, Notiz).
    case aktion
    /// Der Dienst soll antworten.
    case frage
}

// MARK: - Einstellungen

enum TargetSettings {
    static let enabledKey = "targetsEnabled"
    static let addressKey = "targetsAddress"
    static let lastTargetKey = "targetsLast"

    /// Keychain-Ablage des Gerätewortes — getrennt von den Anbieter-Schlüsseln.
    static let keychainService = "de.thull24.shout.ziele"
    static let keychainAccount = "geraetewort"

    static func token() -> String? {
        ProviderKeychain.read(for: keychainAccount, service: keychainService)
    }

    static func storeToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try ProviderKeychain.delete(for: keychainAccount, service: keychainService)
        } else {
            try ProviderKeychain.store(trimmed, for: keychainAccount, service: keychainService)
        }
    }

    /// Macht aus der Eingabe eine Basis-Adresse: ohne Schema kommt `http://`
    /// davor (im eigenen Netz der Normalfall), ein Schrägstrich am Ende fällt weg.
    /// `nil`, wenn sich daraus keine Adresse mit Rechnername bauen lässt.
    static func normalizedBase(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }
}

// MARK: - Antworten des Dienstes

/// Vorschlag des Dienstes zu einer Handlung. Alle Felder sind optional — der
/// Dienst lässt weg, was er nicht erkannt hat.
struct TargetProposal: Codable, Equatable, Sendable {
    var art: String?
    var titel: String?
    var datum: String?
    var uhrzeit: String?
    var ort: String?
}

/// Antwort von `GET /sprache/<id>`.
struct TargetStatusResponse: Codable, Equatable, Sendable {
    var id: String
    var status: String
    var ziel: String?
    var text: String?
    var vorschlag: TargetProposal?
    var bestaetigt: String?

    var isFinished: Bool { status == "fertig" || status == "fehler" }
}

/// Antwort von `POST /sprache`.
struct TargetAcceptResponse: Codable, Equatable, Sendable {
    var id: String
    var status: String
    var doppelt: Bool?
}

enum TargetError: Error, Equatable, Sendable {
    /// Keine Adresse eingetragen oder nicht lesbar.
    case notConfigured
    /// Kein Gerätewort hinterlegt.
    case missingToken
    /// 401 — der Dienst sagt bewusst nicht, warum.
    case unauthorized
    /// Keine Verbindung (kein Netz, Tailnet aus, Rechner aus).
    case unreachable
    /// Verbindung da, aber keine oder eine unbrauchbare Antwort.
    case noResponse
    /// Sonstiger HTTP-Status.
    case server(Int)
}

/// Gerade Abbildung von `URLError` auf die drei Fälle, die der Nutzer
/// unterscheiden kann. Zeitüberschreitung heißt: Etwas hat angenommen, aber
/// nicht geantwortet — das ist ein anderer Rat als „Netz prüfen“.
extension TargetError {
    static func from(_ error: Error) -> TargetError {
        if let own = error as? TargetError { return own }
        guard let urlError = error as? URLError else { return .unreachable }
        switch urlError.code {
        case .timedOut, .badServerResponse, .cannotParseResponse, .zeroByteResource:
            return .noResponse
        default:
            return .unreachable
        }
    }
}

// MARK: - Netz

/// Spricht mit dem Dienst. Kennt keine Warteschlange und keinen Zustand.
struct TargetClient: Sendable {
    let base: URL
    let token: String
    var session: URLSession = .shared
    /// Länger als die ~55 s, die der Dienst eine Abfrage offen hält.
    var pollTimeout: TimeInterval = 70
    var postTimeout: TimeInterval = 20

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func submit(id: String, ziel: DictationTarget, text: String,
                quelle: String, zeit: Date) async throws -> TargetAcceptResponse {
        var request = URLRequest(url: base.appendingPathComponent("sprache"))
        request.httpMethod = "POST"
        request.timeoutInterval = postTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-TTBrain-Token")
        let body: [String: String] = [
            "ziel": ziel.rawValue, "text": text, "quelle": quelle,
            "zeit": Self.iso.string(from: zeit), "id": id,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return try await perform(request, as: TargetAcceptResponse.self)
    }

    func status(id: String) async throws -> TargetStatusResponse {
        var request = URLRequest(url: base.appendingPathComponent("sprache").appendingPathComponent(id))
        request.httpMethod = "GET"
        request.timeoutInterval = pollTimeout
        request.setValue(token, forHTTPHeaderField: "X-TTBrain-Token")
        return try await perform(request, as: TargetStatusResponse.self)
    }

    private func perform<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TargetError.from(error)
        }
        guard let http = response as? HTTPURLResponse else { throw TargetError.noResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw TargetError.unauthorized
        default: throw TargetError.server(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TargetError.noResponse
        }
    }
}

// MARK: - Einträge

struct TargetItem: Codable, Identifiable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        /// Noch nicht beim Dienst angekommen — wird erneut gesendet.
        case wartet
        /// Unterwegs oder in Bearbeitung.
        case laeuft
        /// Ergebnis da.
        case fertig
        /// Der Dienst hat gemeldet, dass es nicht ging.
        case fehler
        /// Vom Nutzer abgebrochen. Nicht automatisch erneut, aber per Hand.
        case abgebrochen
    }

    let id: String
    let ziel: DictationTarget
    let text: String
    let zeit: Date
    var status: Status
    /// Hat der Dienst die Sendung bestätigt? Dann wäre ein neuer Versuch
    /// nur noch eine Abfrage — gesendet wird trotzdem, das schadet nicht.
    var angenommen: Bool = false
    var ergebnis: String?
    var vorschlag: TargetProposal?
    /// Letzter Fehler beim Senden/Abfragen, für die Anzeige.
    var letzterFehler: TargetError?

    /// Soll die Warteschlange es von selbst erneut versuchen?
    var isPending: Bool { status == .wartet }
}

extension TargetError: Codable {
    private enum Kind: String, Codable { case notConfigured, missingToken, unauthorized, unreachable, noResponse, server }
    private enum Keys: String, CodingKey { case kind, status }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .notConfigured: self = .notConfigured
        case .missingToken: self = .missingToken
        case .unauthorized: self = .unauthorized
        case .unreachable: self = .unreachable
        case .noResponse: self = .noResponse
        case .server: self = .server(try c.decodeIfPresent(Int.self, forKey: .status) ?? 0)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .notConfigured: try c.encode(Kind.notConfigured, forKey: .kind)
        case .missingToken: try c.encode(Kind.missingToken, forKey: .kind)
        case .unauthorized: try c.encode(Kind.unauthorized, forKey: .kind)
        case .unreachable: try c.encode(Kind.unreachable, forKey: .kind)
        case .noResponse: try c.encode(Kind.noResponse, forKey: .kind)
        case .server(let status):
            try c.encode(Kind.server, forKey: .kind)
            try c.encode(status, forKey: .status)
        }
    }
}

// MARK: - Anzeige einer Handlung

enum TargetSummary {
    /// Eine Zeile aus dem Vorschlag, z. B.
    /// „Termin 20.10. 14:00 Werkstatt Müller“. `nil`, wenn nichts darin steht.
    static func line(for proposal: TargetProposal?) -> String? {
        guard let p = proposal else { return nil }
        let kind = p.art.map(artLabel)
        let parts = [kind, p.datum.map(shortDate), p.uhrzeit, p.titel, p.ort]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// „termin“ → „Termin“; Unbekanntes bleibt, nur großgeschrieben.
    static func artLabel(_ art: String) -> String {
        switch art.lowercased() {
        case "termin": return "Termin"
        case "erinnerung": return "Erinnerung"
        case "notiz": return "Notiz"
        default: return art.prefix(1).uppercased() + art.dropFirst()
        }
    }

    /// „2026-10-20“ → „20.10.“; alles andere bleibt, wie es kam.
    static func shortDate(_ raw: String) -> String {
        let parts = raw.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4,
              let month = Int(parts[1]), let day = Int(parts[2])
        else { return raw }
        return String(format: "%02d.%02d.", day, month)
    }
}

// MARK: - Ablage

/// Warteschlange und Verlauf in einem: eine Liste, neueste zuerst.
/// Gekürzt wird nur, was erledigt ist — wartende Diktate fallen nie heraus.
struct TargetLog: Codable, Equatable, Sendable {
    static let historyLimit = 20

    var items: [TargetItem] = []

    var pending: [TargetItem] { items.filter(\.isPending) }

    mutating func insert(_ item: TargetItem) {
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        trim()
    }

    mutating func update(_ id: String, _ change: (inout TargetItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    mutating func remove(_ id: String) { items.removeAll { $0.id == id } }

    /// „Verlauf löschen“: Erledigtes weg, Wartendes bleibt — sonst wäre es
    /// ein stilles Verwerfen.
    mutating func clearFinished() { items.removeAll { !$0.isPending && $0.status != .laeuft } }

    mutating func trim() {
        var finished = 0
        items.removeAll { item in
            guard !item.isPending, item.status != .laeuft else { return false }
            finished += 1
            return finished > Self.historyLimit
        }
    }

    static func load(from url: URL) -> TargetLog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var log = StoreIO.load(TargetLog.self, from: url, decoder: decoder) ?? TargetLog()
        // Was beim Beenden unterwegs war, ist nicht verloren, sondern wartet.
        for index in log.items.indices where log.items[index].status == .laeuft {
            log.items[index].status = .wartet
        }
        return log
    }

    func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        StoreIO.save(self, to: url, encoder: encoder)
    }
}

// MARK: - Ablauf

/// Führt Senden, Abfragen, Warteschlange und Verlauf zusammen. Die Oberfläche
/// beobachtet nur `log`, `offeredText` und `activeID`.
@MainActor
final class TargetDispatcher: ObservableObject {

    @Published private(set) var log: TargetLog
    /// Frisches Diktat, für das noch kein Ziel gewählt ist.
    @Published private(set) var offeredText: String?
    /// Der Eintrag, den die Startseite gerade zeigt.
    @Published private(set) var activeID: String?

    private let storeURL: URL?
    private let quelle: String
    private let makeClient: () throws -> TargetClient
    private var running: [String: Task<Void, Never>] = [:]
    private var runIDs: [String: UUID] = [:]
    /// Höchstdauer, die eine Bearbeitung beim Dienst dauern darf, bevor die
    /// App aufhört zu fragen (der Eintrag bleibt abrufbar).
    var maxWait: TimeInterval = 15 * 60
    /// Pause zwischen zwei Abfragen, falls der Dienst sofort „laeuft“ meldet.
    var pollPause: UInt64 = 1_000_000_000
    /// Erste Pause vor einem selbsttätigen neuen Versuch; danach jeweils
    /// verdoppelt bis `retryMax`. Grund: Nach dem Flugmodus meldet iOS „Netz
    /// da“, bevor das Tailnet wieder steht — der erste Versuch scheitert dann.
    var retryBase: TimeInterval = 5
    var retryMax: TimeInterval = 60
    var defaults: UserDefaults
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0

    init(storeURL: URL?, quelle: String, defaults: UserDefaults = .standard,
         makeClient: @escaping () throws -> TargetClient) {
        self.storeURL = storeURL
        self.quelle = quelle
        self.defaults = defaults
        self.makeClient = makeClient
        self.log = storeURL.map(TargetLog.load(from:)) ?? TargetLog()
    }

    /// Standard-Aufbau aus Einstellungen und Keychain.
    static func defaultClient(session: URLSession = .shared,
                              defaults: UserDefaults = .standard) throws -> TargetClient {
        guard let base = TargetSettings.normalizedBase(defaults.string(forKey: TargetSettings.addressKey) ?? "")
        else { throw TargetError.notConfigured }
        guard let token = TargetSettings.token() else { throw TargetError.missingToken }
        return TargetClient(base: base, token: token, session: session)
    }

    var isEnabled: Bool { defaults.bool(forKey: TargetSettings.enabledKey) }

    var lastTarget: DictationTarget {
        DictationTarget(rawValue: defaults.string(forKey: TargetSettings.lastTargetKey) ?? "") ?? .text
    }

    var activeItem: TargetItem? { activeID.flatMap(item) }

    func item(_ id: String) -> TargetItem? { log.items.first { $0.id == id } }

    // MARK: Auswahl

    /// Neues Diktat da: Ziel anbieten (nur wenn eingeschaltet).
    func offer(_ text: String) {
        guard isEnabled else { offeredText = nil; return }
        offeredText = text
        activeID = nil
    }

    func dismissOffer() { offeredText = nil }

    /// Ziel gewählt. „Text“ ändert nichts am bisherigen Weg — das Diktat ist
    /// da schon in der Zwischenablage.
    @discardableResult
    func choose(_ ziel: DictationTarget) -> String? {
        guard let text = offeredText else { return nil }
        defaults.set(ziel.rawValue, forKey: TargetSettings.lastTargetKey)
        offeredText = nil
        guard ziel != .text else { return nil }
        return submit(text, to: ziel)
    }

    /// Legt den Eintrag an (mit fester `id`) und sendet ihn.
    @discardableResult
    func submit(_ text: String, to ziel: DictationTarget, id: String = UUID().uuidString,
                at zeit: Date = Date()) -> String {
        let item = TargetItem(id: id, ziel: ziel, text: text, zeit: zeit, status: .wartet)
        log.insert(item)
        persist()
        activeID = id
        deliver(id)
        return id
    }

    // MARK: Senden

    /// Sendet (bzw. fragt ab). Läuft für diese `id` schon ein Vorgang, passiert
    /// nichts — zweimal „Senden“ ergibt einen Vorgang.
    func deliver(_ id: String) {
        guard running[id] == nil, let current = item(id),
              current.status != .fertig, current.status != .fehler else { return }
        log.update(id) { $0.status = .laeuft; $0.letzterFehler = nil }
        persist()
        let run = UUID()
        runIDs[id] = run
        running[id] = Task { [weak self] in
            await self?.run(id)
            // Nur den eigenen Eintrag räumen: Nach Abbrechen + neuem Senden
            // gehört `running[id]` schon dem nächsten Vorgang.
            if self?.runIDs[id] == run { self?.running[id] = nil; self?.runIDs[id] = nil }
        }
    }

    /// Alles Wartende erneut — beim Start, beim Zurückkehren in die App und
    /// wenn das Netz wieder da ist.
    func retryPending() {
        guard isEnabled else { return }
        for item in log.pending { deliver(item.id) }
    }

    func cancel(_ id: String) {
        running[id]?.cancel()
        running[id] = nil
        runIDs[id] = nil
        log.update(id) { if $0.status == .laeuft { $0.status = .abgebrochen } }
        persist()
    }

    func isRunning(_ id: String) -> Bool { running[id] != nil }

    func delete(_ id: String) {
        cancel(id)
        log.remove(id)
        if activeID == id { activeID = nil }
        persist()
    }

    func clearHistory() {
        log.clearFinished()
        if let id = activeID, item(id) == nil { activeID = nil }
        persist()
    }

    func show(_ id: String?) { activeID = id }

    private func run(_ id: String) async {
        guard let current = item(id) else { return }
        do {
            let client = try makeClient()
            _ = try await client.submit(id: id, ziel: current.ziel, text: current.text,
                                        quelle: quelle, zeit: current.zeit)
            guard !Task.isCancelled else { return }
            log.update(id) { $0.angenommen = true }
            persist()
            resetRetry()

            let deadline = Date().addingTimeInterval(maxWait)
            while true {
                let answer = try await client.status(id: id)
                guard !Task.isCancelled else { return }
                if answer.isFinished {
                    log.update(id) { item in
                        item.status = answer.status == "fertig" ? .fertig : .fehler
                        item.ergebnis = answer.text
                        item.vorschlag = answer.vorschlag
                    }
                    persist()
                    return
                }
                if Date() >= deadline { throw TargetError.noResponse }
                // Der Dienst hält die Abfrage selbst offen; antwortet er sofort
                // („laeuft“), nicht im Takt der CPU nachfragen.
                try await Task.sleep(nanoseconds: pollPause)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            let reason = TargetError.from(error)
            log.update(id) { $0.status = .wartet; $0.letzterFehler = reason }
            persist()
            scheduleRetry(after: reason)
        }
    }

    /// Bei Netz- und Dienstproblemen selbst erneut versuchen, mit wachsender
    /// Pause. Bei falschem oder fehlendem Gerätewort bzw. fehlender Adresse
    /// nicht — das ändert sich erst, wenn der Nutzer etwas einträgt (dann
    /// sendet `retryPending` aus den Einstellungen).
    private func scheduleRetry(after reason: TargetError) {
        switch reason {
        case .unreachable, .noResponse, .server: break
        case .unauthorized, .notConfigured, .missingToken: return
        }
        guard retryTask == nil else { return }
        let delay = min(retryMax, retryBase * pow(2, Double(retryAttempt)))
        retryAttempt += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.retryPending()
        }
    }

    /// Erfolg: Die nächste Störung beginnt wieder mit der kurzen Pause.
    private func resetRetry() {
        retryAttempt = 0
    }

    private func persist() {
        if let storeURL { log.save(to: storeURL) }
    }
}

// MARK: - Direkt in die Claude- oder ChatGPT-App

/// Übergibt ein Diktat an die App eines Assistenten — ohne Schlüssel und ohne
/// eigenen Dienst, über das Abo in dieser App. Die Adressen sind die offenen
/// Web-Links mit vorbelegter Frage (`?q=`); ist die App installiert, öffnet
/// iOS sie über den Universal Link. Ob die App die Vorbelegung übernimmt,
/// liegt bei ihr — deshalb liegt der Text zusätzlich in der Zwischenablage.
enum AssistantApp: String, CaseIterable, Sendable {
    case claude
    case chatgpt

    /// Lange Diktate sprengen sonst die Adresse; der volle Text steht in der
    /// Zwischenablage.
    static let maxQueryLength = 4000

    var title: String {
        switch self {
        case .claude: return "Claude-App"
        case .chatgpt: return "ChatGPT-App"
        }
    }

    func url(for text: String) -> URL? {
        var components: URLComponents
        switch self {
        case .claude: components = URLComponents(string: "https://claude.ai/new")!
        case .chatgpt: components = URLComponents(string: "https://chatgpt.com/")!
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return components.url }
        components.queryItems = [URLQueryItem(name: "q", value: String(trimmed.prefix(Self.maxQueryLength)))]
        return components.url
    }
}

// MARK: - Anzeigetexte (iPhone und Mac)

/// Anzeigetexte für Ziele, Zustände und Fehler — an einer Stelle, damit die
/// Startseite, der Verlauf und die Einstellungen dasselbe sagen.
@MainActor
enum TargetText {
    static func label(_ ziel: DictationTarget) -> String {
        switch ziel {
        case .text: return Loc.t("Text")
        case .aktion: return "TT-brAIn"
        case .frage: return Loc.t("Claude fragen")
        }
    }

    static func icon(_ ziel: DictationTarget) -> String {
        switch ziel {
        case .text: return "doc.on.clipboard"
        case .aktion: return "checklist"
        case .frage: return "bubble.left.and.text.bubble.right"
        }
    }

    static func error(_ error: TargetError) -> String {
        switch error {
        case .notConfigured: return Loc.t("Keine Adresse eingetragen (Einstellungen → Ziele).")
        case .missingToken: return Loc.t("Kein Gerätewort eingetragen (Einstellungen → Ziele).")
        case .unauthorized: return Loc.t("Gerätewort falsch.")
        case .unreachable: return Loc.t("iMac nicht erreichbar.")
        case .noResponse: return Loc.t("Dienst antwortet nicht.")
        case .server(let status): return Loc.f("Dienst meldet Fehler %d.", status)
        }
    }

    static func status(_ item: TargetItem) -> String {
        switch item.status {
        case .wartet: return Loc.t("wartet")
        case .laeuft: return Loc.t("wird bearbeitet …")
        case .fertig: return Loc.t("fertig")
        case .fehler: return Loc.t("Fehler beim Dienst")
        case .abgebrochen: return Loc.t("abgebrochen")
        }
    }

    /// Was als Ergebnis angezeigt (und kopiert) wird.
    static func result(_ item: TargetItem) -> String? {
        if item.ziel == .aktion, let line = TargetSummary.line(for: item.vorschlag) {
            return Loc.f("%@ – liegt auf TT-brAIn zur Bestätigung", line)
        }
        let text = item.ergebnis?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}
