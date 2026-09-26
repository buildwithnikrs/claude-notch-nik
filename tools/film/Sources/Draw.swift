import AppKit
import CoreGraphics
import CoreText

// MARK: - Math

@inline(__always) func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
@inline(__always) func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
@inline(__always) func lerpP(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
    CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t))
}
/// Progress of `t` through [a, b], clamped to 0...1.
@inline(__always) func seg(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp01((t - a) / (b - a)) }

func easeOutCubic(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
func easeInCubic(_ t: Double) -> Double { t * t * t }
func easeInOutCubic(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
func easeOutBack(_ t: Double, _ s: Double = 1.4) -> Double {
    let c3 = s + 1
    return 1 + c3 * pow(t - 1, 3) + s * pow(t - 1, 2)
}
func easeOutExpo(_ t: Double) -> Double { t >= 1 ? 1 : 1 - pow(2, -10 * t) }

/// Fade in over [a, a+fi], hold, fade out over [b-fo, b].
func window(_ t: Double, _ a: Double, _ b: Double, fi: Double = 0.45, fo: Double = 0.35) -> Double {
    min(easeOutCubic(seg(t, a, a + fi)), 1 - easeInCubic(seg(t, b - fo, b)))
}

struct RNG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> Double {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17
        return Double(s % 1_000_000) / 1_000_000
    }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
}

// MARK: - Color

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func white(_ a: CGFloat) -> CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: a) }
func black(_ a: CGFloat) -> CGColor { CGColor(srgbRed: 0, green: 0, blue: 0, alpha: a) }

enum Pal {
    static let pink = rgb(0xF9A8D4)
    static let fuchsia = rgb(0xF0ABFC)
    static let lilac = rgb(0xD8B4FE)
    static let peri = rgb(0xA5B4FC)
    static let glow = rgb(0xF472B6)
    static let gradient = [pink, fuchsia, lilac, peri]
}

// MARK: - Painter (flipped: origin top-left, y down)

enum Align { case left, center, right }

final class Painter {
    let ctx: CGContext
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private var fontCache: [String: CTFont] = [:]

    init(_ ctx: CGContext) { self.ctx = ctx }

    func fill(_ r: CGRect, _ c: CGColor) {
        ctx.setFillColor(c)
        ctx.fill(r)
    }

    func round(_ r: CGRect, _ radius: CGFloat, _ c: CGColor) {
        ctx.setFillColor(c)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil))
        ctx.fillPath()
    }

    func roundStroke(_ r: CGRect, _ radius: CGFloat, _ c: CGColor, _ w: CGFloat = 1) {
        ctx.setStrokeColor(c)
        ctx.setLineWidth(w)
        let rr = r.insetBy(dx: w / 2, dy: w / 2)
        ctx.addPath(CGPath(roundedRect: rr, cornerWidth: min(radius, rr.width / 2), cornerHeight: min(radius, rr.height / 2), transform: nil))
        ctx.strokePath()
    }

    func gradient(_ colors: [CGColor], in path: CGPath, from: CGPoint, to: CGPoint) {
        guard let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil) else { return }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    func glowBlob(_ c: CGPoint, _ radius: CGFloat, _ color: CGColor, _ alpha: CGFloat) {
        guard alpha > 0.001, let comps = color.components else { return }
        let inner = CGColor(srgbRed: comps[0], green: comps[1], blue: comps[2], alpha: alpha)
        let outer = CGColor(srgbRed: comps[0], green: comps[1], blue: comps[2], alpha: 0)
        guard let g = CGGradient(colorsSpace: space, colors: [inner, outer] as CFArray, locations: [0, 1]) else { return }
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
    }

    // MARK: Text

    func font(_ size: CGFloat, _ weight: NSFont.Weight, mono: Bool = false) -> CTFont {
        let key = "\(size)-\(weight.rawValue)-\(mono)"
        if let f = fontCache[key] { return f }
        let f: NSFont = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                             : NSFont.systemFont(ofSize: size, weight: weight)
        fontCache[key] = f as CTFont
        return f as CTFont
    }

    func line(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: CGColor, kern: CGFloat = 0, mono: Bool = false) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font(size, weight, mono: mono),
            .foregroundColor: color,
            .kern: kern,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    }

    func width(_ l: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) }

    @discardableResult
    func text(_ s: String, _ x: CGFloat, _ baseline: CGFloat, _ size: CGFloat, _ weight: NSFont.Weight = .regular,
              _ color: CGColor = white(1), align: Align = .left, kern: CGFloat = 0, mono: Bool = false) -> CGFloat {
        let l = line(s, size, weight, color, kern: kern, mono: mono)
        let w = width(l)
        let x0 = align == .left ? x : (align == .center ? x - w / 2 : x - w)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x0, y: baseline)
        CTLineDraw(l, ctx)
        ctx.restoreGState()
        return w
    }

    /// Glyph outlines of a line, placed with its baseline at (x, baseline) in flipped coordinates.
    func outline(_ l: CTLine, _ x: CGFloat, _ baseline: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(l) as! [CTRun] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let font = attrs[kCTFontAttributeName as String] as! CTFont
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var pos = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
            for i in 0..<n {
                guard let g = CTFontCreatePathForGlyph(font, glyphs[i], nil) else { continue }
                let tr = CGAffineTransform(translationX: x + pos[i].x, y: baseline - pos[i].y).scaledBy(x: 1, y: -1)
                path.addPath(g, transform: tr)
            }
        }
        return path
    }

    /// Text filled with the brand gradient.
    @discardableResult
    func gradientText(_ s: String, _ x: CGFloat, _ baseline: CGFloat, _ size: CGFloat, _ weight: NSFont.Weight = .semibold,
                      align: Align = .left, kern: CGFloat = 0) -> CGFloat {
        // An empty clip path clips nothing, which would flood the frame with gradient.
        guard !s.isEmpty else { return 0 }
        let l = line(s, size, weight, white(1), kern: kern)
        let w = width(l)
        let x0 = align == .left ? x : (align == .center ? x - w / 2 : x - w)
        gradient(Pal.gradient, in: outline(l, x0, baseline), from: CGPoint(x: x0, y: 0), to: CGPoint(x: x0 + w, y: 0))
        return w
    }

    /// Mixed white + gradient text on one line, centered.
    func headline(_ plain: String, _ accent: String, cx: CGFloat, baseline: CGFloat, size: CGFloat, kern: CGFloat) {
        let a = width(line(plain, size, .semibold, white(1), kern: kern))
        let b = width(line(accent, size, .semibold, white(1), kern: kern))
        let x0 = cx - (a + b) / 2
        text(plain, x0, baseline, size, .semibold, white(1), kern: kern)
        gradientText(accent, x0 + a, baseline, size, .semibold, kern: kern)
    }
}
