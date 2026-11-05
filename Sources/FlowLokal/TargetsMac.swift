import AppKit
import SwiftUI

// MARK: - Zieltaste

/// Eigene Taste für „aufnehmen und dann Ziel wählen“. Die gewohnte
/// Diktiertaste bleibt unberührt und fügt weiter sofort ein.
///
/// Bewusst eine kleine feste Auswahl statt eines Tastenrekorders: Die
/// Kombinationen sind auf Kollisionen mit den festen Kürzeln (⌥⌘C, ⌃⌘V, ⌘V)
/// geprüft, und eine F-Taste geht ohne Modifier.
enum TargetHotkey: String, CaseIterable {
    case ctrlOptionSpace
    case ctrlOptionT
    case f6
    case f7

    static let storageKey = "targetsHotkey"
    static let fallback: TargetHotkey = .ctrlOptionSpace

    static var current: TargetHotkey {
        TargetHotkey(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? fallback
    }

    var keyCode: UInt16 {
        switch self {
        case .ctrlOptionSpace: return 49
        case .ctrlOptionT: return 17
        case .f6: return 97
        case .f7: return 98
        }
    }

    var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .ctrlOptionSpace, .ctrlOptionT: return [.control, .option]
        case .f6, .f7: return []
        }
    }

    @MainActor var label: String {
        switch self {
        case .ctrlOptionSpace: return "⌃⌥ " + Loc.t("Leertaste")
        case .ctrlOptionT: return "⌃⌥T"
        case .f6: return "F6"
        case .f7: return "F7"
        }
    }

    func matches(keyCode: UInt16, modifiers raw: NSEvent.ModifierFlags) -> Bool {
        // fn gehört bei F-Tasten auf manchen Tastaturen dazu — nicht mitzählen.
        let mods = raw.intersection([.command, .option, .control, .shift])
        return keyCode == self.keyCode && mods == modifiers
    }
}

// MARK: - Auswahlfenster nach der Aufnahme

/// Kleines schwebendes Fenster oben rechts. Es nimmt der Ziel-App den Fokus
/// nicht weg (`nonactivatingPanel`) — deshalb landet „Text“ dort, wo vor der
/// Aufnahme der Cursor stand.
@MainActor
final class MacTargetPanel {
    private var panel: NSPanel?
    private var resizeObserver: NSObjectProtocol?

    func show(targets: TargetDispatcher, text: String, onText: @escaping () -> Void) {
        close()
        targets.offer(text)
        let view = MacTargetPanelView(
            targets: targets, text: text,
            onText: { [weak self] in onText(); self?.close() },
            onClose: { [weak self] in targets.dismissOffer(); self?.close() })
        // Der Inhalt wächst, wenn die Antwort kommt: Größe vom SwiftUI-Inhalt
        // übernehmen und die Oberkante dabei oben rechts festhalten.
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentViewController = controller
        anchor(panel)
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in if let p = self?.panel { self?.anchor(p) } }
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func anchor(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(x: vf.maxX - size.width - 16, y: vf.maxY - size.height - 16)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    func close() {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct MacTargetPanelView: View {
    @ObservedObject var targets: TargetDispatcher
    let text: String
    let onText: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Loc.t("Wohin damit?")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help(Loc.t("Schließen"))
            }
            Text(text).font(.callout).lineLimit(3)

            if targets.offeredText != nil {
                HStack(spacing: 6) {
                    ForEach(DictationTarget.primary, id: \.self) { ziel in
                        choice(ziel)
                    }
                }
                HStack(spacing: 6) {
                    ForEach(DictationTarget.auftragReihe, id: \.self) { ziel in
                        choice(ziel)
                    }
                }
                HStack(spacing: 6) {
                    ForEach(AssistantApp.allCases, id: \.self) { app in
                        Button {
                            guard let url = app.url(for: text) else { return }
                            copy(text)
                            targets.dismissOffer()
                            NSWorkspace.shared.open(url)
                            onClose()
                        } label: {
                            Label(app.title, systemImage: "arrow.up.forward.app")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                    }
                }
            } else if let item = targets.activeItem {
                MacTargetItemView(targets: targets, item: item, showText: false)
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func choice(_ ziel: DictationTarget) -> some View {
        let button = Button {
            if ziel == .text {
                targets.choose(.text)
                onText()
            } else {
                targets.choose(ziel)
            }
        } label: {
            Label(TargetText.label(ziel), systemImage: TargetText.icon(ziel))
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        if ziel == targets.lastTarget {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Ein Eintrag: Zustand, Ergebnis, Kopieren, „Erneut senden“.
struct MacTargetItemView: View {
    @ObservedObject var targets: TargetDispatcher
    let item: TargetItem
    var showText = true
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(TargetText.label(item.ziel), systemImage: TargetText.icon(item.ziel))
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(TargetText.status(item)).font(.caption).foregroundStyle(.secondary)
            }
            if showText {
                Text(item.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            switch item.status {
            case .laeuft:
                HStack {
                    ProgressView().controlSize(.small)
                    Text(Loc.t("wird bearbeitet …")).font(.callout)
                    Spacer()
                    Button(Loc.t("Abbrechen")) { targets.cancel(item.id) }
                }
            case .wartet, .abgebrochen:
                if let error = item.letzterFehler {
                    Label(TargetText.error(error), systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                if item.status == .wartet {
                    Text(Loc.t("Das Diktat wartet und wird automatisch erneut gesendet."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(Loc.t("Erneut senden")) { targets.deliver(item.id) }
            case .fertig, .fehler:
                if let result = TargetText.result(item) {
                    ScrollView {
                        Text(result).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    Button(copied ? Loc.t("Kopiert ✓") : Loc.t("Kopieren")) {
                        copy(result)
                        copied = true
                    }
                } else {
                    Text(item.status == .fehler ? Loc.t("Der Dienst konnte das Diktat nicht bearbeiten.")
                                                : Loc.t("Erledigt, ohne Rückmeldung."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Einstellungen

/// Bereich „Ziele“ auf der Seite „Aufnahme & Text“.
struct MacTargetsSettings: View {
    @ObservedObject var targets: TargetDispatcher
    @AppStorage(TargetSettings.enabledKey) private var enabled = false
    @AppStorage(TargetSettings.addressKey) private var address = ""
    @AppStorage(TargetHotkey.storageKey) private var hotkey = TargetHotkey.fallback.rawValue
    @State private var tokenInput = ""
    @State private var hasToken = TargetSettings.token() != nil
    @State private var message: String?

    var body: some View {
        ConsolePanel(title: Loc.t("Ziele")) {
            FieldRow(title: Loc.t("Zieltaste"),
                     help: Loc.t("Aufnehmen und danach wählen: Text, TT-brAIn, Claude fragen, Claude-App oder ChatGPT-App. Einmal drücken zum Starten, nochmal zum Stoppen. Die Diktiertaste bleibt wie gewohnt.")) {
                HStack(spacing: 10) {
                    Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.switch).tint(Color.shoutLive)
                    Picker("", selection: $hotkey) {
                        ForEach(TargetHotkey.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: 150)
                    .disabled(!enabled)
                }
            }
            ConsoleDivider()
            FieldRow(title: Loc.t("Adresse des Dienstes"),
                     help: Loc.t("Nur im eigenen Netz (Tailnet). Am besten den Rechnernamen ohne Punkte, z. B. http://rechnername:8765.")) {
                TextField("http://rechnername:8765", text: $address)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
            }
            ConsoleDivider()
            FieldRow(title: Loc.t("Gerätewort"),
                     help: hasToken ? Loc.t("Hinterlegt – zum Ändern neu eingeben")
                                    : Loc.t("Wird im Schlüsselbund gespeichert und nie angezeigt.")) {
                HStack(spacing: 8) {
                    SecureField(Loc.t("Gerätewort einfügen"), text: $tokenInput)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 150)
                    Button(Loc.t("Speichern")) { saveToken() }
                        .buttonStyle(ConsoleButtonStyle())
                        .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if !targets.log.items.isEmpty {
                ConsoleDivider()
                HStack {
                    Text(Loc.t("Verlauf der Ziele")).font(.callout.weight(.semibold))
                    Spacer()
                    Button(Loc.t("Erledigte löschen")) { targets.clearHistory() }
                        .buttonStyle(ConsoleButtonStyle())
                }
                ForEach(targets.log.items) { item in
                    HStack(alignment: .top) {
                        MacTargetItemView(targets: targets, item: item)
                        Button { targets.delete(item.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help(Loc.t("Löschen"))
                    }
                    .padding(.vertical, 4)
                }
            }
        }
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
