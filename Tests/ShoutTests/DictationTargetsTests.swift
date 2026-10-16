import XCTest

/// Ziele nach der Aufnahme: Senden, Abfragen, Warteschlange, Verlauf.
/// Alles läuft gegen `StubURLProtocol` — mit erfundenen Texten, erfundener
/// Adresse und erfundenem Gerätewort.
@MainActor
final class DictationTargetsTests: XCTestCase {

    private let base = URL(string: "http://dienst.test:9999")!
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        StubURLProtocol.reset()
        suite = "shout.tests.ziele.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.set(true, forKey: TargetSettings.enabledKey)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        StubURLProtocol.reset()
    }

    private func client() -> TargetClient {
        TargetClient(base: base, token: "test-wort", session: StubURLProtocol.session())
    }

    private func dispatcher(store: URL? = nil) -> TargetDispatcher {
        let d = TargetDispatcher(storeURL: store, quelle: "shout-test", defaults: defaults) { [base] in
            TargetClient(base: base, token: "test-wort", session: StubURLProtocol.session())
        }
        d.pollPause = 10_000_000
        return d
    }

    private func json(_ object: [String: Any], status: Int = 200) -> StubURLProtocol.Antwort {
        StubURLProtocol.Antwort(status: status, body: try! JSONSerialization.data(withJSONObject: object))
    }

    private func angenommen(_ id: String, doppelt: Bool = false) -> StubURLProtocol.Antwort {
        var o: [String: Any] = ["id": id, "status": "angenommen"]
        if doppelt { o["doppelt"] = true }
        return json(o)
    }

    private func waitUntilIdle(_ d: TargetDispatcher, _ id: String,
                               file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 {
            if !d.isRunning(id) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Vorgang wurde nicht fertig", file: file, line: line)
    }

    private func posts() -> [[String: Any]] {
        StubURLProtocol.anfragen
            .filter { $0.request.httpMethod == "POST" }
            .compactMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
    }

    // MARK: - Netz

    func testPostSchicktFelderUndGeraetewort() async throws {
        StubURLProtocol.antworten = [angenommen("abc")]
        let zeit = Date(timeIntervalSince1970: 1_800_000_000)
        let antwort = try await client().submit(id: "abc", ziel: .aktion, text: "Montag Werkstatt",
                                                quelle: "shout-ios", zeit: zeit)
        XCTAssertEqual(antwort.status, "angenommen")

        let anfrage = try XCTUnwrap(StubURLProtocol.anfragen.first)
        XCTAssertEqual(anfrage.request.url?.absoluteString, "http://dienst.test:9999/sprache")
        XCTAssertEqual(anfrage.request.value(forHTTPHeaderField: "X-TTBrain-Token"), "test-wort")
        let body = try XCTUnwrap(posts().first)
        XCTAssertEqual(body["ziel"] as? String, "aktion")
        XCTAssertEqual(body["text"] as? String, "Montag Werkstatt")
        XCTAssertEqual(body["quelle"] as? String, "shout-ios")
        XCTAssertEqual(body["id"] as? String, "abc")
        XCTAssertEqual(body["zeit"] as? String, "2027-01-15T08:00:00Z")
    }

    func testAbfrageLangesZeitlimit() async throws {
        StubURLProtocol.antworten = [json(["id": "abc", "status": "fertig", "ziel": "frage", "text": "42"])]
        let antwort = try await client().status(id: "abc")
        XCTAssertEqual(antwort.text, "42")
        let anfrage = try XCTUnwrap(StubURLProtocol.anfragen.first)
        XCTAssertEqual(anfrage.request.url?.path, "/sprache/abc")
        XCTAssertGreaterThanOrEqual(anfrage.request.timeoutInterval, 60)
    }

    func test401WirdGeraetewortFalsch() async {
        StubURLProtocol.antworten = [StubURLProtocol.Antwort(status: 401)]
        do {
            _ = try await client().status(id: "x")
            XCTFail("hätte werfen müssen")
        } catch {
            XCTAssertEqual(error as? TargetError, .unauthorized)
        }
    }

    func testVerbindungsfehlerUndZeitueberschreitungWerdenUnterschieden() {
        XCTAssertEqual(TargetError.from(URLError(.notConnectedToInternet)), .unreachable)
        XCTAssertEqual(TargetError.from(URLError(.cannotConnectToHost)), .unreachable)
        XCTAssertEqual(TargetError.from(URLError(.timedOut)), .noResponse)
    }

    // MARK: - Ablauf

    func testFrageKommtMitAntwortZurueck() async {
        let d = dispatcher()
        let id = "frage-1"
        StubURLProtocol.antworten = [
            angenommen(id),
            json(["id": id, "status": "laeuft", "ziel": "frage"]),
            json(["id": id, "status": "fertig", "ziel": "frage", "text": "Die Preisliste kommt Freitag."]),
        ]
        d.submit("Wann kommt die Preisliste?", to: .frage, id: id)
        await waitUntilIdle(d, id)
        XCTAssertEqual(d.item(id)?.status, .fertig)
        XCTAssertEqual(d.item(id)?.ergebnis, "Die Preisliste kommt Freitag.")
    }

    func testAktionLiefertVorschlagszeile() async {
        let d = dispatcher()
        let id = "aktion-1"
        StubURLProtocol.antworten = [
            angenommen(id),
            json(["id": id, "status": "fertig", "ziel": "aktion", "bestaetigt": "offen",
                  "vorschlag": ["art": "termin", "titel": "Werkstatt", "datum": "2026-10-20", "uhrzeit": "14:00"]]),
        ]
        d.submit("Montag 14 Uhr Werkstatt", to: .aktion, id: id)
        await waitUntilIdle(d, id)
        XCTAssertEqual(d.item(id)?.status, .fertig)
        XCTAssertEqual(TargetSummary.line(for: d.item(id)?.vorschlag), "Termin 20.10. 14:00 Werkstatt")
    }

    func testFalschesGeraetewortBleibtInWarteschlange() async {
        let d = dispatcher()
        StubURLProtocol.antworten = [StubURLProtocol.Antwort(status: 401)]
        let id = d.submit("Notiz Test", to: .aktion)
        await waitUntilIdle(d, id)
        XCTAssertEqual(d.item(id)?.status, .wartet)
        XCTAssertEqual(d.item(id)?.letzterFehler, .unauthorized)
        XCTAssertEqual(d.log.pending.count, 1)
    }

    /// Flugmodus: Diktat wartet, danach geht es mit DERSELBEN id raus.
    func testOhneNetzWartenDannMitGleicherIdSenden() async {
        let d = dispatcher()
        StubURLProtocol.antworten = [StubURLProtocol.Antwort(error: URLError(.notConnectedToInternet))]
        let id = d.submit("Erinnerung Test", to: .aktion)
        await waitUntilIdle(d, id)
        XCTAssertEqual(d.item(id)?.status, .wartet)
        XCTAssertEqual(d.item(id)?.letzterFehler, .unreachable)

        StubURLProtocol.antworten = [
            angenommen(id),
            json(["id": id, "status": "fertig", "ziel": "aktion", "text": "ok"]),
        ]
        d.retryPending()
        await waitUntilIdle(d, id)
        XCTAssertEqual(d.item(id)?.status, .fertig)
        XCTAssertEqual(posts().compactMap { $0["id"] as? String }, [id, id])
    }

    /// Zweimal „Senden“ hintereinander → ein Vorgang.
    func testDoppeltesSendenErgibtEinenVorgang() async {
        let d = dispatcher()
        let id = "doppelt-1"
        StubURLProtocol.antworten = [
            angenommen(id),
            json(["id": id, "status": "fertig", "ziel": "frage", "text": "ok"]),
        ]
        d.submit("Test", to: .frage, id: id)
        d.deliver(id)
        d.retryPending()
        await waitUntilIdle(d, id)
        XCTAssertEqual(posts().count, 1)
        // Nach dem Ergebnis sendet auch ein weiterer Versuch nichts mehr.
        d.deliver(id)
        XCTAssertFalse(d.isRunning(id))
        XCTAssertEqual(posts().count, 1)
    }

    func testLetztesZielWirdVorgeschlagen() {
        let d = dispatcher()
        XCTAssertEqual(d.lastTarget, .text)
        d.offer("Erstes Diktat")
        StubURLProtocol.antworten = [StubURLProtocol.Antwort(error: URLError(.notConnectedToInternet))]
        d.choose(.frage)
        XCTAssertNil(d.offeredText)
        XCTAssertEqual(dispatcher().lastTarget, .frage)

        d.offer("Zweites Diktat")
        d.choose(.text)
        XCTAssertEqual(d.lastTarget, .text)
    }

    func testAusgeschaltetBietetNichtsAn() {
        defaults.set(false, forKey: TargetSettings.enabledKey)
        let d = dispatcher()
        d.offer("Text")
        XCTAssertNil(d.offeredText)
    }

    func testAbbrechenBleibtImVerlauf() async {
        let d = dispatcher()
        // Abfrage hängt: der Stub antwortet „laeuft“ immer wieder.
        StubURLProtocol.antworten = [angenommen("abbr")] +
            Array(repeating: json(["id": "abbr", "status": "laeuft"]), count: 200)
        d.submit("Lange Frage", to: .frage, id: "abbr")
        try? await Task.sleep(nanoseconds: 50_000_000)
        d.cancel("abbr")
        XCTAssertFalse(d.isRunning("abbr"))
        XCTAssertEqual(d.item("abbr")?.status, .abgebrochen)
        XCTAssertTrue(d.log.pending.isEmpty)
    }

    // MARK: - Ablage

    func testVerlaufKuerztNurErledigtes() {
        var log = TargetLog()
        log.insert(TargetItem(id: "wartet", ziel: .frage, text: "w", zeit: Date(), status: .wartet))
        for n in 0..<30 {
            log.insert(TargetItem(id: "f\(n)", ziel: .frage, text: "f", zeit: Date(), status: .fertig))
        }
        XCTAssertEqual(log.items.filter { $0.status == .fertig }.count, TargetLog.historyLimit)
        XCTAssertNotNil(log.items.first { $0.id == "wartet" })
        XCTAssertEqual(log.items.first?.id, "f29")

        log.clearFinished()
        XCTAssertEqual(log.items.map(\.id), ["wartet"])
    }

    func testAblageUeberstehtNeustartUndLaufendesWirdWartend() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ziele-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var log = TargetLog()
        log.insert(TargetItem(id: "a", ziel: .aktion, text: "t", zeit: Date(), status: .laeuft,
                              letzterFehler: .server(502)))
        log.save(to: url)

        let geladen = TargetLog.load(from: url)
        XCTAssertEqual(geladen.items.first?.status, .wartet)
        XCTAssertEqual(geladen.items.first?.letzterFehler, .server(502))
    }

    // MARK: - Anzeige und Adresse

    func testVorschlagszeileMitOrtUndOhneFelder() {
        XCTAssertEqual(TargetSummary.line(for: TargetProposal(art: "termin", titel: "Werkstatt",
                                                              datum: "2026-10-20", uhrzeit: "14:00", ort: "Trier")),
                       "Termin 20.10. 14:00 Werkstatt Trier")
        XCTAssertNil(TargetSummary.line(for: TargetProposal()))
        XCTAssertEqual(TargetSummary.shortDate("morgen"), "morgen")
    }

    func testAdresseWirdNormalisiert() {
        XCTAssertEqual(TargetSettings.normalizedBase("dienst.test:8765/")?.absoluteString,
                       "http://dienst.test:8765")
        XCTAssertEqual(TargetSettings.normalizedBase(" https://dienst.test ")?.absoluteString,
                       "https://dienst.test")
        XCTAssertNil(TargetSettings.normalizedBase(""))
        XCTAssertNil(TargetSettings.normalizedBase("ftp://dienst.test"))
    }
}
