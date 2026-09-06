// MVProbe — measurement prototype for classic MCFI motion estimation
// (hierarchical block matching, MSL compute shaders) in Core/Interpolation.
//
// Usage:
//   swift run MVProbe [path/to/file.mkv]
//
// Env (optional):
//   MV_PAIRS   pairs to process  (default 120 ⇒ decodes 121 frames)
//   MV_LAMBDA  linear true-motion penalty per px (default 4)
//   MV_SUBPEL  0 disables half-pel refinement at L0 (default 1)
//   MV_DUMP    0 disables PNG/CSV export of pair 0 (default 1)
//
// Success criterion: real measured time per stage on ≥100 real pairs from an
// MKV, reported as mean/p50/p95 on the M4, and a visually verifiable MV field.
// The source file is demuxed/decoded on demand only — nothing is copied or
// transcoded. This is a measurement harness: it consumes Core/Demux and
// Core/Decode as-is (read-only), touches no other module.

import Foundation
import CoreVideo
import Metal
import CoreMedia
import VideoToolbox
import Demux
import Decode
import Interpolation
import Accelerate
import CoreGraphics
import ImageIO

// MARK: - Configuration

let defaultPath = "/Users/rafael/Downloads/Avatar.Aang.el.ultimo.maestro.del.aire.2026.WEB-DL.4k.HDR-Dual-Lat.mkv"
let workWidth = 1152
let workHeight = 480

private func envInt(_ key: String, _ fallback: Int) -> Int {
    guard let raw = ProcessInfo.processInfo.environment[key], let v = Int(raw) else { return fallback }
    return v
}

let pairCount = envInt("MV_PAIRS", 120)
let lambdaPx = envInt("MV_LAMBDA", 4)
let subpelOn = envInt("MV_SUBPEL", 1) != 0
let dumpArtifacts = envInt("MV_DUMP", 1) != 0
let seekFraction = Double(envInt("MV_SEEK_PCT", 60)) / 100.0
let dumpDir = "/tmp/rift_mvprobe"

// MARK: - Helpers

private func elapsedMilliseconds(from start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
}

private func chipName() -> String {
    var name = [CChar](repeating: 0, count: 256)
    var size = name.count
    if sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0) == 0 {
        return String(cString: name)
    }
    return "unknown"
}

func stats(_ xs: [Double]) -> (mean: Double, p50: Double, p95: Double) {
    guard !xs.isEmpty else { return (0, 0, 0) }
    let mean = xs.reduce(0, +) / Double(xs.count)
    let s = xs.sorted()
    func pct(_ q: Double) -> Double {
        let idx = min(max(Int((Double(s.count) - 1) * q), 0), s.count - 1)
        return s[idx]
    }
    return (mean, pct(0.5), pct(0.95))
}

// MARK: - Luma extraction (plane0 of 420YpCbCr10BiPlanar, 10 bit in high bits
// of each 16-bit word) scaled to the 480p work plane with vImage. Linear
// resampling is SAD-safe: both frames go through the exact same transform.

private func scaledLuma(_ buffer: CVPixelBuffer) -> Data? {
    guard CVPixelBufferIsPlanar(buffer), CVPixelBufferGetPlaneCount(buffer) >= 1 else { return nil }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

    let sw = CVPixelBufferGetWidthOfPlane(buffer, 0)
    let sh = CVPixelBufferGetHeightOfPlane(buffer, 0)
    let bpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }

    var src = Data(count: sw * sh * MemoryLayout<UInt16>.stride)
    src.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) -> Void in
        let dst = dstRaw.bindMemory(to: UInt16.self)
        let dstBase = dst.baseAddress!
        for row in 0..<sh {
            let srcRow = base.advanced(by: row * bpr).assumingMemoryBound(to: UInt16.self)
            for col in 0..<sw {
                dstBase[row * sw + col] = srcRow[col] >> 6
            }
        }
    }

    var out = Data(count: workWidth * workHeight * MemoryLayout<UInt16>.stride)
    src.withUnsafeMutableBytes { (srcRaw: UnsafeMutableRawBufferPointer) -> Void in
        out.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) -> Void in
            var srcBuf = vImage_Buffer(
                data: srcRaw.baseAddress,
                height: vImagePixelCount(sh),
                width: vImagePixelCount(sw),
                rowBytes: sw * MemoryLayout<UInt16>.stride
            )
            var dstBuf = vImage_Buffer(
                data: dstRaw.baseAddress,
                height: vImagePixelCount(workHeight),
                width: vImagePixelCount(workWidth),
                rowBytes: workWidth * MemoryLayout<UInt16>.stride
            )
            vImageScale_Planar16U(&srcBuf, &dstBuf, nil,
                                  vImage_Flags(kvImageHighQualityResampling | kvImageDoNotTile))
        }
    }
    return out
}

// MARK: - PNG export helpers

private func writeGrayPNG(_ gray: [UInt8], width: Int, height: Int, to path: String) -> Bool {
    guard let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ), let canvas = ctx.data else { return false }
    gray.withUnsafeBytes { canvas.copyMemory(from: $0.baseAddress!, byteCount: width * height) }
    return finalizePNG(ctx, path: path)
}

private func writeRGBA(_ rgba: [UInt8], width: Int, height: Int, to path: String) -> Bool {
    let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: info
    ), let canvas = ctx.data else { return false }
    rgba.withUnsafeBytes { canvas.copyMemory(from: $0.baseAddress!, byteCount: width * height * 4) }
    return finalizePNG(ctx, path: path)
}

private func finalizePNG(_ ctx: CGContext, path: String) -> Bool {
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(
              URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil
          ) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

private func hsv2rgb(h: Double, s: Double, v: Double) -> (UInt8, UInt8, UInt8) {
    let c = v * s
    let x = c * (1.0 - abs((h.truncatingRemainder(dividingBy: 360.0) / 60.0).truncatingRemainder(dividingBy: 2.0) - 1.0))
    let m = v - c
    var r = 0.0, g = 0.0, b = 0.0
    let hh = (h + 360.0).truncatingRemainder(dividingBy: 360.0)
    switch hh {
    case 0..<60: (r, g, b) = (c, x, 0)
    case 60..<120: (r, g, b) = (x, c, 0)
    case 120..<180: (r, g, b) = (0, c, x)
    case 180..<240: (r, g, b) = (0, x, c)
    case 240..<300: (r, g, b) = (x, 0, c)
    default: (r, g, b) = (c, 0, x)
    }
    return (UInt8((r + m) * 255), UInt8((g + m) * 255), UInt8((b + m) * 255))
}

/// Same HSV mapping as mvDiagramL0, returning the RGB of one grid block.
private func rgbAt(_ mvs: [SIMD2<Int32>], gridW: Int, blockSize: Int, bx: Int, by: Int) -> [UInt8] {
    let mv = mvs[by * gridW + bx]
    let dx = Double(mv.x) / 2.0
    let dy = Double(mv.y) / 2.0
    let mag = (dx * dx + dy * dy).squareRoot()
    let hue = atan2(dy, dx) * 180.0 / .pi
    let (r, g, b) = hsv2rgb(h: hue + 180.0, s: 1.0, v: 0.18 + 0.82 * min(mag / 24.0, 1.0))
    return [r, g, b]
}

/// Renders the L0 MV field as HSV flow colors (hue = direction, value = speed,
/// capped at 24 px/frame) into a block-grid upscaled image. Blocks with
/// mag < 1 px are rendered as neutral gray (no hue) — encoding direction as
/// hue for near-zero vectors makes angle noise look like field corruption.
/// Lesson (2026-09-02): numeric ratio and hue-for-all are both insufficient
/// alone; magnitude thresholding in the visualizer is required for reliable
/// visual inspection. Keep this threshold as default.
private func mvDiagramL0(_ mvs: [SIMD2<Int32>], gridW: Int, gridH: Int, blockSize: Int) -> [UInt8] {
    let w = gridW * blockSize
    let h = gridH * blockSize
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    let magCap = 24.0
    let hueThresholdPx = 1.0
    for by in 0..<gridH {
        for bx in 0..<gridW {
            let mv = mvs[by * gridW + bx]
            let dx = Double(mv.x) / 2.0
            let dy = Double(mv.y) / 2.0
            let mag = (dx * dx + dy * dy).squareRoot()
            let v = 0.18 + 0.82 * min(mag / magCap, 1.0)
            let (r, g, b): (UInt8, UInt8, UInt8)
            if mag < hueThresholdPx {
                let gray = UInt8(v * 255)
                (r, g, b) = (gray, gray, gray)
            } else {
                let hue = atan2(dy, dx) * 180.0 / .pi
                (r, g, b) = hsv2rgb(h: hue + 180.0, s: 1.0, v: v)
            }
            for yy in 0..<blockSize {
                for xx in 0..<blockSize {
                    let idx = ((by * blockSize + yy) * w + (bx * blockSize + xx)) * 4
                    rgba[idx] = r
                    rgba[idx + 1] = g
                    rgba[idx + 2] = b
                    rgba[idx + 3] = 255
                }
            }
        }
    }
    return rgba
}

private func lumaGray(_ data: Data) -> [UInt8] {
    let count = workWidth * workHeight
    var gray = [UInt8](repeating: 0, count: count)
    data.withUnsafeBytes { raw in
        let u16 = raw.bindMemory(to: UInt16.self)
        for i in 0..<count {
            let v = u16[i] >> 2 // 10-bit luma → 8-bit
            gray[i] = v > 255 ? 255 : UInt8(v)
        }
    }
    return gray
}

private func writeMVCSV(_ mvs: [SIMD2<Int32>], gridW: Int, gridH: Int, path: String) {
    var s = "bx,by,mvx_halfpel,mvy_halfpel\n"
    for i in 0..<mvs.count {
        let b = mvs[i]
        s += "\(i % gridW),\(i / gridW),\(b.x),\(b.y)\n"
    }
    try? s.write(toFile: path, atomically: true, encoding: .utf8)
}

/// Quantitative validity check for the MV field, cumulative over every pair:
/// for each L0 block compare the SAD of the motion-compensated prediction
/// against the zero-move SAD and track the largest displacement found. A mean
/// improve-fraction well above 0 (and ratio < 1) proves the field captures real
/// motion; tracking max |MV| across all pairs distinguishes "static scene"
/// from "broken ME".
struct PairMetrics {
    var zeroTotal: UInt64 = 0
    var compTotal: UInt64 = 0
    var blocksImprove = 0
    // Magnitude histogram in full pixels (half-pel / 2): bins [≤0.5, ≤1, ≤2, ≤8, ≤16, >16]
    var hist = [0, 0, 0, 0, 0, 0]
}

private func magBinPx(_ mv: SIMD2<Int32>) -> Int {
    let magPx = (Double(mv.x) * Double(mv.x) + Double(mv.y) * Double(mv.y)).squareRoot() / 2.0
    if magPx <= 0.5 { return 0 }
    if magPx <= 1 { return 1 }
    if magPx <= 2 { return 2 }
    if magPx <= 8 { return 3 }
    if magPx <= 16 { return 4 }
    return 5
}

private func measurePair(cur: [UInt16], ref: [UInt16], mvs: [SIMD2<Int32>]) -> PairMetrics {
    let w = workWidth
    let h = workHeight
    let bs = 8
    let gw = w / bs
    let gh = h / bs
    var m = PairMetrics()
    for by in 0..<gh {
        for bx in 0..<gw {
            let mv = mvs[by * gw + bx]
            let dx = Int(mv.x) / 2
            let dy = Int(mv.y) / 2
            var zSad: UInt64 = 0
            var cSad: UInt64 = 0
            for y in 0..<bs {
                for x in 0..<bs {
                    let ix = bx * bs + x
                    let iy = by * bs + y
                    let c = UInt64(cur[iy * w + ix])
                    let r = UInt64(ref[iy * w + ix])
                    let rp = UInt64(ref[min(max(iy + dy, 0), h - 1) * w + min(max(ix + dx, 0), w - 1)])
                    zSad += c >= r ? c - r : r - c
                    cSad += c >= rp ? c - rp : rp - c
                }
            }
            m.zeroTotal += zSad
            m.compTotal += cSad
            if cSad < zSad { m.blocksImprove += 1 }
            m.hist[magBinPx(mv)] += 1
        }
    }
    return m
}

/// Ground-truth probe on high-texture blocks of a pair: brute-force SAD over
/// +/-40 px, reporting (a) whether the winner is a genuinely good match (cost
/// clearly below the zero-move cost), (b) where league-winning offsets cluster,
/// so we can tell "real large motion not reached by the estimator" from "no
/// correspondence exists here at all" (cuts / heavy aliasing).
private func bruteProbe(cur: [UInt16], ref: [UInt16]) -> [(bx: Int, by: Int, dx: Int, dy: Int)] {
    let w = workWidth
    let h = workHeight
    let bs = 8
    let gh = h / bs
    let range = 40
    var sampled = 0
    var zeroWins = 0
    var goodMatches = 0
    var sumImproveRatio = 0.0
    var sumDX = 0.0
    var sumDY = 0.0
    var samples: [(bx: Int, by: Int, dx: Int, dy: Int)] = []
    var magBins = [Int](repeating: 0, count: 9)
    for startBy in stride(from: 0, to: gh, by: 32) {
        let by = min(startBy, gh - 1)
        for bx in 0..<(w / bs / 4) {
            var mean: UInt64 = 0
            var variance: UInt64 = 0
            for y in 0..<bs {
                for x in 0..<bs {
                    mean += UInt64(cur[(by * bs + y) * w + bx * 4 * bs + x])
                }
            }
            mean /= UInt64(bs * bs)
            for y in 0..<bs {
                for x in 0..<bs {
                    let v = UInt64(cur[(by * bs + y) * w + bx * 4 * bs + x])
                    let d = v > mean ? v - mean : mean - v
                    variance += d * d
                }
            }
            if variance < 400 { continue }
            sampled += 1
            var bestDX = 0
            var bestDY = 0
            var bestCost = UInt64.max
            var costZero: UInt64 = 0
            for oy in -range...range {
                for ox in -range...range {
                    var cost: UInt64 = 0
                    for y in 0..<bs {
                        for x in 0..<bs {
                            let ix = bx * 4 * bs + x
                            let iy = by * bs + y
                            let c = UInt64(cur[iy * w + ix])
                            let px = min(max(ix + ox, 0), w - 1)
                            let py = min(max(iy + oy, 0), h - 1)
                            let r = UInt64(ref[py * w + px])
                            cost += c >= r ? c - r : r - c
                        }
                    }
                    if ox == 0 && oy == 0 { costZero = cost }
                    if cost < bestCost { bestCost = cost; bestDX = ox; bestDY = oy }
                }
            }
            let mag = (Double(bestDX * bestDX + bestDY * bestDY)).squareRoot()
            if mag <= 0.5 { magBins[0] += 1 } else if mag <= 1 { magBins[1] += 1 }
            else if mag <= 2 { magBins[2] += 1 } else if mag <= 4 { magBins[3] += 1 }
            else if mag <= 8 { magBins[4] += 1 } else if mag <= 16 { magBins[5] += 1 }
            else if mag <= 30 { magBins[6] += 1 } else if mag <= 40 { magBins[7] += 1 }
            else { magBins[8] += 1 }
            if bestDX == 0 && bestDY == 0 { zeroWins += 1 }
            if costZero > 0 && Double(bestCost) / Double(costZero) < 0.75 { goodMatches += 1 }
            sumImproveRatio += Double(bestCost) / Double(max(costZero, 1))
            sumDX += Double(bestDX)
            sumDY += Double(bestDY)
            samples.append((bx * 4, by, bestDX, bestDY))
        }
    }
    print(String(format: "brute ±40px on %d high-texture blocks: zero-wins=%d good-matches(best<0.75×zero)=%d mean best/zero-ratio=%.2f",
                 sampled, zeroWins, goodMatches, sumImproveRatio / Double(max(sampled, 1))))
    print(String(format: "  argmin magnitude bins (px): ≤0.5=%d 1=%d 2=%d 3-4=%d 5-8=%d 9-16=%d 17-30=%d 31-40=%d >40=%d",
                 magBins[0], magBins[1], magBins[2], magBins[3], magBins[4], magBins[5], magBins[6], magBins[7], magBins[8]))
    print(String(format: "  argmin dominant offset (mean over blocks): (%.1f, %.1f) px",
                 sumDX / Double(max(sampled, 1)), sumDY / Double(max(sampled, 1))))
    return samples
}

// MARK: - Main

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultPath
print("=== MVProbe (hierarchical block matching, MSL) ===")
print("chip    : \(chipName())")
print("file    : \(path)")
print("config  : pairs=\(pairCount) plane=\(workWidth)x\(workHeight) lambda=\(lambdaPx) subpel=\(subpelOn ? "on" : "off") median=\(envInt("MV_MEDIAN", 1) == 1 ? "on" : "off") gate=\(envInt("MV_GATE", 1) == 1 ? "on" : "off") hier=\(envInt("MV_HIER", 1) == 1 ? "on" : "off")")

let demuxer = FFmpegDemuxer()
let info: ContainerInfo
do {
    info = try demuxer.open(url: URL(fileURLWithPath: path))
} catch {
    print("OPEN FAILED: \(error)")
    exit(1)
}
guard let video = info.tracks.first(where: { $0.kind == .video }) else {
    print("FAIL: no video track in container")
    exit(1)
}
print("video   : \(video.width ?? 0)x\(video.height ?? 0) \(video.codecName) "
    + "fps=\(video.frameRate.map { String(format: "%.3f", $0) } ?? "-")")

let decoder = VTDecoder()
do {
    try decoder.prepare(track: video)
} catch {
    print("PREPARE FAILED: \(error)")
    exit(1)
}

let seekTime = info.duration * seekFraction
do {
    try demuxer.seek(to: seekTime)
    decoder.flush()
} catch {
    print("WARNING: seek failed, decoding from start — \(error)")
}
print(String(format: "decoding from %.2f s (≈%.0f%%) until %d luma planes are ready…",
             seekTime, seekFraction * 100.0, pairCount + 1))

var frames: [Data] = []
var readPackets = 0
while frames.count < pairCount + 1 && readPackets < 100_000 {
    guard let packet = try? demuxer.nextPacket() else { break }
    readPackets += 1
    guard packet.streamIndex == video.streamIndex else { continue }
    guard let buf = try? decoder.decodeFrame(packet) else { continue }
    guard let luma = scaledLuma(buf) else { continue }
    frames.append(luma)
}
decoder.close()
demuxer.close()

guard frames.count >= pairCount + 1 else {
    print("FAIL: only \(frames.count) planes decoded (need \(pairCount + 1))")
    exit(2)
}

let pyramidSpec: [LevelSpec]
if envInt("MV_HIER", 1) == 1 {
    pyramidSpec = [
        LevelSpec(width: workWidth, height: workHeight, blockSize: 8,  searchHalfPel: 8,  halfPelRefine: subpelOn, inheritFactor: 4),
        LevelSpec(width: 576,       height: 240,        blockSize: 16, searchHalfPel: 16, halfPelRefine: false,   inheritFactor: 2),
        LevelSpec(width: 288,       height: 120,        blockSize: 16, searchHalfPel: 32, halfPelRefine: false,   inheritFactor: 2),
        LevelSpec(width: 144,       height: 60,         blockSize: 16, searchHalfPel: 32, halfPelRefine: false,   inheritFactor: 1),
    ]
} else {
    // Single level, exhaustive wide search: isolates the coarse-hierarchy from
    // the fine-level block matcher (diagnostic, MV_HIER=0). ~40x L0 cost.
    pyramidSpec = [
        LevelSpec(width: workWidth, height: workHeight, blockSize: 8, searchHalfPel: 70, halfPelRefine: subpelOn, inheritFactor: 1),
    ]
}

let engine: MotionSearchEngine
do {
    engine = try MotionSearchEngine(
        msl: motionShadersMSL,
        spec: pyramidSpec,
        lambdaPx: UInt32(lambdaPx),
        smoothL0: envInt("MV_MEDIAN", 1) == 1,
        gateL0: envInt("MV_GATE", 1) == 1
    )
} catch {
    print("ENGINE INIT FAILED: \(error)")
    exit(3)
}
let warpEngine: WarpEngine
do {
    guard let dev = MTLCreateSystemDefaultDevice() else { print("WARP INIT FAILED: no Metal device"); exit(3) }
    warpEngine = try WarpEngine(device: dev)
} catch {
    print("WARP INIT FAILED: \(error)")
    exit(3)
}
var warpTotal: [Double] = []

// Synthetic HSV-coloring verification (MV_DIAG_ZERO=1): render a field of
// known vectors to PNG and print the exact RGB at each grid block. This pins
// down the color for MV=(0,0) and a large vector BEFORE blaming the estimator.
if envInt("MV_DIAG_ZERO", 0) == 1 {
    let g = engine.grids[0]
    var field = [SIMD2<Int32>](repeating: SIMD2<Int32>(0, 0), count: g.w * g.h)
    // Split image: left half all-zero, right half a uniform +20px rightward
    // motion (so one block's color is directly comparable).
    for by in 0..<g.h {
        for bx in 0..<g.w {
            if bx >= g.w / 2 {
                field[by * g.w + bx] = SIMD2<Int32>(40, 0) // +20 px rightward
            }
        }
    }
    try? FileManager.default.createDirectory(atPath: dumpDir, withIntermediateDirectories: true)
    _ = writeRGBA(mvDiagramL0(field, gridW: g.w, gridH: g.h, blockSize: 8),
                  width: workWidth, height: workHeight, to: "\(dumpDir)/diag_zero_field.png")
    // Print the RGB of representative blocks.
    let half = g.w / 2
    let zeroRGB = rgbAt(field, gridW: g.w, blockSize: 8, bx: 1, by: 1)
    let movedRGB = rgbAt(field, gridW: g.w, blockSize: 8, bx: half + 1, by: 1)
    print(String(format: "DIAG zero-field: MV=(0,0) -> RGB(%d,%d,%d); MV=(+20,0) -> RGB(%d,%d,%d)",
                 zeroRGB[0], zeroRGB[1], zeroRGB[2], movedRGB[0], movedRGB[1], movedRGB[2]))
    print("artifacts: \(dumpDir)/diag_zero_field.png")
}

// Hierarchical amplification diagnostic (MV_HIER_DIAG=1): for pair 0, print
// how each level's search result diverges from the inherited (coarse, x2-scaled)
// center. If level n's chosen MV is almost always exactly the x2-scaled parent
// (center), the fine search is rubber-stamping a coarse decision and any coarse
// error doubles every level. Also prints raw magnitude extremes per level so a
// mechanical x2/overflow (symmetric, "round" values like +-424) is obvious.
if envInt("MV_HIER_DIAG", 0) == 1 {
    _ = engine.runPair(cur: frames[0], ref: frames[1])
    func magpx(_ v: SIMD2<Int32>) -> Double {
        (Double(v.x) * Double(v.x) + Double(v.y) * Double(v.y)).squareRoot() / 2.0
    }
    let mg = engine.grids.count
    for lvl in 0..<mg {
        let g = engine.grids[lvl]
        let f = engine.downloadMV(level: lvl, smoothed: false)
        let mags = f.map(magpx)
        let mx = mags.max() ?? 0
        let top = f.enumerated().sorted { magpx($0.element) > magpx($1.element) }.prefix(5)
        let str = top.map { "L\(lvl) [\($0.element.x),\($0.element.y)]=\(String(format: "%.0f", magpx($0.element)))px" }.joined(separator: "; ")
        print("  \(str)")
        _ = mx
    }
    let g0 = engine.grids[0]
    let g1 = engine.grids[1]
    let l0 = engine.downloadMV(level: 0, smoothed: false)
    let l1 = engine.downloadMV(level: 1, smoothed: false)
    let fx = g0.w / g1.w
    let fy = g0.h / g1.h
    var centerEqual = 0
    var total = 0
    var nearCenterP = 0      // |chosen - 2*parent| <= 4px
    var nearZeroP = 0        // |chosen| <= 2px
    var farFromBoth = 0
    for by in 0..<g0.h {
        for bx in 0..<g0.w {
            total += 1
            let px = min(bx / fx, g1.w - 1)
            let py = min(by / fy, g1.h - 1)
            let center = SIMD2<Int32>(2 &* l1[py * g1.w + px].x, 2 &* l1[py * g1.w + px].y)
            let chosen = l0[by * g0.w + bx]
            if chosen.x == center.x && chosen.y == center.y { centerEqual += 1 }
            let dC = magpx(chosen &- center)
            let dZ = magpx(chosen)
            if dC <= 4 { nearCenterP += 1 }
            if dZ <= 2 { nearZeroP += 1 }
            if dC > 4 && dZ > 2 { farFromBoth += 1 }
        }
    }
    print("L0→L1 inherit block ratio (g0/g1) = (\(fx),\(fy))")
    print(String(format: "L0 chosen vs inherited 2*parent: exactly-equal=%.2f%%  within4px-of-center=%.2f%%  within2px-of-zero=%.2f%%  far-from-both=%.2f%%",
                 100.0 * Double(centerEqual) / Double(total),
                 100.0 * Double(nearCenterP) / Double(total),
                 100.0 * Double(nearZeroP) / Double(total),
                 100.0 * Double(farFromBoth) / Double(total)))
}
var perStage = [[Double]](repeating: [], count: SEStage.allCases.count)
var perPairTotal: [Double] = []
var uploadTotal: [Double] = []
// Per-level |MV| magnitude histograms (index 0 = L0): 6 bins like PairMetrics.hist.
var levelHist = [[Int]](repeating: [0, 0, 0, 0, 0, 0], count: 4)
var levelBlocks = [Int](repeating: 0, count: 4)
// Aggregate motion-compensation metrics, accumulated per pair inside the main
// loop (NOT recomputed on the last field after the loop — that was a reporting
// bug that made the histogram reflect only whichever pair landed last).
var cum = PairMetrics()
var totalBlocks = 0
let measureBS = 8
let measureGW = workWidth / measureBS
let measureGH = workHeight / measureBS
let measurePlaneCount = workWidth * workHeight
var madSum = 0.0
var madMax = 0.0

print("\n--- measuring \(pairCount) pairs @ \(workWidth)x\(workHeight) ---")
for i in 0..<pairCount {
    let pairStart = DispatchTime.now().uptimeNanoseconds
    let t = engine.runPair(cur: frames[i], ref: frames[i + 1])
    for s in SEStage.allCases {
        perStage[s.rawValue].append(t.stages[s.rawValue])
    }
    perPairTotal.append(t.stages.reduce(0, +))
    uploadTotal.append(t.uploadMS)

    for lvl in 0..<engine.grids.count {
        let g = engine.grids[lvl]
        let mvs = engine.downloadMV(level: lvl)
        for b in mvs {
            levelHist[lvl][magBinPx(b)] += 1
            levelBlocks[lvl] += 1
        }
    }

    // Per-pair quality metrics: accumulate the same L0 field the histogram uses.
    let cur: [UInt16] = frames[i].withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
    let ref: [UInt16] = frames[i + 1].withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
    let m = measurePair(cur: cur, ref: ref, mvs: engine.downloadMV(level: 0))
    cum.zeroTotal += m.zeroTotal
    cum.compTotal += m.compTotal
    cum.blocksImprove += m.blocksImprove
    for b in 0..<cum.hist.count { cum.hist[b] += m.hist[b] }
    totalBlocks += measureGW * measureGH

    var diff: UInt64 = 0
    for k in 0..<measurePlaneCount {
        let a = UInt64(cur[k])
        let b = UInt64(ref[k])
        diff += a >= b ? a - b : b - a
    }
    let mad = Double(diff) / Double(measurePlaneCount)
    madSum += mad
    if mad > madMax { madMax = mad }

    // Warp/blend at t=0.5 (OBMC omitted v1 — known limitation, see header)
    let mvForWarp = engine.downloadMV(level: 0)
    let (interpPlane, warpMS) = warpEngine.interpolate(I0: cur, I1: ref, mv: mvForWarp, width: workWidth, height: workHeight, gridW: measureGW, gridH: measureGH, blockSize: measureBS, t: 0.5)
    warpTotal.append(warpMS)

    print(String(format: "  pair %4d: ME %.3f ms + warp %.3f ms", i + 1, elapsedMilliseconds(from: pairStart) - warpMS, warpMS))

    if dumpArtifacts && i == 0 {
        try? FileManager.default.createDirectory(atPath: dumpDir, withIntermediateDirectories: true)
        let g = engine.grids[0]
        let mv0 = engine.downloadMV(level: 0)
        _ = writeRGBA(mvDiagramL0(mv0, gridW: g.w, gridH: g.h, blockSize: 8),
                      width: workWidth, height: workHeight, to: "\(dumpDir)/mv_l0_pair0.png")
        _ = writeGrayPNG(lumaGray(frames[0]), width: workWidth, height: workHeight,
                         to: "\(dumpDir)/cur_l0_pair0_gray.png")
        // I1 (next real frame) for side-by-side I0 / interp / I1 inspection
        let nxtGray: [UInt8]
        if frames.count > 1 {
            nxtGray = lumaGray(frames[1])
        } else {
            // fallback: ref plane from this pair
            nxtGray = ref.map { UInt8(min(255, Int($0 >> 2))) }
        }
        _ = writeGrayPNG(nxtGray, width: workWidth, height: workHeight, to: "\(dumpDir)/nxt_l0_pair0_gray.png")
        writeMVCSV(mv0, gridW: g.w, gridH: g.h, path: "\(dumpDir)/mv_l0_pair0.csv")
        // Export interpolated frame at t=0.5 for direct visual inspection (lesson: no ratio/histogram alone)
        let interpGray = interpPlane.map { UInt8(min(255, Int($0 >> 2))) }
        _ = writeGrayPNG(interpGray, width: workWidth, height: workHeight, to: "\(dumpDir)/interp_t05_pair0.png")
        print("artifacts: \(dumpDir)/{mv_l0_pair0.png, cur_l0_pair0_gray.png, nxt_l0_pair0_gray.png, mv_l0_pair0.csv, interp_t05_pair0.png}")
    }
}

print("\n--- |MV| magnitude distribution per level (px, cumulative over \(pairCount) pairs) ---")
print(String(format: "  %-24@ %8@ %8@ %8@ %8@ %8@ %8@",
             "level" as NSString, "≤0.5" as NSString, "1" as NSString, "2" as NSString,
             "3-8" as NSString, "9-16" as NSString, ">16" as NSString))
for lvl in 0..<engine.grids.count {
    let label = "L\(lvl) (\(engine.grids[lvl].w)x\(engine.grids[lvl].h))"
    var row = String(format: "  %-24@", label as NSString)
    for b in 0..<6 {
        let pct = Double(levelHist[lvl][b]) / Double(max(levelBlocks[lvl], 1)) * 100
        row += String(format: " %7.1f%%", pct)
    }
    print(row)
}

print("\n--- per-stage timings (ms) over \(pairCount) pairs ---")
print(String(format: "  %-42@ %10@ %10@ %10@", "stage" as NSString, "mean" as NSString, "p50" as NSString, "p95" as NSString))
for s in SEStage.allCases {
    let t = stats(perStage[s.rawValue])
    print(String(format: "  %-42@ %10.3f %10.3f %10.3f", s.label as NSString, t.mean, t.p50, t.p95))
}

let total = stats(perPairTotal)
let up = stats(uploadTotal)
print(String(format: "\nME total per pair : mean=%.3f p50=%.3f p95=%.3f ms", total.mean, total.p50, total.p95))
print(String(format: "host upload/pair  : mean=%.3f ms", up.mean))
print(String(format: "ME total + upload : mean=%.3f ms", total.mean + up.mean))
print(String(format: "\nbUDGET 41.7 ms/pair @60fps → ME is %.1f%% of budget (upload excluded)",
             total.mean / 41.7 * 100.0))
print("REFERENCE (RIFE MLX probe, same plane): t_flow=177.7ms stage, 196.3ms end-to-end "
     + "→ classic ME is \(String(format: "%.1f", 177.7 / max(total.mean, 0.001)))x faster at measured stage cost.")
let warp = stats(warpTotal)
print(String(format: "\nWarp/blend t=0.5 per pair : mean=%.3f p50=%.3f p95=%.3f ms (OBMC omitted v1, occ thresh 1.0px)", warp.mean, warp.p50, warp.p95))
let combined = total.mean + warp.mean
print(String(format: "Combined ME+warp per pair : mean=%.3f ms (%.1f%% of 41.7ms budget) — margen %.1f ms %@",
             combined, combined/41.7*100.0, 41.7 - combined, combined <= 41.7 ? "dentro" : "EXCEDE"))
if combined > 41.7 {
    print("NOTA: OBMC omitido v1; si se añade, re-medir presupuesto.")
}

// Quality verdict — computed from the metrics accumulated INSIDE the main loop
// (cum, totalBlocks, madSum, madMax), so the aggregate reflects every measured
// pair instead of whichever pair ran last.
let ratio = Double(cum.compTotal) / Double(cum.zeroTotal)
print(String(format: "\nmotion metric (cumulative over %d pairs): %.1f%% of blocks improve on zero-move, compensated/zero SAD ratio = %.3f",
             pairCount, 100.0 * Double(cum.blocksImprove) / Double(totalBlocks), ratio))
let h = cum.hist.map { Double($0) / Double(totalBlocks) }
print(String(format: "MV magnitude histogram (px): ≤0.5=%.1f%% ≤1=%.1f%% ≤2=%.1f%% ≤8=%.1f%% ≤16=%.1f%% >16=%.1f%%",
             h[0] * 100, h[1] * 100, h[2] * 100, h[3] * 100, h[4] * 100, h[5] * 100))
print(String(format: "frame deltas avg %.1f / max %.1f (10-bit luma units; ~0 → static frames, large → real content change)",
             madSum / Double(pairCount), madMax))

if envInt("MV_BRUTE", 0) == 1 {
    var pair0Samples: [(bx: Int, by: Int, dx: Int, dy: Int)] = []
    for i in 0..<min(pairCount, 3) {
        let cur: [UInt16] = frames[i].withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        let ref: [UInt16] = frames[i + 1].withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        print("pair \(i):", terminator: " ")
        let s = bruteProbe(cur: cur, ref: ref)
        if i == 0 { pair0Samples = s }
    }
    // Shader-vs-brute agreement on the SAME blocks (fresh pair-0 L0 run, raw
    // pre-median field, same +/-40px window in MV_HIER=0): two independent SAD
    // implementations over identical data must pick ~identical argmins if the
    // estimator pipeline is faithful.
    _ = engine.runPair(cur: frames[0], ref: frames[1])
    let raw0 = engine.downloadMV(level: 0, smoothed: false)
    let rawW = engine.grids[0].w
    var agree = 0
    var agreeMag = 0
    for s in pair0Samples {
        let midx = Int(raw0[s.by * rawW + s.bx].x)
        let midy = Int(raw0[s.by * rawW + s.bx].y)
        let sx = Double(midx) / 2.0
        let sy = Double(midy) / 2.0
        if abs(sx - Double(s.dx)) <= 3 && abs(sy - Double(s.dy)) <= 3 { agree += 1 }
        if abs(sx - Double(s.dx)) <= 8 && abs(sy - Double(s.dy)) <= 8 { agreeMag += 1 }
    }
    print(String(format: "shader-vs-brute (same %d blocks, +-3px): agree=%.1f%%  (+-8px): %.1f%%",
                 pair0Samples.count,
                 100.0 * Double(agree) / Double(max(pair0Samples.count, 1)),
                 100.0 * Double(agreeMag) / Double(max(pair0Samples.count, 1))))

    // Pyramid energy check (textures from the runPair above): report mean/var
    // per level so a constant (all-zero / unwritten) level is obvious.
    for lvl in 0..<engine.texSizes.count {
        let pix = engine.readLevel(lvl)
        let count = max(pix.count, 1)
        var acc = 0.0
        var acc2 = 0.0
        for v in pix {
            let f = Double(v)
            acc += f
            acc2 += f * f
        }
        let mean = acc / Double(count)
        let variance = acc2 / Double(count) - mean * mean
        let t = engine.texSizes[lvl]
        print(String(format: "pyramid L%d (cur, %dx%d): mean=%.1f var=%.1f min=%d max=%d",
                     lvl, t.w, t.h, mean, variance, pix.min() ?? 0, pix.max() ?? 0))
    }

    // Ground truth: does the GPU L0 texture equal the host luma plane exactly?
    // 0 differing pixels → upload path faithful → kernel bug is the only suspect.
    let p0r = engine.readLevel(0)
    let src: [UInt16] = frames[0].withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
    if p0r.count == src.count {
        var neq = [Int](repeating: 0, count: 9)
        var maxDiff = 0
        var ssd = 0.0
        for k in 0..<p0r.count {
            let d = abs(Int(p0r[k]) - Int(src[k]))
            if d > 0 {
                ssd += Double(d * d)
                if d > maxDiff { maxDiff = d }
                let b = min(d / 2, 8)
                neq[b] += 1
            }
        }
        let n = p0r.count
        let mismatched = neq.reduce(0, +)
        print(String(format: "L0 texture vs host frames[0]: %d/%d px differ, maxDiff=%d, ssd=%.0f",
                     mismatched, n, maxDiff, ssd))
        if mismatched > 0 {
            print(String(format: "  diff histogram (1-2,3-4,5-6,7-8,9-10,11-20,21-40,41-80,>80): %@",
                         neq.map(String.init).joined(separator: ",")))
        }
    }

    // Field quality vs the (robust) dominant pan: median (dx,dy) of the L0
    // field as the center, capture = % of blocks within +-3px of it, and
    // dispersion = median abs deviation in px. Raw writes are still in
    // mvBuffer[0] from the runPair above, so raw-vs-smoothed capture shows the
    // median pass pruning outliers.
    func medianOffset(_ mvs: [SIMD2<Int32>]) -> (dx: Double, dy: Double) {
        let n = mvs.count
        guard n > 0 else { return (0, 0) }
        let sx = mvs.map { Double($0.x) }.sorted()
        let sy = mvs.map { Double($0.y) }.sorted()
        return (sx[n / 2] / 2.0, sy[n / 2] / 2.0) // half-pel -> px
    }
    func dispersion(_ mvs: [SIMD2<Int32>], dx: Double, dy: Double) -> Double {
        guard !mvs.isEmpty else { return 0 }
        let dev = mvs.map { abs(Double($0.x) / 2.0 - dx) + abs(Double($0.y) / 2.0 - dy) }.sorted()
        return dev[dev.count / 2]
    }
    func capture(_ mvs: [SIMD2<Int32>], dx: Double, dy: Double) -> Double {
        guard !mvs.isEmpty else { return 0 }
        var inRange = 0
        for m in mvs {
            let px = Double(m.x) / 2.0, py = Double(m.y) / 2.0
            if abs(px - dx) <= 3 && abs(py - dy) <= 3 { inRange += 1 }
        }
        return 100.0 * Double(inRange) / Double(mvs.count)
    }
    let rawL0 = engine.downloadMV(level: 0, smoothed: false)
    let smL0 = engine.downloadMV(level: 0, smoothed: true)
    let rawC = medianOffset(rawL0)
    let smC = medianOffset(smL0)
    print(String(format: "  dominant pan (median): raw=(%.1f, %.1f)px smoothed=(%.1f, %.1f)px",
                 rawC.dx, rawC.dy, smC.dx, smC.dy))
    print(String(format: "  L0 capture within +-3px: raw=%.1f%% smoothed=%.1f%%  dispersion(raw)=%.1fpx (smoothed)=%.1fpx",
                 capture(rawL0, dx: rawC.dx, dy: rawC.dy),
                 capture(smL0, dx: smC.dx, dy: smC.dy),
                 dispersion(rawL0, dx: rawC.dx, dy: rawC.dy),
                 dispersion(smL0, dx: smC.dx, dy: smC.dy)))
    var changed = 0
    for k in 0..<min(rawL0.count, smL0.count) where rawL0[k] != smL0[k] { changed += 1 }
    print(String(format: "  L0 blocks changed by median: %d/%d (%.1f%%)",
                 changed, rawL0.count, 100.0 * Double(changed) / Double(max(rawL0.count, 1))))
}

print("\nOK — MVProbe finished")