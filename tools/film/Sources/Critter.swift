import CoreGraphics

/// Same 16×14 pixel critter as the app (apps/macos/Mascot.swift), drawn with CoreGraphics.
enum Mood: Int { case working, waiting, celebrate, idle, happy }

struct SpriteFrame {
    var pixels: [(x: Int, y: Int, c: Character)] = []
    var dy = 0
}

enum CritterArt {
    static let bodyRows: [CGColor] = (0..<14).map { y in
        let t = min(max(Double(y - 3) / 8, 0), 1)
        let a = (0.976, 0.659, 0.831), b = (0.647, 0.706, 0.988)
        return CGColor(srgbRed: lerp(a.0, b.0, t), green: lerp(a.1, b.1, t), blue: lerp(a.2, b.2, t), alpha: 1)
    }
    static let palette: [Character: CGColor] = [
        "o": rgb(0x8C80DB), "E": rgb(0x1A0F24), "S": rgb(0xFFFFFF), "L": rgb(0x333338), "l": rgb(0x616166),
        "G": rgb(0xF472B6), "W": white(0.85), "P": rgb(0xF472B6, 0.75), "A": rgb(0xF472B6),
    ]

    private static var cache: [Int: SpriteFrame] = [:]

    static func frame(_ mood: Mood, _ beat: Int) -> SpriteFrame {
        let b = ((beat % 24) + 24) % 24
        let key = mood.rawValue * 100 + b
        if let f = cache[key] { return f }
        let f = build(mood, b)
        cache[key] = f
        return f
    }

    private static func build(_ mood: Mood, _ beat: Int) -> SpriteFrame {
        var grid = [[Character]](repeating: [Character](repeating: ".", count: 16), count: 14)
        var dy = 0
        func set(_ x: Int, _ y: Int, _ c: Character) { if x >= 0, x < 16, y >= 0, y < 14 { grid[y][x] = c } }
        func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: Character) {
            for y in y0...y1 { for x in x0...x1 { set(x, y, c) } }
        }
        func body() { fill(4, 4, 11, 4, "O"); fill(3, 5, 12, 9, "O"); fill(4, 10, 11, 10, "O") }
        func feet() { for x in [4, 6, 9, 11] { set(x, 11, "o") } }
        func spark(_ tw: Bool) {
            if tw { for p in [(6, 1), (8, 1), (7, 2), (6, 3), (8, 3)] { set(p.0, p.1, "S") } }
            else { set(7, 1, "S"); fill(6, 2, 8, 2, "S"); set(7, 3, "S") }
        }
        func happyEyes() { for p in [(4, 7), (5, 6), (6, 7), (9, 7), (10, 6), (11, 7)] { set(p.0, p.1, "E") } }
        let blink = beat % 23 == 0

        switch mood {
        case .working:
            spark(false); body()
            if blink { set(5, 7, "E"); set(10, 7, "E") } else { fill(5, 7, 5, 8, "E"); fill(10, 7, 10, 8, "E") }
            fill(3, 8, 12, 11, "L"); set(7, 9, "G"); set(8, 9, "G"); fill(2, 12, 13, 12, "l")
            let left = beat % 2 == 0
            set(2, left ? 10 : 11, "O"); set(13, left ? 11 : 10, "O")
        case .waiting:
            spark((beat / 3) % 2 == 0); body(); feet()
            if blink { set(5, 7, "E"); set(10, 7, "E") } else { fill(5, 6, 5, 7, "E"); fill(10, 6, 10, 7, "E") }
            set(2, 8, "O")
            if beat % 2 == 0 { set(13, 8, "O"); set(14, 7, "O") } else { set(13, 7, "O"); set(14, 6, "O") }
            if (beat / 2) % 3 != 2 { fill(15, 1, 15, 3, "A"); set(15, 5, "A") }
            dy = beat % 4 < 2 ? 0 : -1
        case .happy:
            spark(true); body(); feet(); happyEyes(); set(4, 8, "P"); set(11, 8, "P")
            set(2, 8, "O"); set(13, 7, "O"); set(14, 6, "O"); set(14, 5, "O")
            dy = beat % 3 == 0 ? -1 : 0
        case .celebrate:
            let air = beat % 4
            spark(beat % 2 == 0); body(); happyEyes(); set(4, 8, "P"); set(11, 8, "P")
            if air == 1 || air == 2 {
                set(2, 5, "O"); set(1, 4, "O"); set(13, 5, "O"); set(14, 4, "O")
                dy = air == 1 ? -1 : -2
            } else { feet(); set(2, 8, "O"); set(13, 8, "O") }
        case .idle:
            body(); feet(); fill(4, 7, 6, 7, "E"); fill(9, 7, 11, 7, "E"); set(7, 3, "S")
            if (beat / 3) % 2 == 0 { set(13, 3, "W") } else { set(14, 1, "W") }
            dy = 1
        }
        var f = SpriteFrame()
        f.dy = dy
        for y in 0..<14 { for x in 0..<16 where grid[y][x] != "." { f.pixels.append((x, y, grid[y][x])) } }
        return f
    }

    /// Draws a critter centered at `c`. `px` is the size of one sprite pixel.
    static func draw(_ p: Painter, _ c: CGPoint, px: CGFloat, mood: Mood, beat: Int, alpha: CGFloat = 1) {
        guard alpha > 0.01, px > 0.2 else { return }
        let f = frame(mood, beat)
        let ox = c.x - 8 * px, oy = c.y - 7 * px + CGFloat(f.dy) * px
        let ctx = p.ctx
        ctx.saveGState()
        ctx.setAlpha(alpha)
        // Batch by color to keep hundreds of critters per frame cheap.
        var byColor: [Int: [CGRect]] = [:]
        var colors: [Int: CGColor] = [:]
        for (x, y, ch) in f.pixels {
            let key: Int
            let color: CGColor
            if ch == "O" { key = 1000 + y; color = bodyRows[y] } else { key = Int(ch.asciiValue ?? 0); color = palette[ch] ?? white(1) }
            byColor[key, default: []].append(CGRect(x: ox + CGFloat(x) * px, y: oy + CGFloat(y) * px, width: px + 0.3, height: px + 0.3))
            colors[key] = color
        }
        for (k, rects) in byColor {
            ctx.setFillColor(colors[k]!)
            ctx.fill(rects)
        }
        ctx.restoreGState()
    }
}
