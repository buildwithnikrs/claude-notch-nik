import SwiftUI

enum MascotMood: Equatable {
    case idle, working, thinking, waiting, acknowledging, celebrating
}

/// Mascot rendering abstraction (PRD §43). The UI only ever asks for a mood; swap this
/// implementation to use different artwork without touching the rest of the app.
protocol MascotRenderer {
    func view(mood: MascotMood, height: CGFloat, animated: Bool) -> AnyView
}

struct MascotView: View {
    var mood: MascotMood
    var height: CGFloat
    var animated: Bool
    var renderer: MascotRenderer = PixelCritter()

    var body: some View {
        renderer.view(mood: mood, height: height, animated: animated)
            .id(mood)
            .transition(.asymmetric(insertion: .scale(scale: 0.7).combined(with: .opacity),
                                    removal: .opacity))
            .accessibilityHidden(true)
    }
}

// MARK: - Pixel critter

/// An original little orange critter with a spark on its head, drawn from code
/// (no image assets). 16×14 pixel grid, ~6 fps.
struct PixelCritter: MascotRenderer {
    func view(mood: MascotMood, height: CGFloat, animated: Bool) -> AnyView {
        AnyView(PixelCritterView(mood: mood, height: height, animated: animated))
    }
}

private struct PixelCritterView: View {
    let mood: MascotMood
    let height: CGFloat
    let animated: Bool

    var body: some View {
        // Whole-point pixels keep the art crisp.
        let px = max(1, (height / CGFloat(Sprite.rows)).rounded(.down))
        Group {
            if animated {
                TimelineView(.animation(minimumInterval: 1.0 / 6.0)) { ctx in
                    canvas(time: ctx.date.timeIntervalSinceReferenceDate, px: px)
                }
            } else {
                canvas(time: 0.4, px: px)
            }
        }
        .frame(width: px * CGFloat(Sprite.cols), height: px * CGFloat(Sprite.rows))
    }

    private func canvas(time: TimeInterval, px: CGFloat) -> some View {
        let sprite = Sprite.frame(mood: mood, time: time)
        return Canvas { gc, _ in
            for (y, row) in sprite.pixels.enumerated() {
                for (x, c) in row.enumerated() {
                    guard let base = Sprite.palette[c] else { continue }
                    let color = c == "O" ? Sprite.bodyColor(row: y) : base
                    let rect = CGRect(x: CGFloat(x) * px, y: CGFloat(y + sprite.dy) * px, width: px, height: px)
                    gc.fill(Path(rect), with: .color(color), style: FillStyle(antialiased: false))
                }
            }
        }
    }
}

struct Sprite {
    static let cols = 16
    static let rows = 14

    static let palette: [Character: Color] = [
        "O": Color(red: 0.94, green: 0.67, blue: 0.99),  // body (overridden per row by bodyColor)
        "o": Color(red: 0.55, green: 0.50, blue: 0.86),  // feet
        "E": Color(red: 0.10, green: 0.06, blue: 0.14),  // eyes
        "S": Color.white,                                // head spark
        "L": Color(white: 0.20),                         // laptop lid (dark glass)
        "l": Color(white: 0.38),                         // laptop base
        "G": Color(red: 0.96, green: 0.45, blue: 0.71),  // lid logo glow
        "W": Color.white.opacity(0.85),                  // bubbles, z's
        "P": Color(red: 0.96, green: 0.45, blue: 0.71).opacity(0.75), // cheeks
        "A": Color(red: 0.96, green: 0.45, blue: 0.71),  // attention mark
    ]

    /// The body shades from pink at the top to periwinkle at the feet, echoing the app gradient.
    static func bodyColor(row y: Int) -> Color {
        let t = min(max(Double(y - 3) / 8, 0), 1)
        let top = (r: 0.976, g: 0.659, b: 0.831), bottom = (r: 0.647, g: 0.706, b: 0.988)
        return Color(red: top.r + (bottom.r - top.r) * t, green: top.g + (bottom.g - top.g) * t, blue: top.b + (bottom.b - top.b) * t)
    }

    var pixels: [[Character]]
    var dy: Int = 0

    init() {
        pixels = Array(repeating: Array(repeating: ".", count: Self.cols), count: Self.rows)
    }

    mutating func set(_ x: Int, _ y: Int, _ c: Character) {
        guard x >= 0, x < Self.cols, y >= 0, y < Self.rows else { return }
        pixels[y][x] = c
    }

    mutating func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: Character) {
        for y in y0...y1 { for x in x0...x1 { set(x, y, c) } }
    }

    // MARK: Parts

    mutating func spark(twinkle: Bool) {
        if twinkle {
            set(6, 1, "S"); set(8, 1, "S"); set(7, 2, "S"); set(6, 3, "S"); set(8, 3, "S")
        } else {
            set(7, 1, "S"); fill(6, 2, 8, 2, "S"); set(7, 3, "S")
        }
    }

    mutating func body() {
        fill(4, 4, 11, 4, "O")
        fill(3, 5, 12, 9, "O")
        fill(4, 10, 11, 10, "O")
    }

    mutating func feet() {
        set(4, 11, "o"); set(6, 11, "o"); set(9, 11, "o"); set(11, 11, "o")
    }

    enum Eyes { case open, blink, up, down, happy, closed }

    mutating func eyes(_ e: Eyes) {
        switch e {
        case .open: fill(5, 6, 5, 7, "E"); fill(10, 6, 10, 7, "E")
        case .blink: set(5, 7, "E"); set(10, 7, "E")
        case .up: fill(6, 5, 6, 6, "E"); fill(11, 5, 11, 6, "E")
        case .down: fill(5, 7, 5, 8, "E"); fill(10, 7, 10, 8, "E")
        case .happy:
            set(4, 7, "E"); set(5, 6, "E"); set(6, 7, "E")
            set(9, 7, "E"); set(10, 6, "E"); set(11, 7, "E")
        case .closed: fill(4, 7, 6, 7, "E"); fill(9, 7, 11, 7, "E")
        }
    }

    mutating func cheeks() { set(4, 8, "P"); set(11, 8, "P") }

    mutating func laptop() {
        fill(3, 8, 12, 11, "L")
        set(7, 9, "G"); set(8, 9, "G")
        fill(2, 12, 13, 12, "l")
    }

    // MARK: Frames

    static func frame(mood: MascotMood, time t: TimeInterval) -> Sprite {
        var s = Sprite()
        let beat = Int(t * 6)            // 6 fps
        let blinking = t.truncatingRemainder(dividingBy: 3.7) < 0.16
        let twinkle = (beat / 3) % 2 == 0

        switch mood {
        case .working, .thinking:
            // Mostly typing, with a thinking pause every ~12 s (PRD: deterministic is fine).
            let thinking = mood == .thinking || t.truncatingRemainder(dividingBy: 12) > 9.5
            s.spark(twinkle: thinking ? twinkle : false)
            s.body()
            if thinking {
                s.eyes(blinking ? .blink : .up)
                let dots = (beat / 2) % 4
                if dots >= 1 { s.set(13, 3, "W") }
                if dots >= 2 { s.set(14, 1, "W") }
                if dots >= 3 { s.set(15, 0, "W") }
            } else {
                s.eyes(blinking ? .blink : .down)
            }
            s.laptop()
            if thinking {
                s.set(2, 11, "O"); s.set(13, 11, "O")
            } else {
                // Alternate hands: typing.
                let left = beat % 2 == 0
                s.set(2, left ? 10 : 11, "O")
                s.set(13, left ? 11 : 10, "O")
                if beat % 4 == 0 { s.set(9, 9, "G") } // screen flicker on the lid
            }

        case .waiting:
            s.spark(twinkle: twinkle)
            s.body()
            s.feet()
            s.eyes(blinking ? .blink : .open)
            s.set(2, 8, "O")
            // Wave with the right arm.
            if beat % 2 == 0 { s.set(13, 8, "O"); s.set(14, 7, "O") } else { s.set(13, 7, "O"); s.set(14, 6, "O") }
            // "!" beside the head.
            if (beat / 2) % 3 != 2 { s.fill(15, 1, 15, 3, "A"); s.set(15, 5, "A") }
            s.dy = beat % 4 < 2 ? 0 : -1

        case .acknowledging:
            s.spark(twinkle: true)
            s.body()
            s.feet()
            s.eyes(.happy)
            s.cheeks()
            s.set(2, 8, "O")
            s.set(13, 7, "O"); s.set(14, 6, "O"); s.set(14, 5, "O")
            s.dy = beat % 3 == 0 ? -1 : 0

        case .celebrating:
            let air = beat % 4
            s.spark(twinkle: beat % 2 == 0)
            s.body()
            s.eyes(.happy)
            s.cheeks()
            if air == 1 || air == 2 {
                // Arms up, in the air.
                s.set(2, 5, "O"); s.set(1, 4, "O")
                s.set(13, 5, "O"); s.set(14, 4, "O")
                s.dy = air == 1 ? -1 : -2
            } else {
                s.feet()
                s.set(2, 8, "O"); s.set(13, 8, "O")
            }
            // Sparkles.
            let sp: [(Int, Int)] = [(0, 1), (15, 2), (1, 10), (14, 11), (0, 6), (15, 7)]
            for (i, p) in sp.enumerated() where (beat + i) % 3 == 0 { s.set(p.0, p.1 + 2, "S") }

        case .idle:
            s.body()
            s.feet()
            s.eyes(.closed)
            s.set(7, 3, "S")
            let z = (beat / 3) % 3
            if z >= 0 { s.set(13, 3, "W") }
            if z >= 1 { s.set(14, 1, "W"); s.set(15, 1, "W") }
            s.dy = 1
        }
        return s
    }
}
