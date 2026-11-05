import SwiftUI
import UIKit

// MARK: - Auswahl nach der Aufnahme

/// Drei Knöpfe unter dem frischen Diktat. Das zuletzt gewählte Ziel ist
/// hervorgehoben, damit der häufige Fall ein Tipp bleibt.
struct TargetChooser: View {
    @ObservedObject var targets: TargetDispatcher
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var targetLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Loc.t("Wohin damit?"))
                .font(.caption).foregroundStyle(.secondary)
            targetLayout {
                ForEach(DictationTarget.primary, id: \.self) { ziel in
                    choiceButton(ziel)
                }
            }
            // Einfall von unterwegs: wird als Auftrag festgehalten, nichts weiter.
            targetLayout {
                ForEach(DictationTarget.auftragReihe, id: \.self) { ziel in
                    choiceButton(ziel)
                }
            }
            // Direkt in die App des Assistenten — über das dortige Abo,
            // ohne Dienst auf dem iMac.
            targetLayout {
                ForEach(AssistantApp.allCases, id: \.self) { app in
                    Button { open(app) } label: {
                        Label(app.title, systemImage: "arrow.up.forward.app")
                            .font(.footnote.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
            }
            // Am iMac öffnen: Der Dienst dort startet Claude bzw. ChatGPT mit
            // dem Diktat — praktisch, wenn man gleich am Schreibtisch weitermacht.
            targetLayout {
                ForEach(DictationTarget.imac, id: \.self) { ziel in
                    choiceButton(ziel)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    /// Text liegt schon in der Zwischenablage; zur Sicherheit noch einmal,
    /// falls die App die Vorbelegung nicht übernimmt — dann einfach einsetzen.
    private func open(_ app: AssistantApp) {
        guard let text = targets.offeredText, let url = app.url(for: text) else { return }
        UIPasteboard.general.string = text
        targets.dismissOffer()
        openURL(url)
    }

    @ViewBuilder
    private func choiceButton(_ ziel: DictationTarget) -> some View {
        let button = Button { targets.choose(ziel) } label: {
            VStack(spacing: 4) {
                Image(systemName: TargetText.icon(ziel))
                Text(TargetText.label(ziel))
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        if ziel == targets.lastTarget {
            button.buttonStyle(.borderedProminent)
                .accessibilityHint(Loc.t("Zuletzt gewählt"))
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

// MARK: - Ergebnis eines Ziels

/// Ein Eintrag auf der Startseite oder im Verlauf: Zustand, Ergebnis,
/// Kopieren/Teilen, bei Problemen „Erneut senden“.
struct TargetItemCard: View {
    @ObservedObject var targets: TargetDispatcher
    let item: TargetItem
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(TargetText.label(item.ziel), systemImage: TargetText.icon(item.ziel))
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(TargetText.status(item))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text(item.text)
                .font(.footnote).foregroundStyle(.secondary)
                .lineLimit(3)

            switch item.status {
            case .laeuft:
                HStack(spacing: 10) {
                    ProgressView()
                    Text(Loc.t("wird bearbeitet …")).font(.subheadline)
                    Spacer()
                    Button(Loc.t("Abbrechen"), role: .cancel) { targets.cancel(item.id) }
                        .buttonStyle(.bordered)
                }
            case .wartet, .abgebrochen:
                if let error = item.letzterFehler {
                    Label(TargetText.error(error), systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
                if item.status == .wartet {
                    Text(Loc.t("Das Diktat wartet und wird automatisch erneut gesendet."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { targets.deliver(item.id) } label: {
                    Label(Loc.t("Erneut senden"), systemImage: "arrow.clockwise")
                        .frame(minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
            case .fertig, .fehler:
                if let result = TargetText.result(item) {
                    Text(result)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = result
                            copied = true
                            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                        } label: {
                            Label(copied ? Loc.t("Kopiert ✓") : Loc.t("Kopieren"), systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        ShareLink(item: result) {
                            Label(Loc.t("Teilen"), systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Text(item.status == .fehler ? Loc.t("Der Dienst konnte das Diktat nicht bearbeiten.")
                                                : Loc.t("Erledigt, ohne Rückmeldung."))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }
}

/// „1 Diktat wartet“ — sichtbar, solange etwas nicht angekommen ist.
struct TargetPendingBanner: View {
    @ObservedObject var targets: TargetDispatcher

    var body: some View {
        let waiting = targets.log.pending
        if !waiting.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.up").foregroundStyle(.orange)
                Text(waiting.count == 1 ? Loc.t("1 Diktat wartet")
                                        : Loc.f("%d Diktate warten", waiting.count))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button(Loc.t("Jetzt senden")) { targets.retryPending() }
                    .buttonStyle(.bordered)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.12)))
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Verlauf

struct TargetHistoryView: View {
    @ObservedObject var targets: TargetDispatcher
    @State private var confirmClear = false

    var body: some View {
        List {
            if targets.log.items.isEmpty {
                Text(Loc.t("Noch keine Diktate an TT-brAIn oder Claude."))
                    .foregroundStyle(.secondary)
            }
            ForEach(targets.log.items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.zeit, format: .dateTime.day().month().hour().minute())
                        .font(.caption2).foregroundStyle(.secondary)
                    TargetItemCard(targets: targets, item: item)
                }
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { targets.delete(item.id) } label: {
                        Label(Loc.t("Löschen"), systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(Loc.t("Verlauf der Ziele"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !targets.log.items.isEmpty {
                Button(Loc.t("Leeren")) { confirmClear = true }
            }
        }
        .confirmationDialog(Loc.t("Verlauf der Ziele leeren?"), isPresented: $confirmClear,
                            titleVisibility: .visible) {
            Button(Loc.t("Erledigte löschen"), role: .destructive) { targets.clearHistory() }
            Button(Loc.t("Abbrechen"), role: .cancel) {}
        } message: {
            Text(Loc.t("Wartende Diktate bleiben erhalten, bis sie angekommen sind."))
        }
    }
}

// MARK: - Einstellungen

struct TargetSettingsPage: View {
    @ObservedObject var targets: TargetDispatcher
    @AppStorage(TargetSettings.enabledKey) private var enabled = false
    @AppStorage(TargetSettings.addressKey) private var address = ""
    @State private var tokenInput = ""
    @State private var hasToken = TargetSettings.token() != nil
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle(Loc.t("Ziele anzeigen"), isOn: $enabled)
                    .onChange(of: enabled) { _, on in if on { targets.retryPending() } }
            } footer: {
                Text(Loc.t("Nach jeder Aufnahme stehen dann drei Knöpfe zur Wahl: Text (wie bisher), TT-brAIn (Termin, Erinnerung, Notiz) und Claude fragen. Aus = alles bleibt wie gewohnt."))
            }

            Section {
                TextField("http://100.x.y.z:8765", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !address.isEmpty, TargetSettings.normalizedBase(address) == nil {
                    Text(Loc.t("Diese Adresse ist nicht lesbar."))
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text(Loc.t("Adresse des Dienstes"))
            } footer: {
                Text(Loc.t("Nur im eigenen Netz (Tailnet). Diktate gehen an keine andere Adresse."))
            }

            Section {
                SecureField(hasToken ? Loc.t("Hinterlegt – zum Ändern neu eingeben")
                                     : Loc.t("Gerätewort einfügen"), text: $tokenInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                Button(Loc.t("Gerätewort speichern")) { saveToken() }
                    .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasToken {
                    Button(Loc.t("Gerätewort entfernen"), role: .destructive) {
                        try? TargetSettings.storeToken("")
                        hasToken = false
                        message = Loc.t("Gerätewort entfernt.")
                    }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text(Loc.t("Gerätewort"))
            } footer: {
                Text(Loc.t("Wird im Schlüsselbund dieses iPhones gespeichert und nie angezeigt."))
            }

            Section {
                NavigationLink { TargetHistoryView(targets: targets) } label: {
                    LabeledContent(Loc.t("Verlauf der Ziele"),
                                   value: "\(targets.log.items.count)")
                }
            } footer: {
                Text(Loc.t("Die letzten 20 Diktate mit Ziel und Ergebnis, nur auf diesem Gerät."))
            }
        }
        .navigationTitle(Loc.t("Ziele"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func saveToken() {
        do {
            try TargetSettings.storeToken(tokenInput)
            tokenInput = ""
            hasToken = true
            message = Loc.t("Gerätewort gespeichert.")
            targets.retryPending()
        } catch {
            message = Loc.t("Gerätewort konnte nicht gespeichert werden.")
        }
    }
}
