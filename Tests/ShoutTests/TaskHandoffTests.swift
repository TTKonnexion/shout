import XCTest

/// Auftrag Nr. 268: Termin aus gesprochenem Text, Adressen für Mail und WhatsApp.
/// Nur erfundene Beispieltexte.
final class TaskHandoffTests: XCTestCase {
    /// Donnerstag, 05.11.2026, 10:00 Uhr (feste Zeitzone, damit die Tests überall gleich laufen).
    private var kal: Calendar {
        var c = Calendar.deutsch
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }
    private var jetzt: Date { kal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 10))! }

    private func tag(_ d: Date) -> String {
        let c = kal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }
    private func e(_ s: String) -> TerminEntwurf? { TerminErkennung.erkenne(s, jetzt: jetzt, kalender: kal) }

    func testWochentagUndUhrzeit() throws {
        let t = try XCTUnwrap(e("Termin Montag 14 Uhr, Besprechung mit Herrn Beispiel"))
        XCTAssertEqual(tag(t.start), "2026-11-09 14:00")
        XCTAssertFalse(t.ganztaegig)
        XCTAssertEqual(t.titel, "Besprechung mit Herrn Beispiel")
    }

    func testMorgenMitMinuten() throws {
        let t = try XCTUnwrap(e("Morgen um 9:30 Uhr Zahnarzt"))
        XCTAssertEqual(tag(t.start), "2026-11-06 09:30")
        XCTAssertEqual(t.titel, "Zahnarzt")
    }

    func testHeuteUndUebermorgen() throws {
        XCTAssertEqual(tag(try XCTUnwrap(e("heute um 16 Uhr Anruf")).start), "2026-11-05 16:00")
        XCTAssertEqual(tag(try XCTUnwrap(e("übermorgen 8 Uhr Abholung")).start), "2026-11-07 08:00")
    }

    func testGleicherWochentagMeintNaechsteWoche() throws {
        XCTAssertEqual(tag(try XCTUnwrap(e("am Donnerstag um 11 Uhr Lieferung")).start), "2026-11-12 11:00")
    }

    func testDatumMitPunktenUndMonatsname() throws {
        XCTAssertEqual(tag(try XCTUnwrap(e("am 12.11. um 15 Uhr Rückruf")).start), "2026-11-12 15:00")
        XCTAssertEqual(tag(try XCTUnwrap(e("am 3.12.2026 um 10:15 Uhr Messe")).start), "2026-12-03 10:15")
        XCTAssertEqual(tag(try XCTUnwrap(e("am 20. Dezember um 18 Uhr Feier")).start), "2026-12-20 18:00")
    }

    func testDatumOhneJahrDasSchonVorbeiIstGehtInsNaechsteJahr() throws {
        XCTAssertEqual(tag(try XCTUnwrap(e("am 2.11. um 9 Uhr Jahrestag")).start), "2027-11-02 09:00")
    }

    func testOhneUhrzeitIstGanztaegig() throws {
        let t = try XCTUnwrap(e("Freitag Angebot abgeben"))
        XCTAssertTrue(t.ganztaegig)
        XCTAssertEqual(tag(t.start), "2026-11-06 00:00".replacingOccurrences(of: "11-06", with: "11-06"))
        XCTAssertEqual(t.titel, "Angebot abgeben")
    }

    func testKeinTagKeinTermin() {
        XCTAssertNil(e("Ich muss noch Milch kaufen"))
        XCTAssertNil(e("um 14 Uhr"))   // Uhrzeit allein reicht nicht, der Nutzer wählt den Tag
    }

    func testUngueltigesDatumWirdNichtGeraten() {
        XCTAssertNil(e("am 31.02. Besprechung"))
        XCTAssertNil(e("am 40.13. Besprechung"))
    }

    func testLeererTitelBekommtStandard() throws {
        XCTAssertEqual(try XCTUnwrap(e("Montag um 14 Uhr")).titel, "Termin")
    }

    func testLinksKodierenSonderzeichen() throws {
        let w = try XCTUnwrap(AufgabenLinks.whatsApp(text: "Müller & Söhne: 3+4=7\nBis 14 Uhr"))
        XCTAssertEqual(w.absoluteString, "https://wa.me/?text=M%C3%BCller%20%26%20S%C3%B6hne%3A%203%2B4%3D7%0ABis%2014%20Uhr")
        let m = try XCTUnwrap(AufgabenLinks.mailEntwurf(text: "Hallo & danke", betreff: "Test 1"))
        XCTAssertEqual(m.absoluteString, "mailto:?subject=Test%201&body=Hallo%20%26%20danke")
        XCTAssertEqual(AufgabenLinks.mailEntwurf(text: "x")?.absoluteString, "mailto:?body=x")
    }

    func testVorgabeVorDemText() {
        XCTAssertEqual(AufgabenLinks.mitVorgabe("Trage das ein:", text: "Montag 14 Uhr"), "Trage das ein:\n\nMontag 14 Uhr")
        XCTAssertEqual(AufgabenLinks.mitVorgabe("  ", text: "Montag"), "Montag")
    }
}
