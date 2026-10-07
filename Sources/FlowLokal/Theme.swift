import SwiftUI

/// Farbwelt „Mischpult, sanft": dunkles Graphit-Panel, ein warmes Vermillion
/// als „live"/Aktiv-Akzent.
extension Color {
    #if os(iOS)
    /// iPhone-Fassung im Konnexion-Look: Konnexion-Blau (#005DA4) statt Vermillion.
    /// Im Dunkelmodus heller, sonst verschwindet Blau auf Schwarz als Schrift- und Symbolfarbe.
    static let shoutLive = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.30, green: 0.58, blue: 0.86, alpha: 1)   // #4D94DB
            : UIColor(red: 0.0, green: 0.365, blue: 0.643, alpha: 1)  // #005DA4
    })
    /// Konnexion-Anthrazit (#2B2B2A) aus dem Logo.
    static let konnexionAnthracite = Color(red: 0.169, green: 0.169, blue: 0.165)
    #else
    /// „live"-Signalfarbe (kräftiges, sattes Rot-Orange) — Aufnahme, aktive Schalter, Lern-Akzent.
    static let shoutLive = Color(red: 1.0, green: 0.29, blue: 0.04)
    #endif
    /// Fenster-/Panel-Hintergrund (Graphit).
    static let shoutPanel = Color(red: 0.145, green: 0.145, blue: 0.165)
    static let shoutPanelHi = Color(red: 0.19, green: 0.19, blue: 0.21)
    /// Vertiefte Flächen (Inset).
    static let shoutInset = Color(red: 0.10, green: 0.10, blue: 0.12)
    /// Fenster-Hintergrund (dunkler als die Panels, damit sie sich abheben).
    static let shoutWindow = Color(red: 0.105, green: 0.105, blue: 0.125)
    /// Seitenleisten-Hintergrund (noch etwas dunkler).
    static let shoutSidebar = Color(red: 0.085, green: 0.085, blue: 0.10)
}
