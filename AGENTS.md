# Hinweise für Codex – Projekt shout

## Arbeitsteilung Chat ↔ Code (Wunsch Thomas, 12.10.2026)

- **Programmierung nur im Code-Werkzeug** (Codex bzw. Claude Code im Terminal): Code, Tests, Hintergrunddienste, Build, feste Regeln.
- **Ideen, Verschönerungen, neue Wünsche und Konzepte zuerst im Chat** (Claude Cowork oder ChatGPT) mit Thomas besprechen.
  Das Ergebnis liegt als Auftrag `cowork/auftrag-an-code-<n>.md` im Projekt. Umgesetzt wird, was dort steht oder was Thomas
  direkt beauftragt. Eigene Ideen am Ende als Vorschlag nennen, nicht ungefragt bauen.
- **Texte, die Cowork verwendet** (z. B. Anweisungen geplanter Aufgaben in `cowork/*.txt`): Änderungen in die Datei schreiben (alte Fassung vorher als `alt-…` sichern). **Die geplanten Aufgaben lesen diese Dateien bei jedem Start direkt vom iMac – jede gespeicherte Änderung gilt ab dem nächsten Lauf.** Deshalb nur vollständige, geprüfte Fassungen speichern (erst als .tmp schreiben, dann umbenennen) und Thomas die geänderten Stellen nennen.
- Alles, was sich fest programmieren lässt, gehört in den Code – nicht in Chat-Anweisungen.
- Sprache Deutsch. Am Ende jeder Arbeit: kurze Zusammenfassung für Thomas, einfach erklärt – was gemacht wurde, was er tun muss, was offen ist.

## Vor jeder neuen Aufgabe: Gab es das schon? (Wunsch Thomas, 12.10.2026)

- Zuerst `~/Developer/AUFTRAGSBUCH.md` lesen und im Projekt nach Ähnlichem suchen: `cowork/auftrag-*.md`, `AUFTRAG-*.md`, `OFFEN.md`,
  `git log --oneline | grep -i <Stichwort>`. Gibt es Ähnliches, Thomas das kurz nennen (wann, Stand) und fragen, ob darauf aufgebaut wird.
- Neue Aufträge im Auftragsbuch eintragen; nach Fertigstellung dort den Status auf `erledigt (<Datum>)` setzen.

## Ziele nach der Aufnahme (Auftrag Nr. 1, 16.10.2026)

- iOS: Nach dem Diktat „Text“ / „TT-brAIn“ / „Claude fragen“ (Einstellungen → Ziele). Kern in
  `Sources/FlowLokal/DictationTargets.swift`, Oberfläche in `Sources/ShoutMobile/MobileTargetsView.swift`.
- Gegenstück ist der Mail-Dienst (`mail-dienst`, Nr. 53): `POST /sprache`, `GET /sprache/<id>`, Kopf `X-TTBrain-Token`.
- Eine `id` je Diktat, bei Wiederholungen dieselbe. Nichts verwerfen: wartende Einträge nie kürzen.
- Keine Adresse, kein Gerätewort, nichts aus `cowork/` in Code, Tests oder Commits (öffentlicher Fork).
- Dieser iMac ist ein Intel-Rechner: Tests laufen nur mit vorübergehend `ARCHS: x86_64` (xcodegen mit einer
  Kopie der project.yml, die danach gelöscht wird); iOS-Build mit `-skipPackagePluginValidation -skipMacroValidation`.
- Adresse in der App immer als Tailnet-Rechnername ohne Punkte (`http://thomass-imac-2:8765`), nicht als 100.x-IP:
  iOS sperrt http an IP-Adressen (ATS), `NSAllowsLocalNetworking` gilt nur für Namen ohne Punkte (geprüft 16.10.2026).
- Mac (Auftrag Nr. 3): Zieltaste in `TargetsMac.swift` (feste Auswahl ⌃⌥ Leertaste/⌃⌥T/F6/F7), Auswahlfenster als
  nicht aktivierendes Panel, damit „Text“ in die vorherige App einfügt. Mac-Build auf dem Intel-iMac nur mit
  `-scheme FlowLokal -destination 'generic/platform=macOS'` (nicht `-arch arm64`: Makro-Werkzeug fehlt dann).

- Aufträge und Status: `~/Developer/tt-workspace/auftraege/` (erzeugtes Buch: `~/Developer/AUFTRAGSBUCH.md`)
