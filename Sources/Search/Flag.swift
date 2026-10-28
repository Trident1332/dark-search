import SwiftUI

/// A country's flag, flat: a few shapes drawn here, rather than the Mac's
/// emoji flags, which wave. Stripes, crosses, discs, stars, a canton or a
/// hoist triangle cover most of the world; a flag that is mostly a crest
/// or a device these can't draw is shown as its two-letter code in a quiet
/// badge instead, never as a wrong flag. Settings › Proxy shows one beside
/// where sites see you from.
struct FlatFlag: View {
    /// ISO 3166 alpha-2, upper case (see ProxyCountry.normalized).
    let code: String
    var width: CGFloat = 18

    private var height: CGFloat { width * 2 / 3 }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: width / 9, style: .continuous) }

    var body: some View {
        Group {
            if let pieces = FlatFlag.designs[code] {
                Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                    for piece in pieces { piece.draw(in: &context, size: size) }
                }
            } else {
                Text(code)
                    .font(.system(size: width * 0.36, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(Palette.muted)
                    .frame(width: width, height: height)
                    .background(Palette.wash)
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        // A hairline keeps a flag with white at its edge from bleeding into
        // the page; a touch of shadow lifts it off a dark one.
        .overlay(shape.strokeBorder(Palette.ink.opacity(0.14), lineWidth: 0.5))
        .accessibilityLabel(Locale.current.localizedString(forRegionCode: code) ?? code)
    }

    // MARK: - the shapes

    /// One layer of a flag, in fractions of its width and height.
    enum Piece {
        case field(Color)
        /// Horizontal bands, top to bottom, each as wide as its weight.
        case rows([(Color, CGFloat)])
        /// Vertical bands, hoist to fly.
        case columns([(Color, CGFloat)])
        case rect(Color, CGRect)
        /// A disc; `r` is a fraction of the height.
        case disc(Color, x: CGFloat, y: CGFloat, r: CGFloat)
        case ring(Color, x: CGFloat, y: CGFloat, r: CGFloat, line: CGFloat)
        /// A cross whose upright stands at `x`; `thick` is a fraction of the height.
        case cross(Color, x: CGFloat, thick: CGFloat)
        /// Both diagonals.
        case saltire(Color, thick: CGFloat)
        case star(Color, x: CGFloat, y: CGFloat, r: CGFloat)
        /// A triangle from the hoist, its point this far across.
        case hoist(Color, width: CGFloat)
        case diamond(Color, inset: CGFloat)
        /// A crescent open to the fly: a disc with the field's colour cut back in.
        case crescent(Color, x: CGFloat, y: CGFloat, r: CGFloat, field: Color)
        case hexagram(Color, x: CGFloat, y: CGFloat, r: CGFloat)

        func draw(in context: inout GraphicsContext, size: CGSize) {
            let w = size.width, h = size.height
            switch self {
            case .field(let colour):
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(colour))
            case .rows(let bands):
                let total = bands.reduce(0) { $0 + $1.1 }
                var y: CGFloat = 0
                for (colour, weight) in bands {
                    let band = h * weight / total
                    context.fill(Path(CGRect(x: 0, y: y, width: w, height: band + 0.5)), with: .color(colour))
                    y += band
                }
            case .columns(let bands):
                let total = bands.reduce(0) { $0 + $1.1 }
                var x: CGFloat = 0
                for (colour, weight) in bands {
                    let band = w * weight / total
                    context.fill(Path(CGRect(x: x, y: 0, width: band + 0.5, height: h)), with: .color(colour))
                    x += band
                }
            case .rect(let colour, let box):
                context.fill(Path(CGRect(x: box.minX * w, y: box.minY * h, width: box.width * w, height: box.height * h)), with: .color(colour))
            case .disc(let colour, let x, let y, let r):
                context.fill(Path(ellipseIn: CGRect(x: x * w - r * h, y: y * h - r * h, width: 2 * r * h, height: 2 * r * h)), with: .color(colour))
            case .ring(let colour, let x, let y, let r, let line):
                context.stroke(Path(ellipseIn: CGRect(x: x * w - r * h, y: y * h - r * h, width: 2 * r * h, height: 2 * r * h)),
                               with: .color(colour), lineWidth: line * h)
            case .cross(let colour, let x, let thick):
                let t = thick * h
                context.fill(Path(CGRect(x: 0, y: (h - t) / 2, width: w, height: t)), with: .color(colour))
                context.fill(Path(CGRect(x: x * w - t / 2, y: 0, width: t, height: h)), with: .color(colour))
            case .saltire(let colour, let thick):
                var path = Path()
                path.move(to: .zero); path.addLine(to: CGPoint(x: w, y: h))
                path.move(to: CGPoint(x: w, y: 0)); path.addLine(to: CGPoint(x: 0, y: h))
                context.stroke(path, with: .color(colour), lineWidth: thick * h)
            case .star(let colour, let x, let y, let r):
                context.fill(Piece.star(at: CGPoint(x: x * w, y: y * h), outer: r * h), with: .color(colour))
            case .hoist(let colour, let width):
                var path = Path()
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: width * w, y: h / 2))
                path.addLine(to: CGPoint(x: 0, y: h))
                path.closeSubpath()
                context.fill(path, with: .color(colour))
            case .diamond(let colour, let inset):
                var path = Path()
                path.move(to: CGPoint(x: w / 2, y: inset * h))
                path.addLine(to: CGPoint(x: w - inset * w, y: h / 2))
                path.addLine(to: CGPoint(x: w / 2, y: h - inset * h))
                path.addLine(to: CGPoint(x: inset * w, y: h / 2))
                path.closeSubpath()
                context.fill(path, with: .color(colour))
            case .crescent(let colour, let x, let y, let r, let field):
                let d = 2 * r * h
                context.fill(Path(ellipseIn: CGRect(x: x * w - r * h, y: y * h - r * h, width: d, height: d)), with: .color(colour))
                let inner = r * 0.8 * h
                context.fill(Path(ellipseIn: CGRect(x: x * w - inner + r * h * 0.45, y: y * h - inner, width: 2 * inner, height: 2 * inner)), with: .color(field))
            case .hexagram(let colour, let x, let y, let r):
                let centre = CGPoint(x: x * w, y: y * h)
                for flipped in [false, true] {
                    var path = Path()
                    for i in 0..<3 {
                        let angle = (-CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / 3) + (flipped ? .pi : 0)
                        let point = CGPoint(x: centre.x + cos(angle) * r * h, y: centre.y + sin(angle) * r * h)
                        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    path.closeSubpath()
                    context.stroke(path, with: .color(colour), lineWidth: max(0.6, r * h * 0.18))
                }
            }
        }

        private static func star(at centre: CGPoint, outer: CGFloat) -> Path {
            var path = Path()
            let inner = outer * 0.382
            for i in 0..<10 {
                let radius = i.isMultiple(of: 2) ? outer : inner
                let angle = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
                let point = CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            return path
        }
    }

    // MARK: - the flags

    private static func c(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    private static let white = Color.white
    private static let black = c(0x000000)

    private static func rows(_ colours: Color...) -> Piece { .rows(colours.map { ($0, 1) }) }
    private static func columns(_ colours: Color...) -> Piece { .columns(colours.map { ($0, 1) }) }
    private static func alternating(_ a: Color, _ b: Color, _ count: Int) -> Piece {
        .rows((0..<count).map { ($0.isMultiple(of: 2) ? a : b, 1) })
    }

    /// Each flag as its layers, hoist at the left, in rough proportion.
    /// Devices too small to read at this size (coats of arms, suns, words,
    /// small stars) are left off rather than smudged in.
    static let designs: [String: [Piece]] = [
        // Horizontal bands
        "DE": [rows(black, c(0xDD0000), c(0xFFCE00))],
        "AT": [rows(c(0xED2939), white, c(0xED2939))],
        "NL": [rows(c(0xAE1C28), white, c(0x21468B))],
        "LU": [rows(c(0xED2939), white, c(0x00A1DE))],
        "RU": [rows(white, c(0x0039A6), c(0xD52B1E))],
        "HU": [rows(c(0xCE2939), white, c(0x477050))],
        "BG": [rows(white, c(0x00966E), c(0xD62612))],
        "EE": [rows(c(0x0072CE), black, white)],
        "LT": [rows(c(0xFDB913), c(0x006A44), c(0xC1272D))],
        "LV": [.rows([(c(0x9E3039), 2), (white, 1), (c(0x9E3039), 2)])],
        "UA": [rows(c(0x0057B7), c(0xFFD700))],
        "PL": [rows(white, c(0xDC143C))],
        "ID": [rows(c(0xCE1126), white)],
        "MC": [rows(c(0xCE1126), white)],
        "AR": [rows(c(0x74ACDF), white, c(0x74ACDF))],
        "CO": [.rows([(c(0xFCD116), 2), (c(0x003893), 1), (c(0xCE1126), 1)])],
        "EC": [.rows([(c(0xFFDD00), 2), (c(0x034EA2), 1), (c(0xED1C24), 1)])],
        "VE": [rows(c(0xFFCC00), c(0x00247D), c(0xCF142B))],
        "BO": [rows(c(0xD52B1E), c(0xF9E300), c(0x007934))],
        "ES": [.rows([(c(0xAA151B), 1), (c(0xF1BF00), 2), (c(0xAA151B), 1)])],
        "YE": [rows(c(0xCE1126), white, black)],
        "EG": [rows(c(0xCE1126), white, black)],
        "IQ": [rows(c(0xCE1126), white, black)],
        "SY": [rows(c(0x007A3D), white, black)],
        "AM": [rows(c(0xD90012), c(0x0033A0), c(0xF2A800))],
        "HR": [rows(c(0xFF0000), white, c(0x171796))],
        "RS": [rows(c(0xC6363C), c(0x0C4076), white)],
        "SI": [rows(white, c(0x005DA4), c(0xED1C24))],
        "SK": [rows(white, c(0x0B4EA2), c(0xEE1C25))],
        "TH": [.rows([(c(0xA51931), 1), (white, 1), (c(0x2D2A4A), 2), (white, 1), (c(0xA51931), 1)])],
        "CR": [.rows([(c(0x002B7F), 1), (white, 1), (c(0xCE1126), 2), (white, 1), (c(0x002B7F), 1)])],
        "GA": [rows(c(0x009E60), c(0xFCD116), c(0x3A75C4))],
        "SL": [rows(c(0x1EB53A), white, c(0x0072C6))],
        "LI": [rows(c(0x002B7F), c(0xCE1126))],
        "GH": [rows(c(0xCE1126), c(0xFCD116), c(0x006B3F)), .star(black, x: 0.5, y: 0.5, r: 0.2)],
        "IR": [rows(c(0x239F40), white, c(0xDA0000))],
        "IN": [rows(c(0xFF9933), white, c(0x138808)), .ring(c(0x000080), x: 0.5, y: 0.5, r: 0.13, line: 0.04)],
        "NE": [rows(c(0xE05206), white, c(0x0DB02B)), .disc(c(0xE05206), x: 0.5, y: 0.5, r: 0.14)],
        "ET": [rows(c(0x078930), c(0xFCDD09), c(0xDA121A)), .disc(c(0x0F47AF), x: 0.5, y: 0.5, r: 0.3), .star(c(0xFCDD09), x: 0.5, y: 0.5, r: 0.22)],
        "UZ": [.rows([(c(0x0099B5), 1), (c(0xCE1126), 0.12), (white, 0.76), (c(0xCE1126), 0.12), (c(0x1EB53A), 1)])],
        "AZ": [rows(c(0x00B5E2), c(0xEF3340), c(0x509E2F)), .crescent(white, x: 0.45, y: 0.5, r: 0.15, field: c(0xEF3340))],
        "BY": [.rows([(c(0xC8313E), 2), (c(0x4AA657), 1)]), .rect(white, CGRect(x: 0, y: 0, width: 0.11, height: 1))],
        "AE": [rows(c(0x00732F), white, black), .rect(c(0xFF0000), CGRect(x: 0, y: 0, width: 0.25, height: 1))],
        "KW": [rows(c(0x007A3D), white, c(0xCE1126)), .hoist(black, width: 0.25)],
        "LA": [.rows([(c(0xCE1126), 1), (c(0x002868), 2), (c(0xCE1126), 1)]), .disc(white, x: 0.5, y: 0.5, r: 0.2)],
        "SG": [rows(c(0xEF3340), white), .crescent(white, x: 0.2, y: 0.25, r: 0.14, field: c(0xEF3340))],
        "QA": [.field(c(0x8A1538)), .rect(white, CGRect(x: 0, y: 0, width: 0.3, height: 1))],
        "BH": [.field(c(0xCE1126)), .rect(white, CGRect(x: 0, y: 0, width: 0.25, height: 1))],
        "IL": [.field(white), .rect(c(0x0038B8), CGRect(x: 0, y: 0.14, width: 1, height: 0.12)),
               .rect(c(0x0038B8), CGRect(x: 0, y: 0.74, width: 1, height: 0.12)), .hexagram(c(0x0038B8), x: 0.5, y: 0.5, r: 0.2)],
        "GR": [alternating(c(0x0D5EAF), white, 9), .rect(c(0x0D5EAF), CGRect(x: 0, y: 0, width: 0.37, height: 0.555)),
               .rect(white, CGRect(x: 0, y: 0.22, width: 0.37, height: 0.115)), .rect(white, CGRect(x: 0.145, y: 0, width: 0.08, height: 0.555))],
        "UY": [alternating(white, c(0x0038A8), 9), .rect(white, CGRect(x: 0, y: 0, width: 0.33, height: 0.555))],
        "US": [alternating(c(0xB22234), white, 13), .rect(c(0x3C3B6E), CGRect(x: 0, y: 0, width: 0.4, height: 7 / 13))],
        "CL": [rows(white, c(0xD52B1E)), .rect(c(0x0039A6), CGRect(x: 0, y: 0, width: 0.333, height: 0.5)), .star(white, x: 0.167, y: 0.25, r: 0.17)],
        "TW": [.field(c(0xFE0000)), .rect(c(0x000095), CGRect(x: 0, y: 0, width: 0.5, height: 0.5)), .disc(white, x: 0.25, y: 0.25, r: 0.14)],
        "MY": [alternating(c(0xCC0001), white, 14), .rect(c(0x010066), CGRect(x: 0, y: 0, width: 0.5, height: 0.5)),
               .crescent(c(0xFFCC00), x: 0.2, y: 0.25, r: 0.15, field: c(0x010066))],
        // Hoist triangles
        "CZ": [rows(white, c(0xD7141A)), .hoist(c(0x11457E), width: 0.5)],
        "PH": [rows(c(0x0038A8), c(0xCE1126)), .hoist(white, width: 0.45)],
        "JO": [rows(black, white, c(0x007A3D)), .hoist(c(0xCE1126), width: 0.45)],
        "PS": [rows(black, white, c(0x007A3D)), .hoist(c(0xCE1126), width: 0.4)],
        "SD": [rows(c(0xD21034), white, black), .hoist(c(0x007229), width: 0.33)],
        "CU": [alternating(c(0x002A8F), white, 5), .hoist(c(0xCF142B), width: 0.42)],
        "PR": [alternating(c(0xED0000), white, 5), .hoist(c(0x0050F0), width: 0.42)],
        "BS": [rows(c(0x00778B), c(0xFFC72C), c(0x00778B)), .hoist(black, width: 0.38)],
        // Vertical bands
        "FR": [columns(c(0x0055A4), white, c(0xEF4135))],
        "IT": [columns(c(0x009246), white, c(0xCE2B37))],
        "IE": [columns(c(0x169B62), white, c(0xFF883E))],
        "BE": [columns(black, c(0xFAE042), c(0xED2939))],
        "RO": [columns(c(0x002B7F), c(0xFCD116), c(0xCE1126))],
        "MD": [columns(c(0x0046AE), c(0xFFD200), c(0xCC092F))],
        "AD": [columns(c(0x10069F), c(0xFEDF00), c(0xD50032))],
        "TD": [columns(c(0x002664), c(0xFECB00), c(0xC60C30))],
        "ML": [columns(c(0x14B53A), c(0xFCD116), c(0xCE1126))],
        "GN": [columns(c(0xCE1126), c(0xFCD116), c(0x009460))],
        "NG": [columns(c(0x008751), white, c(0x008751))],
        "CI": [columns(c(0xFF8200), white, c(0x009E60))],
        "PE": [columns(c(0xD91023), white, c(0xD91023))],
        "MX": [columns(c(0x006847), white, c(0xCE1126))],
        "GT": [columns(c(0x4997D0), white, c(0x4997D0))],
        "CM": [columns(c(0x007A5E), c(0xCE1126), c(0xFCD116)), .star(c(0xFCD116), x: 0.5, y: 0.5, r: 0.18)],
        "SN": [columns(c(0x00853F), c(0xFDEF42), c(0xE31B23)), .star(c(0x00853F), x: 0.5, y: 0.5, r: 0.18)],
        "PT": [.columns([(c(0x006600), 2), (c(0xFF0000), 3)]), .ring(c(0xFFE500), x: 0.4, y: 0.5, r: 0.2, line: 0.06)],
        "DZ": [columns(c(0x006233), white), .crescent(c(0xD21034), x: 0.5, y: 0.5, r: 0.24, field: white)],
        "PK": [.field(c(0x01411C)), .rect(white, CGRect(x: 0, y: 0, width: 0.25, height: 1)), .crescent(white, x: 0.62, y: 0.5, r: 0.26, field: c(0x01411C))],
        // Crosses
        "DK": [.field(c(0xC8102E)), .cross(white, x: 0.37, thick: 0.14)],
        "SE": [.field(c(0x006AA7)), .cross(c(0xFECC00), x: 0.37, thick: 0.16)],
        "NO": [.field(c(0xBA0C2F)), .cross(white, x: 0.37, thick: 0.24), .cross(c(0x00205B), x: 0.37, thick: 0.12)],
        "FI": [.field(white), .cross(c(0x002F6C), x: 0.37, thick: 0.18)],
        "IS": [.field(c(0x02529C)), .cross(white, x: 0.37, thick: 0.24), .cross(c(0xDC1E35), x: 0.37, thick: 0.12)],
        "CH": [.field(c(0xFF0000)), .rect(white, CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.6)), .rect(white, CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.2))],
        "GE": [.field(white), .cross(c(0xFF0000), x: 0.5, thick: 0.2)],
        "GB": [.field(c(0x012169)), .saltire(white, thick: 0.2), .saltire(c(0xC8102E), thick: 0.07), .cross(white, x: 0.5, thick: 0.33), .cross(c(0xC8102E), x: 0.5, thick: 0.2)],
        "DO": [.field(white), .rect(c(0x002D62), CGRect(x: 0, y: 0, width: 0.5, height: 0.5)), .rect(c(0xCE1126), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)),
               .rect(c(0xCE1126), CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)), .rect(c(0x002D62), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)), .cross(white, x: 0.5, thick: 0.2)],
        // Discs, stars and crescents on a field
        "JP": [.field(white), .disc(c(0xBC002D), x: 0.5, y: 0.5, r: 0.3)],
        "BD": [.field(c(0x006A4E)), .disc(c(0xF42A41), x: 0.45, y: 0.5, r: 0.3)],
        "PW": [.field(c(0x4AADD6)), .disc(c(0xFFDE00), x: 0.45, y: 0.5, r: 0.3)],
        "KZ": [.field(c(0x00AFCA)), .disc(c(0xFEC50C), x: 0.5, y: 0.5, r: 0.25)],
        "VN": [.field(c(0xDA251D)), .star(c(0xFFFF00), x: 0.5, y: 0.5, r: 0.3)],
        "CN": [.field(c(0xEE1C25)), .star(c(0xFFFF00), x: 0.17, y: 0.27, r: 0.2)],
        "MA": [.field(c(0xC1272D)), .star(c(0x006233), x: 0.5, y: 0.5, r: 0.26)],
        "SO": [.field(c(0x4189DD)), .star(white, x: 0.5, y: 0.5, r: 0.28)],
        "TR": [.field(c(0xE30A17)), .crescent(white, x: 0.36, y: 0.5, r: 0.26, field: c(0xE30A17)), .star(white, x: 0.6, y: 0.5, r: 0.12)],
        "TN": [.field(c(0xE70013)), .disc(white, x: 0.5, y: 0.5, r: 0.3), .crescent(c(0xE70013), x: 0.49, y: 0.5, r: 0.2, field: white)],
        "BR": [.field(c(0x009C3B)), .diamond(c(0xFEDF00), inset: 0.1), .disc(c(0x002776), x: 0.5, y: 0.5, r: 0.24)],
    ]
}
