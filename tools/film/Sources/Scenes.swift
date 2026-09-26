import AppKit
import CoreGraphics

let W: CGFloat = 1920
let H: CGFloat = 1080
let BEAT = 0.5              // 120 BPM
let DURATION = 53.0
let S: CGFloat = 1.9        // notch UI scale
let notchCenter = CGPoint(x: 960, y: 0)

// MARK: - Timeline (seconds)
//  0–4   one critter          4–10 swarm pours in     10–16 tasks, some need you
// 16–20  merge into the notch 20–26 multitasking desk  26–33 question answered
// 33–38  sessions             38–42 usage             42–46 done + confetti
// 46–53  end card

// MARK: - Swarm model

struct Swarmer {
    var slot: CGPoint
    var start: CGPoint
    var enter: Double
    var task: String?
    var labelAt: Double = 0
    var alert = false
    var alertAt: Double = 0
    var mergeAt: Double = 0
    var spin: Double = 1
    var phase: Int = 0
}

let tasks = [
    "Writing tests", "Refactoring auth", "Fixing flaky CI", "Migrating the DB", "Updating docs", "Reviewing a PR",
    "Adding dark mode", "Optimizing images", "Bumping deps", "Writing a changelog", "Fixing a race", "Tuning queries",
    "Porting to Swift 6", "Adding i18n", "Cleaning up CSS", "Profiling startup", "Drafting an RFC", "Adding telemetry opt-out",
    "Fixing a11y labels", "Splitting a monolith", "Writing a migration", "Caching API calls", "Hardening input", "Renaming a module",
    "Designing a schema", "Setting up CI", "Triaging issues", "Adding retries", "Writing E2E tests", "Fixing a memory leak",
    "Pairing on onboarding", "Shaving 40 ms", "Upgrading React", "Rewriting a parser", "Adding pagination", "Documenting APIs",
]

let swarm: [Swarmer] = {
    var rng = RNG(42)
    let cell: CGFloat = 66, cols = 28, rows = 15
    let ox = (W - CGFloat(cols) * cell) / 2 + cell / 2
    let oy = (H - CGFloat(rows) * cell) / 2 + cell / 2
    let hole = CGRect(x: 960 - 600, y: 540 - 150, width: 1200, height: 300)
    var slots: [CGPoint] = []
    for r in 0..<rows { for c in 0..<cols {
        let p = CGPoint(x: ox + CGFloat(c) * cell, y: oy + CGFloat(r) * cell)
        if !hole.contains(p) { slots.append(p) }
    } }
    // Enter in 22 eighth-note waves, random order.
    var order = Array(slots.indices)
    for i in stride(from: order.count - 1, to: 0, by: -1) { order.swapAt(i, Int(rng.next() * Double(i + 1))) }
    var out: [Swarmer] = []
    for (n, idx) in order.enumerated() {
        let s = slots[idx]
        let dir = CGPoint(x: s.x - 960, y: s.y - 540)
        let len = max(1, hypot(dir.x, dir.y))
        let start = CGPoint(x: s.x + dir.x / len * 1500 + rng.range(-200, 200), y: s.y + dir.y / len * 1500 + rng.range(-200, 200))
        let wave = n * 22 / order.count
        var m = Swarmer(slot: s, start: start, enter: 4.0 + Double(wave) * 0.25 + rng.range(0, 0.06))
        let d = hypot(s.x - notchCenter.x, s.y - notchCenter.y) / hypot(W, H)
        m.mergeAt = 16.0 + Double(d) * 1.1 + rng.range(0, 0.25)
        m.spin = rng.next() > 0.5 ? 1 : -1
        m.phase = Int(rng.next() * 24)
        out.append(m)
    }
    // Labels: a readable subset away from the text hole. Alerts: a few near it.
    var labelIdx = out.indices.filter { abs(out[$0].slot.y - 540) > 170 && out[$0].slot.y > 90 && out[$0].slot.y < 1000 }
    for i in stride(from: labelIdx.count - 1, to: 0, by: -1) { labelIdx.swapAt(i, Int(rng.next() * Double(i + 1))) }
    for (k, i) in labelIdx.prefix(34).enumerated() {
        out[i].task = tasks[k % tasks.count]
        out[i].labelAt = 10.0 + Double(k) * 0.085
    }
    let near = out.indices.filter { out[$0].task == nil && abs(out[$0].slot.y - 540) < 230 && abs(out[$0].slot.x - 960) < 760 }
    for (j, i) in near.enumerated() where j % max(1, near.count / 6) == 0 && out.filter({ $0.alert }).count < 6 {
        out[i].alert = true
        out[i].alertAt = 13.0 + Double(out.filter { $0.alert }.count) * 0.5
    }
    return out
}()

func swarmZoom(_ t: Double) -> CGFloat { CGFloat(1 + 0.16 * easeInOutCubic(seg(t, 10, 16))) }

func camera(_ p: CGPoint, _ z: CGFloat) -> CGPoint {
    CGPoint(x: 960 + (p.x - 960) * z, y: 560 + (p.y - 540) * z)
}

// MARK: - Render

func render(_ p: Painter, _ t: Double) {
    let ctx = p.ctx
    p.fill(CGRect(x: 0, y: 0, width: W, height: H), black(1))
    let beat = Int(t / (BEAT / 2))  // animation beat: 8th notes

    // Desktop (20–46), fading in during the merge.
    let deskA = easeInOutCubic(seg(t, 17.2, 19.4)) * (1 - easeInOutCubic(seg(t, 45.8, 47.0)))
    if deskA > 0 { drawDesktop(p, t, CGFloat(deskA)) }

    // Swarm scenes (0–19.5).
    if t < 19.6 { drawSwarm(p, t, beat) }

    // Notch + UI (16.3–47).
    if t > 16.2 && t < 47.2 { drawNotch(p, t, beat, alpha: CGFloat(1 - seg(t, 46.4, 47.1))) }

    // Captions.
    drawTitles(p, t)

    // End card.
    if t > 46.0 { drawEndCard(p, t, beat) }

    // Global fades.
    let fadeIn = 1 - seg(t, 0, 0.8), fadeOut = seg(t, 52.2, 53.0)
    let f = max(fadeIn, fadeOut)
    if f > 0 { p.fill(CGRect(x: 0, y: 0, width: W, height: H), black(CGFloat(f))) }
    _ = ctx
}

// MARK: Swarm

func drawSwarm(_ p: Painter, _ t: Double, _ beat: Int) {
    // Soft center glow that breathes with the beat.
    let pulse = t > 4 && t < 16 ? CGFloat(max(0, 1 - (t.truncatingRemainder(dividingBy: BEAT)) * 4)) : 0
    p.glowBlob(CGPoint(x: 960, y: 560), 900, Pal.lilac, 0.07 + 0.04 * pulse)
    p.glowBlob(CGPoint(x: 700, y: 620), 700, Pal.pink, 0.05)

    // 0–4: the first critter, alone.
    if t < 4.6 {
        let a = CGFloat(easeOutCubic(seg(t, 0.4, 1.4)) * (1 - seg(t, 4.0, 4.4)))
        let mood: Mood = t < 2.0 ? .idle : .waiting
        let pop = t > 2.0 ? CGFloat(easeOutBack(seg(t, 2.0, 2.4)) * 0.1 + 0.9) : 0.9
        CritterArt.draw(p, CGPoint(x: 960, y: 470), px: 10 * pop, mood: mood, beat: beat, alpha: a)
    }

    let z = swarmZoom(t)
    let bounce = t > 4 && t < 16 ? CGFloat(max(0, 1 - t.truncatingRemainder(dividingBy: BEAT) * 5)) * 3 : 0
    var labels: [(CGPoint, String, CGFloat, Bool)] = []

    for (i, m) in swarm.enumerated() {
        guard t >= m.enter else { continue }
        let pEnter = easeOutBack(seg(t, m.enter, m.enter + 0.75), 1.1)
        let start = i == 0 ? CGPoint(x: 960, y: 470) : m.start
        var pos = lerpP(start, m.slot, pEnter)
        var px: CGFloat = 2.6
        if i == 0 { px = CGFloat(lerp(10, 2.6, easeOutCubic(seg(t, 4.0, 4.6)))) }
        pos = camera(pos, z)
        pos.y -= bounce
        var alpha: CGFloat = 1
        let mood: Mood = m.alert && t >= m.alertAt ? .waiting : .working

        // 16–19: spiral into the notch.
        if t >= m.mergeAt {
            let q = easeInCubic(seg(t, m.mergeAt, m.mergeAt + 1.35))
            let target = CGPoint(x: 960, y: 26)
            let v = CGPoint(x: pos.x - target.x, y: pos.y - target.y)
            let r = hypot(v.x, v.y) * CGFloat(1 - q)
            let ang = atan2(v.y, v.x) + CGFloat(q * 1.9 * m.spin)
            pos = CGPoint(x: target.x + cos(ang) * r, y: target.y + sin(ang) * r)
            px *= CGFloat(1 - q * 0.8)
            alpha = CGFloat(1 - seg(q, 0.82, 1))
            if q >= 1 { continue }
        }

        if m.alert && t >= m.alertAt && t < m.mergeAt {
            let g = CGFloat(0.35 + 0.25 * sin(t * 6))
            p.glowBlob(pos, 60, Pal.glow, g)
        }
        CritterArt.draw(p, pos, px: px * z, mood: mood, beat: beat + m.phase, alpha: alpha)

        if t < m.mergeAt, t >= m.labelAt, let task = m.task {
            let a = CGFloat(easeOutCubic(seg(t, m.labelAt, m.labelAt + 0.3)))
            labels.append((pos, task, a, false))
        }
        if m.alert, t >= m.alertAt, t < m.mergeAt {
            labels.append((pos, "Needs you", CGFloat(easeOutBack(seg(t, m.alertAt, m.alertAt + 0.3))), true))
        }
    }
    // Labels on top.
    for (pos, text, a, alert) in labels {
        let size: CGFloat = 15
        let w = p.width(p.line(text, size, .semibold, white(1))) + 22
        let r = CGRect(x: pos.x - w / 2, y: pos.y - 58, width: w, height: 28)
        p.ctx.saveGState()
        p.ctx.setAlpha(a)
        if alert {
            p.ctx.setShadow(offset: .zero, blur: 18, color: rgb(0xF472B6, 0.9))
            p.round(r, 14, rgb(0x2A0F22))
            p.ctx.setShadow(offset: .zero, blur: 0, color: nil)
            p.roundStroke(r, 14, rgb(0xF472B6, 0.8), 1.2)
            p.text(text, pos.x, r.minY + 19, size, .semibold, Pal.pink, align: .center)
        } else {
            p.round(r, 14, rgb(0x16141B, 0.92))
            p.roundStroke(r, 14, white(0.12))
            p.text(text, pos.x, r.minY + 19, size, .medium, white(0.85), align: .center)
        }
        p.ctx.restoreGState()
    }
}

// MARK: Desktop

func drawDesktop(_ p: Painter, _ t: Double, _ a: CGFloat) {
    let ctx = p.ctx
    ctx.saveGState()
    ctx.setAlpha(a)
    let bg = CGPath(rect: CGRect(x: 0, y: 0, width: W, height: H), transform: nil)
    p.gradient([rgb(0x100D16), rgb(0x07060A)], in: bg, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: H))
    let d = CGFloat(t * 6)
    p.glowBlob(CGPoint(x: 420 + d, y: 860), 760, Pal.lilac, 0.16)
    p.glowBlob(CGPoint(x: 1560 - d, y: 260), 700, Pal.pink, 0.13)
    p.glowBlob(CGPoint(x: 1150, y: 980 - d), 620, Pal.peri, 0.11)

    // Menu bar (same height as the notch).
    let mb = 32 * S
    p.fill(CGRect(x: 0, y: 0, width: W, height: mb), white(0.035))
    var x: CGFloat = 36
    p.round(CGRect(x: x, y: mb / 2 - 9, width: 18, height: 18), 9, white(0.8)); x += 42
    for (i, item) in ["Canvas", "File", "Edit", "View", "Object", "Window"].enumerated() {
        x += p.text(item, x, mb / 2 + 8, 21, i == 0 ? .semibold : .regular, white(0.82)) + 30
    }
    p.text("Fri 4:12 PM", W - 36, mb / 2 + 8, 21, .regular, white(0.82), align: .right)
    p.text("100%", W - 210, mb / 2 + 8, 21, .regular, white(0.6), align: .right)

    // Design app window (you, doing something else).
    let win = CGRect(x: 130, y: 150, width: 1170, height: 740)
    ctx.setShadow(offset: CGSize(width: 0, height: 20), blur: 60, color: black(0.6))
    p.round(win, 18, rgb(0x16141C))
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    p.roundStroke(win, 18, white(0.08))
    for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        p.round(CGRect(x: win.minX + 22 + CGFloat(i) * 24, y: win.minY + 18, width: 14, height: 14), 7, rgb(UInt32(c), 0.55))
    }
    p.text("Launch — Canvas", win.midX, win.minY + 31, 17, .semibold, white(0.55), align: .center)
    p.fill(CGRect(x: win.minX, y: win.minY + 50, width: win.width, height: 1), white(0.06))
    // Layers sidebar
    for i in 0..<9 {
        p.round(CGRect(x: win.minX + 22, y: win.minY + 76 + CGFloat(i) * 38, width: CGFloat(120 + (i * 37) % 60), height: 14), 7, white(i == 3 ? 0.22 : 0.08))
    }
    p.fill(CGRect(x: win.minX + 210, y: win.minY + 50, width: 1, height: win.height - 50), white(0.06))
    // Artboards
    let ab1 = CGRect(x: win.minX + 290, y: win.minY + 110, width: 300, height: 560)
    let ab2 = CGRect(x: win.minX + 660, y: win.minY + 110, width: 300, height: 560)
    for ab in [ab1, ab2] {
        p.round(ab, 30, rgb(0x0E0C12))
        p.roundStroke(ab, 30, white(0.1))
        p.round(CGRect(x: ab.minX + 28, y: ab.minY + 60, width: 170, height: 22), 11, white(0.2))
        p.round(CGRect(x: ab.minX + 28, y: ab.minY + 96, width: 230, height: 14), 7, white(0.08))
        p.round(CGRect(x: ab.minX + 28, y: ab.minY + 120, width: 200, height: 14), 7, white(0.08))
        p.round(CGRect(x: ab.minX + 28, y: ab.minY + 470, width: 244, height: 50), 25, white(0.85))
    }
    let hero1 = CGPath(roundedRect: CGRect(x: ab1.minX + 28, y: ab1.minY + 160, width: 244, height: 250), cornerWidth: 22, cornerHeight: 22, transform: nil)
    p.gradient([rgb(0xF9A8D4, 0.55), rgb(0xA5B4FC, 0.45)], in: hero1, from: CGPoint(x: ab1.minX, y: ab1.minY + 160), to: CGPoint(x: ab1.maxX, y: ab1.minY + 410))
    // The shape you're dragging.
    let drag = dragShapeRect(t)
    let dragPath = CGPath(roundedRect: drag, cornerWidth: 22, cornerHeight: 22, transform: nil)
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: black(0.5))
    p.gradient([rgb(0xD8B4FE, 0.9), rgb(0xA5B4FC, 0.9)], in: dragPath, from: drag.origin, to: CGPoint(x: drag.maxX, y: drag.maxY))
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    if t > 21.1 && t < 23.4 { p.roundStroke(drag.insetBy(dx: -4, dy: -4), 24, rgb(0xA5B4FC), 2) }

    // Terminal windows: five Claudes working.
    let names = ["checkout", "api", "infra"]
    let lines = [
        ["✻ Refactoring payment flow", "  Editing CheckoutView.swift", "  Editing PaymentSheet.swift", "✻ Using SQLite", "  Writing migrations/001.sql", "  Running tests… 48 passed"],
        ["✻ Running the test suite", "  ✓ auth  ✓ billing  ✓ users", "  ✓ search  ✓ export", "  Fixing flaky retry test", "  Editing RetryPolicy.ts", "  Re-running…"],
        ["✻ Updating deploy config", "  Editing deploy.yaml", "  Checking health probes", "  Bumping node to 22", "  Editing Dockerfile", "  Validating…"],
    ]
    for (i, n) in names.enumerated() {
        let r = CGRect(x: 1360, y: 170 + CGFloat(i) * 235, width: 460, height: 300)
        ctx.setShadow(offset: CGSize(width: 0, height: 16), blur: 40, color: black(0.6))
        p.round(r, 16, rgb(0x121015, 0.97))
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        p.roundStroke(r, 16, white(0.08))
        for k in 0..<3 { p.round(CGRect(x: r.minX + 18 + CGFloat(k) * 20, y: r.minY + 16, width: 12, height: 12), 6, white(0.18)) }
        p.text("\(n) — claude", r.midX, r.minY + 27, 15, .semibold, white(0.45), align: .center)
        let shown = min(lines[i].count, Int((t - 19.5) / 1.6) + 2 + i)
        for (k, l) in lines[i].prefix(max(0, shown)).enumerated() {
            p.text(l, r.minX + 22, r.minY + 72 + CGFloat(k) * 30, 16, .regular, l.hasPrefix("✻") ? rgb(0xD8B4FE, 0.9) : white(0.5), mono: true)
        }
    }

    // Dock
    let dock = CGRect(x: 960 - 330, y: H - 96, width: 660, height: 82)
    p.round(dock, 26, white(0.07))
    p.roundStroke(dock, 26, white(0.1))
    let icons: [UInt32] = [0xA5B4FC, 0xF9A8D4, 0xD8B4FE, 0x86EFAC, 0xFDE68A, 0x93C5FD, 0xF0ABFC, 0xFCA5A5]
    for (i, c) in icons.enumerated() {
        p.round(CGRect(x: dock.minX + 24 + CGFloat(i) * 78, y: dock.minY + 12, width: 58, height: 58), 14, rgb(c, 0.55))
    }
    ctx.restoreGState()

    // Dim the desk while the notch is open, so the eye goes up.
    let open = notchOpenness(t)
    if open > 0 { p.fill(CGRect(x: 0, y: 32 * S, width: W, height: H), black(0.42 * CGFloat(open) * a)) }
}

func dragShapeRect(_ t: Double) -> CGRect {
    let c = cursorPosition(t)
    let from = CGPoint(x: 560, y: 740), to = CGPoint(x: 830, y: 820)
    var center = from
    if t >= 21.2 && t < 23.2 { center = CGPoint(x: c.x - 20, y: c.y + 30) } else if t >= 23.2 { center = to }
    _ = to
    return CGRect(x: center.x - 70, y: center.y - 50, width: 140, height: 100)
}

// MARK: Cursor

struct CursorKey { let t: Double; let p: CGPoint }
let cursorKeys: [CursorKey] = [
    CursorKey(t: 19.8, p: CGPoint(x: 760, y: 900)),
    CursorKey(t: 20.9, p: CGPoint(x: 580, y: 710)),
    CursorKey(t: 21.2, p: CGPoint(x: 580, y: 710)),
    CursorKey(t: 23.2, p: CGPoint(x: 850, y: 790)),
    CursorKey(t: 24.4, p: CGPoint(x: 980, y: 700)),
    CursorKey(t: 27.2, p: CGPoint(x: 990, y: 690)),
    CursorKey(t: 29.0, p: CGPoint(x: 1195, y: 250)),
    CursorKey(t: 31.4, p: CGPoint(x: 1195, y: 250)),
    CursorKey(t: 32.6, p: CGPoint(x: 1010, y: 36)),
    CursorKey(t: 33.2, p: CGPoint(x: 1010, y: 36)),
    CursorKey(t: 37.2, p: CGPoint(x: 1000, y: 380)),
    CursorKey(t: 37.7, p: CGPoint(x: 728, y: 104)),
    CursorKey(t: 41.4, p: CGPoint(x: 728, y: 104)),
    CursorKey(t: 42.6, p: CGPoint(x: 1150, y: 640)),
]
let clicks: [Double] = [21.15, 29.5, 32.85, 37.85]

func cursorPosition(_ t: Double) -> CGPoint {
    guard let first = cursorKeys.first else { return .zero }
    if t <= first.t { return first.p }
    for i in 1..<cursorKeys.count where t <= cursorKeys[i].t {
        let a = cursorKeys[i - 1], b = cursorKeys[i]
        return lerpP(a.p, b.p, easeInOutCubic(seg(t, a.t, b.t)))
    }
    return cursorKeys.last!.p
}

func drawCursor(_ p: Painter, _ t: Double) {
    let a = CGFloat(seg(t, 19.8, 20.3) * (1 - seg(t, 44.5, 45.2)))
    guard a > 0 else { return }
    let c = cursorPosition(t)
    let ctx = p.ctx
    var scale: CGFloat = 1.8
    for k in clicks where t >= k && t < k + 0.5 {
        let q = seg(t, k, k + 0.45)
        scale *= CGFloat(1 - 0.12 * sin(q * .pi))
        ctx.saveGState()
        ctx.setAlpha(CGFloat(1 - q) * a)
        ctx.setStrokeColor(white(0.8))
        ctx.setLineWidth(2)
        let r = CGFloat(10 + 34 * q)
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.restoreGState()
    }
    let pts: [CGPoint] = [(0, 0), (0, 17), (4.2, 13.2), (7, 19.6), (9.8, 18.4), (7.2, 12.2), (12.6, 12.2)].map { CGPoint(x: c.x + $0.0 * scale, y: c.y + $0.1 * scale) }
    ctx.saveGState()
    ctx.setAlpha(a)
    ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 8, color: black(0.5))
    ctx.addLines(between: pts)
    ctx.closePath()
    ctx.setFillColor(white(1))
    ctx.setStrokeColor(black(1))
    ctx.setLineWidth(1.6)
    ctx.drawPath(using: .fillStroke)
    ctx.restoreGState()
}

// MARK: Notch

enum NotchState { case plain, compact, peek, question, ack, sessions, usage, done }

let notchStates: [(Double, NotchState)] = [
    (16.3, .plain), (19.3, .compact), (23.6, .peek), (25.5, .compact), (26.2, .question), (30.1, .ack),
    (31.6, .compact), (33.1, .sessions), (37.9, .usage), (42.0, .done), (45.6, .plain),
]

func size(of s: NotchState) -> (w: Double, h: Double, r: Double) {
    switch s {
    case .plain: return (185, 32, 10)
    case .compact, .ack, .done: return (337, 32, 12)
    case .peek: return (337, 62, 16)
    case .question: return (520, 300, 24)
    case .sessions: return (520, 344, 24)
    case .usage: return (520, 318, 24)
    }
}

func notchStateAt(_ t: Double) -> (state: NotchState, start: Double, prev: NotchState) {
    var cur = notchStates[0], prev = notchStates[0]
    for s in notchStates where t >= s.0 { prev = cur; cur = s }
    return (cur.1, cur.0, prev.1)
}

func notchOpenness(_ t: Double) -> Double {
    let (s, start, prev) = notchStateAt(t)
    let open: (NotchState) -> Double = { [.question, .sessions, .usage].contains($0) ? 1 : 0 }
    return lerp(open(prev), open(s), easeOutCubic(seg(t, start, start + 0.4)))
}

func notchPath(_ w: CGFloat, _ h: CGFloat, _ br: CGFloat) -> CGPath {
    let x0 = 960 - w / 2, t: CGFloat = 8 * S, b = min(br, h / 2)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: x0, y: 0))
    path.addQuadCurve(to: CGPoint(x: x0 + t, y: t), control: CGPoint(x: x0 + t, y: 0))
    path.addLine(to: CGPoint(x: x0 + t, y: h - b))
    path.addQuadCurve(to: CGPoint(x: x0 + t + b, y: h), control: CGPoint(x: x0 + t, y: h))
    path.addLine(to: CGPoint(x: x0 + w - t - b, y: h))
    path.addQuadCurve(to: CGPoint(x: x0 + w - t, y: h - b), control: CGPoint(x: x0 + w - t, y: h))
    path.addLine(to: CGPoint(x: x0 + w - t, y: t))
    path.addQuadCurve(to: CGPoint(x: x0 + w, y: 0), control: CGPoint(x: x0 + w - t, y: 0))
    path.closeSubpath()
    return path
}

func drawNotch(_ p: Painter, _ t: Double, _ beat: Int, alpha: CGFloat) {
    let ctx = p.ctx
    let (state, start, prev) = notchStateAt(t)
    let a = size(of: prev), b = size(of: state)
    let k = easeOutBack(seg(t, start, start + 0.55), 1.15)
    let w = CGFloat(lerp(a.w, b.w, k)) * S, h = max(CGFloat(lerp(a.h, b.h, k)), 30) * S
    let r = CGFloat(lerp(a.r, b.r, clamp01(k))) * S
    let path = notchPath(w, h, r)

    ctx.saveGState()
    ctx.setAlpha(alpha)
    // Pink glow while Claude needs you.
    let glow = seg(t, 26.2, 26.7) * (1 - seg(t, 29.9, 30.3))
    if glow > 0 {
        let pulse = 0.65 + 0.35 * sin(t * 5)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 70, color: rgb(0xF472B6, CGFloat(glow * pulse)))
        ctx.addPath(path); ctx.setFillColor(black(1)); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 140, color: rgb(0xD8B4FE, CGFloat(glow * 0.5)))
        ctx.addPath(path); ctx.fillPath()
        ctx.restoreGState()
    } else if [.question, .sessions, .usage].contains(state) || [.question, .sessions, .usage].contains(prev) {
        ctx.setShadow(offset: CGSize(width: 0, height: 24), blur: 60, color: black(0.7))
    }
    ctx.addPath(path)
    ctx.setFillColor(black(1))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Content, clipped to the shape, in unscaled local coordinates.
    ctx.addPath(path)
    ctx.clip()
    ctx.translateBy(x: 960 - w / 2, y: 0)
    ctx.scaleBy(x: S, y: S)
    let lw = w / S
    let ca = CGFloat(easeOutCubic(seg(t, start + 0.1, start + 0.45)))
    ctx.setAlpha(alpha * ca)
    drawNotchContent(p, t, beat, state, start, lw)
    ctx.restoreGState()

    // Confetti from under the notch when a task finishes.
    if t > 42.1 && t < 45 { drawConfetti(p, t - 42.15) }
    drawCursor(p, t)
}

func timer(_ t: Double, base: Double, from: Double) -> String {
    let s = Int(base + max(0, t - from))
    return String(format: "%02d:%02d", s / 60, s % 60)
}

func drawNotchContent(_ p: Painter, _ t: Double, _ beat: Int, _ state: NotchState, _ start: Double, _ w: CGFloat) {
    if state == .plain { return }
    let mood: Mood = {
        switch state {
        case .question: return .waiting
        case .ack: return .happy
        case .done: return .celebrate
        default: return .working
        }
    }()
    CritterArt.draw(p, CGPoint(x: 30, y: 16), px: 1.75, mood: mood, beat: beat)
    let right = w - 14
    switch state {
    case .compact, .peek:
        let tw = p.text("×5", right, 21, 11, .semibold, white(0.45), align: .right)
        p.text(timer(t, base: 272, from: 19.3), right - tw - 5, 21, 13, .semibold, white(1), align: .right, mono: true)
    case .question:
        let tw = p.gradientText("Needs you", right, 21, 12.5, .semibold, align: .right)
        p.round(CGRect(x: right - tw - 13, y: 13, width: 7, height: 7), 3.5, Pal.glow)
    case .ack:
        p.text("Got it!", right, 21, 13, .semibold, Pal.peri, align: .right)
    case .done:
        p.text("✓ Done", right, 21, 13, .semibold, Pal.peri, align: .right)
    case .sessions, .usage:
        p.text("Claude", 52, 21, 13, .semibold, white(1))
        p.text("×5", right, 21, 11, .semibold, white(0.45), align: .right)
        p.text(timer(t, base: 272, from: 19.3), right - 20, 21, 13, .semibold, white(1), align: .right, mono: true)
    case .plain: break
    }

    switch state {
    case .peek:
        p.round(CGRect(x: 16, y: 41, width: 6, height: 6), 3, Pal.lilac)
        let nw = p.text("checkout", 28, 48, 11.5, .semibold, white(1))
        p.text("Editing CheckoutView.swift", 28 + nw + 6, 48, 11.5, .regular, white(0.6))
        p.text("+4", w - 16, 48, 11.5, .regular, white(0.35), align: .right)
    case .question: drawQuestion(p, t, w)
    case .sessions: drawTabs(p, active: 0); drawSessions(p, t, start, w)
    case .usage: drawTabs(p, active: 1); drawUsage(p, t, start, w)
    default: break
    }
}

func card(_ p: Painter, _ r: CGRect, hover: Bool = false) {
    p.round(r, 14, white(hover ? 0.11 : 0.07))
    p.roundStroke(r, 14, white(0.1))
}

func drawQuestion(_ p: Painter, _ t: Double, _ w: CGFloat) {
    p.round(CGRect(x: 18, y: 41, width: 6, height: 6), 3, Pal.glow)
    let nw = p.text("checkout", 30, 48, 11.5, .semibold, white(1))
    p.text("· Claude needs your input", 30 + nw + 5, 48, 11.5, .regular, white(0.6))
    p.gradientText("DATABASE", 18, 70, 9.5, .semibold, kern: 1.2)
    p.text("Which database should I use?", 18, 96, 17, .semibold, white(1), kern: -0.4)
    let opts = [("PostgreSQL", "Production-grade, runs in Docker"), ("SQLite", "Zero setup, single file"), ("Keep investigating", "Compare both first")]
    let cw = (w - 36 - 6) / 2
    for (i, o) in opts.enumerated() {
        let r = CGRect(x: 18 + CGFloat(i % 2) * (cw + 6), y: 110 + CGFloat(i / 2) * 56, width: cw, height: 50)
        let hover = i == 1 && t > 28.8
        let picked = i == 1 && t > 29.5
        if picked {
            p.round(r, 14, rgb(0xD8B4FE, 0.16))
            p.gradient(Pal.gradient, in: CGPath(roundedRect: r, cornerWidth: 14, cornerHeight: 14, transform: nil).copy(strokingWithWidth: 1.4, lineCap: .round, lineJoin: .round, miterLimit: 4), from: r.origin, to: CGPoint(x: r.maxX, y: r.minY))
        } else { card(p, r, hover: hover) }
        p.text(o.0, r.minX + 12, r.minY + 21, 13, .semibold, white(1))
        p.text(o.1, r.minX + 12, r.minY + 38, 10.5, .regular, white(0.6))
    }
    let f = CGRect(x: 18, y: 226, width: w - 36, height: 32)
    p.round(f, 10, white(0.07))
    p.text("Type your own answer…", 30, 246, 12.5, .regular, white(0.35))
    p.text("Answer in Terminal instead", 18, 284, 11, .regular, white(0.35))
    let later = CGRect(x: w - 18 - 64, y: 268, width: 64, height: 24)
    p.round(later, 12, white(0.08)); p.roundStroke(later, 12, white(0.1))
    p.text("Later", later.midX, later.minY + 16, 12, .semibold, white(1), align: .center)
}

func drawTabs(_ p: Painter, active: Int) {
    let tabs = ["Sessions", "Usage"]
    var x: CGFloat = 16
    for (i, name) in tabs.enumerated() {
        let tw = p.width(p.line(name, 11.5, .semibold, white(1))) + 22
        let r = CGRect(x: x, y: 40, width: tw, height: 24)
        if i == active { p.round(r, 12, white(0.12)); p.roundStroke(r, 12, white(0.1)) }
        p.text(name, r.midX, r.minY + 16, 11.5, .semibold, i == active ? white(1) : white(0.6), align: .center)
        x += tw + 4
    }
}

func drawSessions(_ p: Painter, _ t: Double, _ start: Double, _ w: CGFloat) {
    let rows: [(String, String, String, CGColor, Double?)] = [
        ("marketing-site", "Claude app", "Needs you · Pick a hero headline", Pal.glow, nil),
        ("checkout", "Terminal", "Working · 05:12 · Writing migrations", Pal.lilac, 34),
        ("api", "Terminal", "Working · 12:41 · Run the test suite", Pal.lilac, 61),
        ("infra", "Terminal", "Working · 02:03 · Editing deploy.yaml", Pal.lilac, 18),
        ("docs", "VS Code", "Done · took 06:20", Pal.peri, nil),
    ]
    for (i, row) in rows.enumerated() {
        let ra = CGFloat(easeOutCubic(seg(t, start + 0.15 + Double(i) * 0.08, start + 0.5 + Double(i) * 0.08)))
        let r = CGRect(x: 16, y: 74 + CGFloat(i) * 52 + (1 - ra) * 10, width: w - 32, height: 46)
        p.ctx.saveGState()
        p.ctx.setAlpha(ra)
        card(p, r)
        if i == 0 { p.glowBlob(CGPoint(x: r.minX + 18, y: r.midY), 14, Pal.glow, 0.6) }
        p.round(CGRect(x: r.minX + 14, y: r.midY - 4, width: 8, height: 8), 4, row.3)
        let nw = p.text(row.0, r.minX + 32, r.minY + 19, 13, .semibold, white(1))
        let bw = p.width(p.line(row.1, 9.5, .semibold, white(1))) + 10
        let badge = CGRect(x: r.minX + 32 + nw + 6, y: r.minY + 8, width: bw, height: 15)
        p.round(badge, 7.5, white(0.08))
        p.text(row.1, badge.midX, badge.minY + 11, 9.5, .semibold, white(0.35), align: .center)
        p.text(row.2, r.minX + 32, r.minY + 36, 11, .regular, i == 0 ? Pal.pink : white(0.6))
        if let v = row.4 {
            p.text("\(Int(v))%", r.maxX - 14, r.minY + 20, 9.5, .semibold, white(0.35), align: .right)
            meter(p, CGRect(x: r.maxX - 48, y: r.minY + 27, width: 34, height: 3), v)
        }
        p.ctx.restoreGState()
    }
}

func meter(_ p: Painter, _ r: CGRect, _ v: Double) {
    p.round(r, r.height / 2, white(0.1))
    let fw = max(r.height, r.width * CGFloat(v / 100))
    let fill = CGRect(x: r.minX, y: r.minY, width: fw, height: r.height)
    p.gradient(Pal.gradient, in: CGPath(roundedRect: fill, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil),
               from: r.origin, to: CGPoint(x: r.maxX, y: r.minY))
}

func drawUsage(_ p: Painter, _ t: Double, _ start: Double, _ w: CGFloat) {
    let rows: [(String, String, Double, String)] = [
        ("Current session", "5-hour window", 42, "Resets in 2h 14m"),
        ("Weekly", "7-day window", 18, "Resets Tuesday"),
        ("Context", "checkout", 61, "Verified by Claude Code"),
    ]
    for (i, row) in rows.enumerated() {
        let r = CGRect(x: 16, y: 74 + CGFloat(i) * 78, width: w - 32, height: 70)
        card(p, r)
        let fill = easeOutCubic(seg(t, start + 0.3 + Double(i) * 0.5, start + 1.4 + Double(i) * 0.5))
        let tw = p.text(row.0, r.minX + 14, r.minY + 24, 13, .semibold, white(1))
        p.text(row.1, r.minX + 14 + tw + 6, r.minY + 24, 11, .regular, white(0.35))
        p.text("\(Int((row.2 * fill).rounded()))%", r.maxX - 14, r.minY + 24, 14, .bold, white(1), align: .right, mono: true)
        meter(p, CGRect(x: r.minX + 14, y: r.minY + 34, width: r.width - 28, height: 6), row.2 * fill)
        p.text(row.3, r.minX + 14, r.minY + 60, 10.5, .regular, white(0.6))
    }
}

func drawConfetti(_ p: Painter, _ dt: Double) {
    var rng = RNG(7)
    let colors = Pal.gradient + [white(1)]
    let origin = CGPoint(x: 960, y: 32 * S)
    let ctx = p.ctx
    for i in 0..<110 {
        let ang = Double.pi * (0.08 + 0.84 * rng.next())
        let speed = rng.range(380, 1100)
        let spin = rng.range(-10, 10)
        let x = origin.x + CGFloat(cos(ang) * speed * dt)
        let y = origin.y + CGFloat(sin(ang) * speed * dt * 0.55 + 700 * dt * dt)
        let a = CGFloat(max(0, 1 - dt / 2.6))
        ctx.saveGState()
        ctx.setAlpha(a)
        ctx.translateBy(x: x, y: y)
        ctx.rotate(by: CGFloat(spin * dt))
        let wv: CGFloat = i % 3 == 0 ? 7 : 12
        p.fill(CGRect(x: -wv / 2, y: -3, width: wv, height: 6), colors[i % colors.count])
        ctx.restoreGState()
    }
}

// MARK: Titles

struct Title { let a: Double; let b: Double; let plain: String; let accent: String; let size: CGFloat; let y: CGFloat }

let titles: [Title] = [
    Title(a: 1.0, b: 3.8, plain: "This is Claude.", accent: "", size: 64, y: 640),
    Title(a: 5.3, b: 9.7, plain: "Now there are ", accent: "hundreds.", size: 80, y: 565),
    Title(a: 10.2, b: 12.9, plain: "Each one on a task.", accent: "", size: 80, y: 565),
    Title(a: 13.2, b: 15.9, plain: "One of them ", accent: "needs you.", size: 80, y: 565),
    Title(a: 19.4, b: 21.0, plain: "All of them. ", accent: "One notch.", size: 84, y: 560),
    Title(a: 21.5, b: 25.8, plain: "Go do ", accent: "something else.", size: 60, y: 985),
    Title(a: 26.4, b: 29.4, plain: "The notch ", accent: "taps you.", size: 60, y: 985),
    Title(a: 29.6, b: 32.9, plain: "Answer in a click. ", accent: "Stay where you are.", size: 60, y: 985),
    Title(a: 33.4, b: 37.7, plain: "Every session. ", accent: "One glance.", size: 60, y: 985),
    Title(a: 38.2, b: 41.8, plain: "Know what's ", accent: "left.", size: 60, y: 985),
    Title(a: 42.4, b: 45.8, plain: "Done? ", accent: "You'll know.", size: 60, y: 985),
]

func drawTitles(_ p: Painter, _ t: Double) {
    // Legibility band behind lower-third captions.
    let band = seg(t, 20.8, 21.4) * (1 - seg(t, 45.6, 46.2))
    if band > 0 {
        p.gradient([black(0), black(CGFloat(0.85 * band))], in: CGPath(rect: CGRect(x: 0, y: 760, width: W, height: 320), transform: nil),
                   from: CGPoint(x: 0, y: 760), to: CGPoint(x: 0, y: 1000))
    }
    for tt in titles where t > tt.a - 0.1 && t < tt.b {
        let a = window(t, tt.a, tt.b, fi: 0.55, fo: 0.4)
        let rise = CGFloat(1 - easeOutCubic(seg(t, tt.a, tt.a + 0.7))) * 26
        p.ctx.saveGState()
        p.ctx.setAlpha(CGFloat(a))
        if tt.y == 565 || tt.y == 560 {
            // Center statements get a dark halo so the swarm never fights the words.
            p.glowBlob(CGPoint(x: 960, y: tt.y - tt.size * 0.3), 640, black(1), 0.9)
        }
        p.headline(tt.plain, tt.accent, cx: 960, baseline: tt.y + rise, size: tt.size, kern: -tt.size * 0.035)
        p.ctx.restoreGState()
    }
}

// MARK: End card

func drawEndCard(_ p: Painter, _ t: Double, _ beat: Int) {
    p.glowBlob(CGPoint(x: 960, y: 560), 800, Pal.lilac, CGFloat(0.12 * seg(t, 46.4, 48)))
    p.glowBlob(CGPoint(x: 820, y: 620), 600, Pal.pink, CGFloat(0.08 * seg(t, 46.4, 48)))

    // The hundreds come back, orbiting.
    let orbitA = seg(t, 48.6, 50.0)
    if orbitA > 0 {
        for i in 0..<140 {
            let ph = Double(i) / 140 * 2 * .pi + t * 0.18 * (i % 2 == 0 ? 1 : -1)
            let rx = 760.0 + Double(i % 5) * 26, ry = 400.0 + Double(i % 7) * 16
            let pos = CGPoint(x: 960 + cos(ph) * rx, y: 540 + sin(ph) * ry)
            CritterArt.draw(p, pos, px: 1.8, mood: .working, beat: beat + i, alpha: CGFloat(orbitA * 0.55))
        }
    }

    let pop = easeOutBack(seg(t, 46.6, 47.2), 1.6)
    CritterArt.draw(p, CGPoint(x: 960, y: 395), px: CGFloat(11 * pop), mood: t < 48.4 ? .celebrate : .waiting, beat: beat,
                    alpha: CGFloat(seg(t, 46.6, 46.8)))

    let a1 = easeOutCubic(seg(t, 47.2, 47.9)), a2 = easeOutCubic(seg(t, 48.0, 48.6)), a3 = easeOutCubic(seg(t, 48.8, 49.4))
    p.ctx.saveGState()
    p.ctx.setAlpha(CGFloat(a1))
    p.gradientText("Claude Notch", 960, 620 + CGFloat(1 - a1) * 24, 132, .semibold, align: .center, kern: -5)
    p.ctx.setAlpha(CGFloat(a2))
    p.text("Many Claudes. One notch.", 960, 700 + CGFloat(1 - a2) * 16, 40, .medium, white(0.85), align: .center, kern: -0.8)
    p.ctx.setAlpha(CGFloat(a3))
    p.text("Free  ·  Open source  ·  Nothing leaves your Mac", 960, 770, 24, .regular, white(0.45), align: .center)
    p.ctx.restoreGState()
}
