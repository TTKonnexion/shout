import SwiftUI
import EventKit

/// Aufgaben nach dem Diktat (Auftrag Nr. 268): Termin, E-Mail, WhatsApp.
/// Alles auf dem Gerät. Gesendet wird nichts: Mail und WhatsApp öffnen sich nur mit
/// vorbereitetem Text, der Termin wird erst nach „Eintragen“ gespeichert.
struct AufgabenChooser: View {
    let text: String
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var terminEntwurf: TerminEntwurf?
    @State private var hinweis: String?

    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Loc.t("Daraus machen"))
                .font(.caption).foregroundStyle(.secondary)
            layout {
                knopf(Loc.t("Termin"), "calendar.badge.plus") { terminOeffnen() }
                knopf(Loc.t("E-Mail"), "envelope") { mailOeffnen() }
                knopf("WhatsApp", "message") { whatsAppOeffnen() }
            }
            #if SHOUTME
            // Die Assistenten-Apps des Nutzers (über dessen eigenes Konto). Nichts wird
            // abgeschickt, der Text steht nur vorbereitet in der App.
            layout {
                ForEach(AssistantApp.allCases, id: \.self) { app in
                    knopf(app.title, "arrow.up.forward.app") { assistentOeffnen(app) }
                }
            }
            #endif
            if let hinweis {
                Text(hinweis).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .sheet(item: $terminEntwurf) { _ in
            TerminSheet(entwurf: $terminEntwurf)
        }
    }

    private func knopf(_ titel: String, _ symbol: String, _ aktion: @escaping () -> Void) -> some View {
        Button(action: aktion) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                Text(titel).font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.bordered)
    }

    private func terminOeffnen() {
        hinweis = nil
        // Kein Tag erkannt: Entwurf mit heutigem Tag, der Nutzer wählt selbst (nichts wird geraten).
        terminEntwurf = TerminErkennung.erkenne(text, jetzt: Date())
            ?? TerminEntwurf(titel: String(text.prefix(80)), start: Date(), ganztaegig: false)
    }

    private func mailOeffnen() {
        guard let url = AufgabenLinks.mailEntwurf(text: text) else { return }
        UIPasteboard.general.string = text
        hinweis = Loc.t("Entwurf geöffnet. Empfänger trägst du selbst ein; gesendet wird erst in der Mail-App.")
        openURL(url) { angenommen in
            if !angenommen { hinweis = Loc.t("Keine Mail-App eingerichtet. Der Text liegt in der Zwischenablage.") }
        }
    }

    private func whatsAppOeffnen() {
        guard let url = AufgabenLinks.whatsApp(text: text) else { return }
        UIPasteboard.general.string = text
        hinweis = Loc.t("WhatsApp geöffnet. Empfänger wählst du selbst; gesendet wird erst dort.")
        openURL(url) { angenommen in
            if !angenommen { hinweis = Loc.t("WhatsApp nicht gefunden. Der Text liegt in der Zwischenablage.") }
        }
    }

    #if SHOUTME
    private func assistentOeffnen(_ app: AssistantApp) {
        guard let url = app.url(for: text) else { return }
        UIPasteboard.general.string = text
        hinweis = Loc.t("Die App ist geöffnet. Abgeschickt wird erst, wenn du es dort tust.")
        openURL(url)
    }
    #endif
}

extension TerminEntwurf: Identifiable {
    var id: Date { start }
}

/// Bestätigungsfenster: Titel und Zeit prüfen oder ändern, erst „Eintragen“ speichert.
struct TerminSheet: View {
    @Binding var entwurf: TerminEntwurf?
    @Environment(\.dismiss) private var dismiss
    @State private var titel = ""
    @State private var start = Date()
    @State private var ganztaegig = false
    @State private var meldung: String?
    @State private var fertig = false
    @State private var laeuft = false

    var body: some View {
        NavigationStack {
            Form {
                Section(Loc.t("Termin")) {
                    TextField(Loc.t("Titel"), text: $titel)
                    Toggle(Loc.t("Ganztägig"), isOn: $ganztaegig)
                    DatePicker(Loc.t("Beginn"), selection: $start,
                               displayedComponents: ganztaegig ? [.date] : [.date, .hourAndMinute])
                }
                if let meldung {
                    Section { Text(meldung).font(.footnote) }
                }
            }
            .navigationTitle(Loc.t("Termin eintragen"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(fertig ? Loc.t("Schließen") : Loc.t("Abbrechen")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Loc.t("Eintragen")) { eintragen() }
                        .disabled(laeuft || fertig || titel.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let e = entwurf { titel = e.titel; start = e.start; ganztaegig = e.ganztaegig }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func eintragen() {
        laeuft = true
        let t = titel.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await TerminKalender.eintragen(titel: t, start: start, ganztaegig: ganztaegig)
                meldung = Loc.t("Eingetragen in deinen Kalender.")
                fertig = true
            } catch TerminKalender.Fehler.keinZugriff {
                meldung = Loc.t("Kein Zugriff auf den Kalender. Du kannst ihn in den Einstellungen des Telefons erlauben.")
            } catch {
                meldung = Loc.t("Der Termin konnte nicht gespeichert werden.")
            }
            laeuft = false
        }
    }
}

/// Schreibt einen Termin in den Standardkalender des Telefons. Nur Schreibrecht
/// (kein Lesen fremder Termine), erst auf die Bestätigung des Nutzers.
enum TerminKalender {
    enum Fehler: Error { case keinZugriff }

    static func eintragen(titel: String, start: Date, ganztaegig: Bool) async throws {
        let store = EKEventStore()
        let erlaubt = try await store.requestWriteOnlyAccessToEvents()
        guard erlaubt, let kalender = store.defaultCalendarForNewEvents else { throw Fehler.keinZugriff }
        let ereignis = EKEvent(eventStore: store)
        ereignis.calendar = kalender
        ereignis.title = titel
        ereignis.isAllDay = ganztaegig
        ereignis.startDate = start
        ereignis.endDate = ganztaegig ? start : start.addingTimeInterval(3600)
        if !ganztaegig { ereignis.addAlarm(EKAlarm(relativeOffset: -1800)) }
        try store.save(ereignis, span: .thisEvent)
    }
}
