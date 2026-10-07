import SwiftUI

/// Das Konnexion-Zeichen (Rahmen mit drei Quadraten) als Vektor, mit einer
/// Schallwelle im vierten Feld — dasselbe Motiv wie das App-Icon.
/// Maße aus dem Original-Logo (Rahmen 23000 Einheiten breit).
struct KonnexionMark: View {
    var color: Color = .shoutLive

    var body: some View {
        Canvas { context, size in
            let u = min(size.width, size.height) / 23000
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: x * u, y: y * u, width: w * u, height: h * u)
            }
            let shading = GraphicsContext.Shading.color(color)

            var frame = Path(r(0, 0, 23000, 23000))
            frame.addPath(Path(r(1628, 1628, 23000 - 2 * 1628, 23000 - 2 * 1628)))
            context.fill(frame, with: shading, style: FillStyle(eoFill: true))

            let s: CGFloat = 7330
            context.fill(Path(r(3389, 2963, s, s)), with: shading)
            context.fill(Path(r(12262, 2963, s, s)), with: shading)
            context.fill(Path(r(3389, 12030, s, s)), with: shading)

            let cell = r(12262, 12030, s, s)
            let bw = cell.width * 0.17
            let gap = (cell.width - 3 * bw) / 2
            for (i, h) in [0.55, 1.0, 0.7].enumerated() {
                let bh = cell.height * h
                let bar = CGRect(x: cell.minX + CGFloat(i) * (bw + gap),
                                 y: cell.midY - bh / 2, width: bw, height: bh)
                context.fill(Path(roundedRect: bar, cornerRadius: bw / 2), with: shading)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// Kopfzeile „▣ shout." für die Startseite.
struct BrandTitle: View {
    var body: some View {
        HStack(spacing: 8) {
            KonnexionMark().frame(width: 22, height: 22)
            Text("shout.")
                .font(.headline.weight(.bold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("shout.")
    }
}

