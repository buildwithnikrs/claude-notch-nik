import AVFoundation
import Foundation

/// A synthesized soundtrack locked to the picture: 120 BPM, A minor (Am–F–C–G).
/// Everything is generated here, so there's no third-party music to license.
struct Soundtrack {
    let sr = 48_000.0
    var L: [Float]
    var R: [Float]
    var rng = RNG(99)

    init(duration: Double) {
        let n = Int(duration * 48_000)
        L = [Float](repeating: 0, count: n)
        R = [Float](repeating: 0, count: n)
    }

    // MARK: Primitives

    mutating func add(_ start: Double, _ dur: Double, pan: Double = 0, _ f: (Double) -> Double) {
        let i0 = max(0, Int(start * sr)), i1 = min(L.count, Int((start + dur) * sr))
        guard i1 > i0 else { return }
        let gl = Float(cos((pan + 1) * .pi / 4)), gr = Float(sin((pan + 1) * .pi / 4))
        for i in i0..<i1 {
            let v = Float(f(Double(i) / sr - start))
            L[i] += v * gl
            R[i] += v * gr
        }
    }

    mutating func kick(_ at: Double, _ amp: Double = 0.9) {
        var ph = 0.0
        add(at, 0.5) { t in
            let f = 44 + 110 * exp(-t * 28)
            ph += 2 * .pi * f / 48_000
            return sin(ph) * exp(-t * 7) * amp
        }
    }

    mutating func hat(_ at: Double, _ amp: Double = 0.12, pan: Double = 0.25) {
        var r = RNG(UInt64(at * 1000) + 3), prev = 0.0
        add(at, 0.07, pan: pan) { t in
            let n = r.next() * 2 - 1
            let hp = n - prev; prev = n
            return hp * exp(-t * 55) * amp
        }
    }

    mutating func clap(_ at: Double, _ amp: Double = 0.22) {
        var r = RNG(UInt64(at * 1000) + 11), lp = 0.0
        add(at, 0.25) { t in
            let n = r.next() * 2 - 1
            lp += (n - lp) * 0.35
            let bursts = t < 0.03 ? (sin(t * 2 * .pi * 90) > 0 ? 1.0 : 0.4) : 1.0
            return (n - lp) * exp(-t * 16) * amp * bursts
        }
    }

    mutating func tone(_ at: Double, _ dur: Double, _ freq: Double, _ amp: Double, attack: Double = 0.005, decay: Double = 6,
                       harmonics: [Double] = [1], pan: Double = 0) {
        add(at, dur, pan: pan) { t in
            var v = 0.0
            for (k, h) in harmonics.enumerated() { v += sin(2 * .pi * freq * Double(k + 1) * t) * h }
            let env = min(1, t / attack) * exp(-t * decay)
            let rel = min(1, (dur - t) / 0.02)
            return v * env * amp * rel
        }
    }

    mutating func pad(_ at: Double, _ dur: Double, _ freqs: [Double], _ amp: Double) {
        add(at, dur) { t in
            var v = 0.0
            for f in freqs {
                for d in [0.997, 1.003] {
                    for h in 1...5 { v += sin(2 * .pi * f * d * Double(h) * t + Double(h)) / pow(Double(h), 1.6) }
                }
            }
            let env = min(1, t / 0.6) * min(1, (dur - t) / 0.7)
            return v * env * amp / Double(freqs.count * 2)
        }
    }

    mutating func noiseSweep(_ at: Double, _ dur: Double, _ amp: Double) {
        var r = RNG(5), lp = 0.0, ph = 0.0
        add(at, dur) { t in
            let q = t / dur
            let n = r.next() * 2 - 1
            lp += (n - lp) * (0.02 + 0.5 * q * q)
            ph += 2 * .pi * (180 + 1100 * q * q) / 48_000
            return (lp * 0.8 + sin(ph) * 0.25) * q * q * amp
        }
    }

    mutating func impact(_ at: Double, _ amp: Double = 1) {
        var ph = 0.0
        add(at, 2.2) { t in
            ph += 2 * .pi * (32 + 70 * exp(-t * 9)) / 48_000
            return sin(ph) * exp(-t * 2.2) * amp
        }
        var r = RNG(77), lp = 0.0
        add(at, 1.6, pan: -0.1) { t in
            let n = r.next() * 2 - 1
            lp += (n - lp) * 0.25
            return (n - lp * 0.6) * exp(-t * 3.2) * 0.22 * amp
        }
    }

    mutating func chime(_ at: Double, _ notes: [Double], gap: Double = 0.09, amp: Double = 0.18) {
        for (i, f) in notes.enumerated() {
            tone(at + Double(i) * gap, 1.2, f, amp, attack: 0.003, decay: 3.2, harmonics: [1, 0.3, 0.08, 0.04], pan: i % 2 == 0 ? -0.2 : 0.2)
        }
    }

    mutating func click(_ at: Double) {
        var r = RNG(123)
        add(at, 0.02) { t in (r.next() * 2 - 1) * exp(-t * 400) * 0.35 }
        tone(at, 0.05, 2200, 0.05, decay: 80)
    }

    // MARK: Score

    static func note(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }

    mutating func compose() {
        let n = Soundtrack.note
        // Am, F, C, G — one chord per bar (2 s).
        let chords: [[Double]] = [[57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62]]
        let roots: [Double] = [45, 41, 48, 43]
        func chord(_ t: Double) -> Int { Int(t / 2) % 4 }

        // Pads through the whole film, louder in the open/merge/end sections.
        for bar in 0..<27 {
            let t = Double(bar) * 2
            let amp: Double
            switch t {
            case ..<4: amp = 0.10
            case ..<16: amp = 0.06
            case ..<20: amp = 0.12
            case ..<42: amp = 0.05
            case ..<46: amp = 0.08
            default: amp = 0.11
            }
            pad(t, 2.15, chords[bar % 4].map { n($0) }, amp)
        }

        // Intro: a single wake-up blip when the critter opens its eyes.
        chime(2.0, [n(81), n(88)], gap: 0.12, amp: 0.12)

        // Drums: 4–15.5 and 20–42.
        for b in 0..<200 {
            let t = Double(b) * 0.5
            let inSwarm = t >= 4 && t < 15.5, inGroove = t >= 20 && t < 42
            if inSwarm || inGroove { kick(t, inGroove ? 0.85 : 0.75) }
            if (t >= 6 && t < 15.5) || inGroove { hat(t + 0.25, 0.1) }
            if inGroove && Int(t / 0.5) % 4 == 2 { clap(t, 0.2) }
            if inGroove { hat(t + 0.125, 0.04, pan: -0.3); hat(t + 0.375, 0.04, pan: 0.3) }
        }

        // Bass eighths, ducked under the kick.
        for e in 0..<400 {
            let t = Double(e) * 0.25
            guard (t >= 8 && t < 15.5) || (t >= 20 && t < 42) else { continue }
            let root = n(roots[chord(t)])
            let duck = e % 2 == 0 ? 0.55 : 1.0
            tone(t, 0.24, root, 0.2 * duck, attack: 0.01, decay: 5, harmonics: [1, 0.35, 0.12])
        }

        // Swarm entrances: an ascending pentatonic blip per wave.
        let penta: [Double] = [69, 72, 74, 76, 79, 81, 84, 86, 88, 91, 93]
        for w in 0..<22 {
            let t = 4.0 + Double(w) * 0.25
            tone(t, 0.12, n(penta[w % penta.count]), 0.07, decay: 26, harmonics: [1, 0.2], pan: w % 2 == 0 ? -0.5 : 0.5)
        }
        // Task labels popping.
        for k in 0..<34 { tone(10.0 + Double(k) * 0.085, 0.05, n(96 + Double(k % 3) * 2), 0.03, decay: 60, pan: sin(Double(k)) * 0.7) }
        // Alerts: the pink "needs you" pings.
        for j in 1...6 { chime(13.0 + Double(j) * 0.5, [n(88), n(84)], gap: 0.07, amp: 0.09) }

        // Build and drop into the merge.
        noiseSweep(13.6, 2.4, 0.35)
        impact(16.0, 1.0)
        chime(16.0, chords[0].map { n($0 + 24) }, gap: 0.06, amp: 0.12)
        // The notch appears.
        chime(19.3, [n(76), n(81), n(88)], gap: 0.1, amp: 0.13)

        // Groove arpeggio, 16ths.
        for s in 0..<200 {
            let t = 20.0 + Double(s) * 0.125
            guard t < 42 else { break }
            let c = chords[chord(t)]
            let f = n(c[s % 3] + 24 + (s % 8 >= 6 ? 12 : 0))
            tone(t, 0.14, f, 0.035, decay: 18, harmonics: [1, 0.25], pan: s % 2 == 0 ? -0.35 : 0.35)
        }

        // UI moments.
        chime(26.2, [n(88), n(93)], gap: 0.11, amp: 0.2)   // notch taps you
        click(29.5)
        chime(30.1, [n(84), n(88), n(91)], gap: 0.07, amp: 0.15) // got it
        click(32.85)
        click(37.85)
        for i in 0..<3 { chime(38.3 + Double(i) * 0.5, [n(79 + Double(i) * 3)], amp: 0.08) }

        // Done: chord hit, sparkle cascade.
        impact(42.0, 0.6)
        chime(42.0, [n(93), n(91), n(88), n(84), n(81), n(76)], gap: 0.06, amp: 0.12)
        pad(42.0, 4.0, chords[2].map { n($0 + 12) }, 0.05)

        // End card.
        impact(46.6, 0.8)
        chime(47.2, [n(69), n(76), n(81), n(84)], gap: 0.14, amp: 0.13)
        pad(46.0, 7.0, [n(45), n(57), n(64), n(72)], 0.09)
    }

    mutating func master(fadeOutFrom: Double) {
        var peak: Float = 0
        for i in L.indices {
            let t = Double(i) / sr
            let fade = Float(1 - clamp01((t - fadeOutFrom) / 1.2))
            L[i] = tanh(L[i] * 1.1) * fade
            R[i] = tanh(R[i] * 1.1) * fade
            peak = max(peak, abs(L[i]), abs(R[i]))
        }
        let g = peak > 0 ? 0.89 / peak : 1
        for i in L.indices { L[i] *= g; R[i] *= g }
    }

    func write(to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 16_384
        var i = 0
        while i < L.count {
            let n = min(chunk, L.count - i)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            L.withUnsafeBufferPointer { src in buf.floatChannelData![0].update(from: src.baseAddress! + i, count: n) }
            R.withUnsafeBufferPointer { src in buf.floatChannelData![1].update(from: src.baseAddress! + i, count: n) }
            try file.write(from: buf)
            i += n
        }
    }
}
