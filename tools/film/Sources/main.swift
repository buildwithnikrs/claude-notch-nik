import AVFoundation
import CoreGraphics
import Foundation

// film <output-dir> [--frames a,b,c]
//   Renders claude-notch-film.mp4 (1080p30 + soundtrack) and a poster frame into <output-dir>.
//   --frames renders only still PNGs at the given seconds (for quick visual checks).

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "out", isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let FPS = 30
let width = Int(W), height = Int(H)

func makeContext(_ data: UnsafeMutableRawPointer?, bytesPerRow: Int) -> CGContext {
    let ctx = CGContext(data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

func writePNG(_ ctx: CGContext, _ url: URL, jpeg: Bool = false) {
    guard let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, (jpeg ? "public.jpeg" : "public.png") as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, img, jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary : nil)
    CGImageDestinationFinalize(dest)
}

// Stills mode.
if let i = args.firstIndex(of: "--frames"), i + 1 < args.count {
    for s in args[i + 1].split(separator: ",").compactMap({ Double($0) }) {
        let ctx = makeContext(nil, bytesPerRow: 0)
        render(Painter(ctx), s)
        writePNG(ctx, outDir.appendingPathComponent(String(format: "frame-%05.2f.png", s)))
        print("still \(s)s")
    }
    exit(0)
}

// 1. Video.
let videoURL = outDir.appendingPathComponent(".film-video.mp4")
let audioURL = outDir.appendingPathComponent(".film-audio.m4a")
let finalURL = outDir.appendingPathComponent("claude-notch-film.mp4")
for u in [videoURL, audioURL, finalURL] { try? FileManager.default.removeItem(at: u) }

let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 3_000_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoMaxKeyFrameIntervalKey: FPS * 2,
    ],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let total = Int(DURATION * Double(FPS))
let started = Date()
for f in 0..<total {
    while !input.isReadyForMoreMediaData { usleep(2000) }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    guard let buffer = pb else { fatalError("no pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let ctx = makeContext(CVPixelBufferGetBaseAddress(buffer), bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
    let t = Double(f) / Double(FPS)
    autoreleasepool { render(Painter(ctx), t) }
    if abs(t - 47.8) < 0.5 / Double(FPS) { writePNG(ctx, outDir.appendingPathComponent("claude-notch-film-poster.jpg"), jpeg: true) }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(FPS)))
    if f % 150 == 0 { print(String(format: "frame %d/%d  (%.0fs)", f, total, Date().timeIntervalSince(started))) }
}
input.markAsFinished()
await writer.finishWriting()
guard writer.status == .completed else { fatalError("video failed: \(String(describing: writer.error))") }

// 2. Soundtrack.
var music = Soundtrack(duration: DURATION)
music.compose()
music.master(fadeOutFrom: DURATION - 1.4)
try music.write(to: audioURL)
print("soundtrack written")

// 3. Mux.
let comp = AVMutableComposition()
let vAsset = AVURLAsset(url: videoURL), aAsset = AVURLAsset(url: audioURL)
let vTrack = try await vAsset.loadTracks(withMediaType: .video).first!
let aTrack = try await aAsset.loadTracks(withMediaType: .audio).first!
let range = CMTimeRange(start: .zero, duration: CMTime(seconds: DURATION, preferredTimescale: 600))
try comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: vTrack, at: .zero)
let aDur = try await aAsset.load(.duration)
try comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
    .insertTimeRange(CMTimeRange(start: .zero, duration: min(aDur, range.duration)), of: aTrack, at: .zero)
let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough)!
export.shouldOptimizeForNetworkUse = true
try await export.export(to: finalURL, as: .mp4)
for u in [videoURL, audioURL] { try? FileManager.default.removeItem(at: u) }
let size = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? Int) ?? 0
print(String(format: "✓ %@  (%.1f MB, %.0fs render)", finalURL.lastPathComponent, Double(size) / 1_000_000, Date().timeIntervalSince(started)))
