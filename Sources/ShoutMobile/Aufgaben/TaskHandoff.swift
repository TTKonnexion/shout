import Foundation

/// Aufgaben nach dem Diktat (Auftrag Nr. 268): Termin, E-Mail, WhatsApp.
///
/// Nur reine Logik, ohne Oberfläche und ohne Netz. Alles bleibt auf dem Gerät;
/// gesendet wird nichts — die Apps öffnen sich nur mit vorbereitetem Text und
/// der Nutzer bestätigt selbst.

// MARK: - Termin aus gesprochenem Text

struct TerminEntwurf: Equatable {
    var titel: String
    /// Beginn. Ohne erkannte Uhrzeit steht hier der Tag um 00:00 und `ganztaegig` ist wahr.
    var start: Date
    var ganztaegig: Bool
}

enum TerminErkennung {
    private static let wochentage: [(String, Int)] = [
        ("sonntag", 1), ("montag", 2), ("dienstag", 3), ("mittwoch", 4),
        ("donnerstag", 5), ("freitag", 6), ("samstag", 7), ("sonnabend", 7),
    ]
    private static let monate: [(String, Int)] = [
        ("januar", 1), ("februar", 2), ("märz", 3), ("maerz", 3), ("april", 4), ("mai", 5), ("juni", 6),
        ("juli", 7), ("august", 8), ("september", 9), ("oktober", 10), ("november", 11), ("dezember", 12),
    ]

    /// Erkennt Datum und Uhrzeit in deutschem Text. `nil`, wenn kein Tag erkennbar ist
    /// (dann soll die Oberfläche den Nutzer wählen lassen, statt zu raten).
    static func erkenne(_ text: String, jetzt: Date, kalender: Calendar = .deutsch) -> TerminEntwurf? {
        var rest = text
        var tag: Date?
        let heute = kalender.startOfDay(for: jetzt)

        // 1. Ausdrücke mit Datum: 12.11., 12.11.2026, 12. November (2026)
        if let m = treffer(#"(?i)\b(?:am\s+|den\s+)?(\d{1,2})\.\s?(\d{1,2})\.(?:\s?(\d{4}|\d{2}))?"#, in: rest) {
            let t = Int(m.gruppen[0])!, mo = Int(m.gruppen[1])!
            var j = m.gruppen.count > 2 ? Int(m.gruppen[2]) : nil
            if let jj = j, jj < 100 { j = 2000 + jj }
            tag = datum(tag: t, monat: mo, jahr: j, heute: heute, kalender: kalender)
            if tag != nil { rest = m.entferne(aus: rest) }
        }
        if tag == nil, let m = treffer(#"(?i)\b(?:am\s+|den\s+)?(\d{1,2})\.\s?(januar|februar|märz|maerz|april|mai|juni|juli|august|september|oktober|november|dezember)(?:\s+(\d{4}))?"#, in: rest) {
            let t = Int(m.gruppen[0])!
            let mo = monate.first { $0.0 == m.gruppen[1].lowercased() }!.1
            let j = m.gruppen.count > 2 ? Int(m.gruppen[2]) : nil
            tag = datum(tag: t, monat: mo, jahr: j, heute: heute, kalender: kalender)
            if tag != nil { rest = m.entferne(aus: rest) }
        }
        // 2. Relative Tage
        if tag == nil, let m = treffer(#"(?i)\b(übermorgen|uebermorgen|morgen|heute)\b"#, in: rest) {
            let w = m.gruppen[0].lowercased()
            let plus = w == "heute" ? 0 : (w == "morgen" ? 1 : 2)
            tag = kalender.date(byAdding: .day, value: plus, to: heute)
            rest = m.entferne(aus: rest)
        }
        // 3. Wochentag (nächster, der noch kommt; „heute“ muss man sagen)
        if tag == nil, let m = treffer(#"(?i)\b(?:am\s+|nächsten\s+|naechsten\s+|kommenden\s+)*(montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonnabend|sonntag)\b"#, in: rest) {
            let ziel = wochentage.first { $0.0 == m.gruppen[0].lowercased() }!.1
            let heutiger = kalender.component(.weekday, from: heute)
            var diff = (ziel - heutiger + 7) % 7
            if diff == 0 { diff = 7 }
            tag = kalender.date(byAdding: .day, value: diff, to: heute)
            rest = m.entferne(aus: rest)
        }
        guard let tagStart = tag else { return nil }

        // 4. Uhrzeit: „14 Uhr“, „14:30 Uhr“, „um 9“, „um 9.30“, „halb drei“ wird bewusst nicht geraten
        var stunde: Int?, minute = 0
        if let m = treffer(#"(?i)\b(?:um\s+|gegen\s+|ab\s+)?(\d{1,2})(?:[:.](\d{2}))?\s*uhr\b"#, in: rest)
            ?? treffer(#"(?i)\b(?:um|gegen)\s+(\d{1,2})(?:[:.](\d{2}))?\b"#, in: rest) {
            let h = Int(m.gruppen[0])!
            let mi = m.gruppen.count > 1 ? (Int(m.gruppen[1]) ?? 0) : 0
            if (0...23).contains(h), (0...59).contains(mi) {
                stunde = h; minute = mi
                rest = m.entferne(aus: rest)
            }
        }

        let titel = bereinigt(rest)
        if let h = stunde, let start = kalender.date(bySettingHour: h, minute: minute, second: 0, of: tagStart) {
            return TerminEntwurf(titel: titel, start: start, ganztaegig: false)
        }
        return TerminEntwurf(titel: titel, start: tagStart, ganztaegig: true)
    }

    private static func datum(tag: Int, monat: Int, jahr: Int?, heute: Date, kalender: Calendar) -> Date? {
        var c = DateComponents(); c.day = tag; c.month = monat
        if let j = jahr { c.year = j } else { c.year = kalender.component(.year, from: heute) }
        guard var d = kalender.date(from: c),
              kalender.component(.day, from: d) == tag, kalender.component(.month, from: d) == monat else { return nil }
        // Ohne Jahr und schon vorbei: nächstes Jahr
        if jahr == nil, d < heute, let n = kalender.date(byAdding: .year, value: 1, to: d) { d = n }
        return d
    }

    private static func bereinigt(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"(?i)^\s*(?:ein\s+|einen\s+|eine\s+)?(?:neuer\s+|neuen\s+)?termin\b[\s,:;–-]*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)\b(?:am|um|den|gegen|ab)\b(?=\s*[,.;]|\s*$)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:–-\n\t"))
        t = t.replacingOccurrences(of: #"(?i)^(?:am|um|den|gegen|ab)\s+"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:–-\n\t"))
        guard let ersteBuchstabe = t.first else { return "Termin" }
        return String(ersteBuchstabe).uppercased() + t.dropFirst()
    }

    private struct Treffer {
        var bereich: Range<String.Index>
        var gruppen: [String]
        func entferne(aus text: String) -> String {
            var t = text; t.replaceSubrange(bereich, with: " "); return t
        }
    }

    private static func treffer(_ muster: String, in text: String) -> Treffer? {
        guard let re = try? NSRegularExpression(pattern: muster),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let ganz = Range(m.range, in: text) else { return nil }
        var g: [String] = []
        for i in 1..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: text) { g.append(String(text[r])) } else { g.append("") }
        }
        // Leere (nicht getroffene) Gruppen am Ende weglassen, damit `Int(...)` sicher bleibt
        while g.last == "" { g.removeLast() }
        return Treffer(bereich: ganz, gruppen: g)
    }
}

extension Calendar {
    /// Deutscher Kalender, Woche beginnt am Montag; feste Zeitzone nur bei Bedarf der Aufrufer.
    static var deutsch: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "de_DE")
        c.firstWeekday = 2
        return c
    }
}

// MARK: - E-Mail und WhatsApp: nur Adressen bauen

enum AufgabenLinks {
    /// Streng kodiert: Auch &, +, = und Zeilenumbrüche im Diktat bleiben Teil des Textes
    /// (URLComponents lässt sie in Parametern unkodiert stehen).
    static func kodiert(_ s: String) -> String {
        let erlaubt = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: erlaubt) ?? ""
    }

    /// Entwurf in der Mail-App des Geräts. Empfänger und Betreff trägt der Nutzer selbst ein.
    static func mailEntwurf(text: String, betreff: String = "") -> URL? {
        var teile: [String] = []
        if !betreff.isEmpty { teile.append("subject=" + kodiert(betreff)) }
        teile.append("body=" + kodiert(text))
        return URL(string: "mailto:?" + teile.joined(separator: "&"))
    }

    /// WhatsApp mit vorbereitetem Text. Ohne Empfänger: Der Nutzer wählt in WhatsApp selbst.
    static func whatsApp(text: String) -> URL? {
        URL(string: "https://wa.me/?text=" + kodiert(text))
    }

    /// Vorspannzeile für die Claude-/ChatGPT-App (Variante A): Der Kunde sendet selbst ab.
    static func mitVorgabe(_ vorgabe: String, text: String) -> String {
        let v = vorgabe.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? text : v + "\n\n" + text
    }
}
