// MVProbe — measurement prototype for classic MCFI motion estimation
// (hierarchical block matching, MSL compute shaders) in Core/Interpolation.
//
// Usage:
//   swift run MVProbe [path/to/file.mkv]
//
// Env (optional):
//   MV_PAIRS   pairs to process  (default 120 ⇒ decodes 121 frames)
//    MV_LAMBDA  linear true-motion penalty per px (default 4)
//    MV_SUBPEL  0 disables half-pel refinement at L0 (default 1)
//    MV_DUMP    0 disables PNG/CSV export of pair 0 (default 1)
//    MV_TJITTER 1 dumps the smoothed L0 MV field for EVERY pair and prints
//               temporal-variance stats (same spatial block across consecutive
//               pairs) plus an EMA offline-smoothing simulation (default 0)
//    MV_TEMA    temporal EMA gate in px applied in-engine on the post-median L0
//               field (0 = off; 2 → gate 2px, the production default). When on,
//               the TJITTER report shows the gated-EMA field, not the raw one.
//    MV_TEMARESET_AT  pair index at which to call resetTemporalState() mid-run
//               to simulate a seek discontinuity with EMA active (-1 = never)
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

private func envDouble(_ key: String) -> Double? {
    guard let raw = ProcessInfo.processInfo.environment[key], let v = Double(raw) else { return nil }
    return v
}

let pairCount = envInt("MV_PAIRS", 120)
let lambdaPx = envInt("MV_LAMBDA", 4)
let subpelOn = envInt("MV_SUBPEL", 1) != 0
let dumpArtifacts = envInt("MV_DUMP", 1) != 0
let seekFraction = Double(envInt("MV_SEEK_PCT", 60)) / 100.0
let seekSecondsOverride = envDouble("MV_SEEK_SEC")
let dumpDir = "/tmp/rift_mvprobe"
let tjitOn = envInt("MV_TJITTER", 0) != 0
let tjitDir = ProcessInfo.processInfo.environment["MV_TJDIR"] ?? "/tmp/rift_tj"
let temporalGatePx = envInt("MV_TEMA", 0)
let tmaResetAt = envInt("MV_TEMARESET_AT", -1)

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

// MARK: - Geometry / attachment parity diagnostic (MV_GEOM)
//
// Diagnóstico del "pulso" de tamaño entre frames nativos e interpolados:
// compara dims, bytesPerRow y attachments (modos ShouldPropagate /
// ShouldNotPropagate) de I0, I1 y el buffer interpolado, y construye el
// CMVideoFormatDescription por el MISMO camino que HDRDisplayRenderer
// (CMVideoFormatDescriptionCreateForImageBuffer) para comparar la geometría
// que el AVSampleBufferDisplayLayer realmente usa para escalar cada frame.

private func pixFmtName(_ f: OSType) -> String {
    let c = f & 0xFFFFFFFF
    let b0 = UInt8((c >> 24) & 0xFF)
    let b1 = UInt8((c >> 16) & 0xFF)
    let b2 = UInt8((c >> 8) & 0xFF)
    let b3 = UInt8(c & 0xFF)
    let s = String(bytes: [b0, b1, b2, b3], encoding: .ascii) ?? "?"
    return s
}

private func pbInfo(_ pb: CVPixelBuffer) -> String {
    var s = "\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) fmt=\(pixFmtName(CVPixelBufferGetPixelFormatType(pb)))"
    let planes = CVPixelBufferGetPlaneCount(pb)
    s += " planes=\(planes)"
    if planes == 0 {
        s += " bpr=\(CVPixelBufferGetBytesPerRow(pb))"
    } else {
        for p in 0..<planes {
            s += " p\(p)=\(CVPixelBufferGetWidthOfPlane(pb, p))x\(CVPixelBufferGetHeightOfPlane(pb, p)) bpr=\(CVPixelBufferGetBytesPerRowOfPlane(pb, p))"
        }
    }
    return s
}

private func attachmentDict(_ pb: CVPixelBuffer, _ mode: CVAttachmentMode) -> [String: Any] {
    guard let d = CVBufferCopyAttachments(pb, mode) as NSDictionary? else { return [:] }
    var out: [String: Any] = [:]
    for (k, v) in d {
        if let key = k as? String { out[key] = v }
    }
    return out
}

private func fmtGeom(_ pb: CVPixelBuffer) -> (dims: String, exts: [String], clean: NSDictionary?, par: NSDictionary?) {
    var fmt: CMFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                       imageBuffer: pb,
                                                       formatDescriptionOut: &fmt) == noErr, let fmt else {
        return ("ERR", [], nil, nil)
    }
    let d = CMVideoFormatDescriptionGetDimensions(fmt)
    var extKeys: [String] = []
    if let exts = CMFormatDescriptionGetExtensions(fmt) as NSDictionary? {
        extKeys = exts.allKeys.compactMap { $0 as? String }.sorted()
    }
    let clean = CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_CleanAperture) as? NSDictionary
    let par = CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as? NSDictionary
    return ("\(d.width)x\(d.height)", extKeys, clean, par)
}

private func fullResLuma(_ pb: CVPixelBuffer) -> [UInt16]? {
    guard CVPixelBufferIsPlanar(pb), CVPixelBufferGetPlaneCount(pb) >= 1 else { return nil }
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidthOfPlane(pb, 0)
    let h = CVPixelBufferGetHeightOfPlane(pb, 0)
    let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
    var out = [UInt16](repeating: 0, count: w * h)
    out.withUnsafeMutableBufferPointer { buf in
        guard let dst = buf.baseAddress else { return }
        for y in 0..<h {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt16.self)
            for x in 0..<w { dst[y * w + x] = row[x] }
        }
    }
    return out
}

/// Registra la escala de `img` para que coincida con `ref` (mismo grid). Devuelve
/// el factor s que minimiza SAD(s) y el valor SAD en s=1.0 (relativo al de 1.0).
/// Sin movimiento (par estatico) el argmin es la escala real de `img` vs `ref`.
/// Muestreo bilinear + umbral de textura: solo contribuyen pixels con gradiente
/// local alto, asi el ajuste lo conducen bordes reales y no zonas planas.
/// Muestra el detalle de la curva SAD (fino 0.0001) y la escala exacta argmin
/// por interpolacion quadratica de los 3 vecinos. `img` se asume estatico vs `ref`.
private func scaleSADFine(_ ref: [UInt16], _ img: [UInt16], w: Int, h: Int, label: String) -> (best: Double, valleyRatio: Double) {
    let margin = max(2, min(w, h) / 50)
    var tex = [Bool](repeating: false, count: w * h)
    for y in 1..<(h - 1) {
        for x in 1..<(w - 1) {
            let i = y * w + x
            let gx = abs(Int(ref[i - 1]) - Int(ref[i + 1]))
            let gy = abs(Int(ref[i - w]) - Int(ref[i + w]))
            tex[i] = (gx + gy) > 48
        }
    }
    func sampleScaled(_ s: Double, _ x: Int, _ y: Int) -> Double {
        let dx = Double(x) / s
        let dy = Double(y) / s
        guard dx >= 0 && dx <= Double(w - 1), dy >= 0 && dy <= Double(h - 1) else { return -1 }
        let x0 = min(w - 2, max(0, Int(dx)))
        let y0 = min(h - 2, max(0, Int(dy)))
        let fx = dx - Double(x0)
        let fy = dy - Double(y0)
        let v00 = Double(img[y0 * w + x0])
        let v10 = Double(img[y0 * w + (x0 + 1)])
        let v01 = Double(img[(y0 + 1) * w + x0])
        let v11 = Double(img[(y0 + 1) * w + (x0 + 1)])
        return (v00 * (1 - fx) + v10 * fx) * (1 - fy) + (v01 * (1 - fx) + v11 * fx) * fy
    }
    let lo = 0.9975, hi = 1.0025, step = 0.0001
    var samples: [(s: Double, sad: Double)] = []
    for s in stride(from: lo, through: hi, by: step) {
        var acc: Double = 0
        var n = 0
        for y in margin..<(h - margin) {
            for x in margin..<(w - margin) {
                guard tex[y * w + x] else { continue }
                let tv = sampleScaled(s, x, y)
                if tv < 0 { continue }
                acc += abs(Double(ref[y * w + x]) - tv)
                n += 1
            }
        }
        if n > 0 { samples.append((s, acc / Double(n))) }
    }
    let minIdx = samples.enumerated().min { $0.element.sad < $1.element.sad }!.offset
    var best = samples[minIdx].s
    if minIdx >= 1 && minIdx < samples.count - 1 {
        let (s0, y0v) = (samples[minIdx - 1].s, samples[minIdx - 1].sad)
        let (s1, y1v) = (samples[minIdx].s, samples[minIdx].sad)
        let (s2, y2v) = (samples[minIdx + 1].s, samples[minIdx + 1].sad)
        let denom = y0v - 2 * y1v + y2v
        if abs(denom) > 1e-12 {
            best = s1 + 0.5 * step * (y0v - y2v) / denom
        }
    }
    let sadAt1 = samples.first(where: { abs($0.s - 1.0) < step * 0.6 })?.sad ?? samples[minIdx].sad
    print(String(format: "    %@: argmin=%.5f (quad)  SAD@argmin=%.2f  SAD@1.0=%.2f  ratio=%.4f",
                 label, best, samples[minIdx].sad, sadAt1, samples[minIdx].sad / max(sadAt1, 1e-9)))
    return (best, samples[minIdx].sad / max(sadAt1, 1e-9))
}

/// Registracion por bloques entera: campo de desplazamiento ref-vs-img por SAD.
/// Si el campo es constante (sin gradiente espacial) y x-var/y-var≈0, la fase del
/// round-trip es una traslacion pura y NO hay cambio de escala.
private func blockShiftField(_ ref: [UInt16], _ img: [UInt16], w: Int, h: Int, bs: Int = 48) -> (meanX: Double, meanY: Double, xSpread: Double, ySpread: Double, slopeX: Double, slopeY: Double, blocks: Int, textured: Int) {
    var ptsX: [(x: Double, dx: Double)] = []
    var ptsY: [(y: Double, dy: Double)] = []
    var blocks = 0
    for by in stride(from: 0, to: h - bs, by: bs) {
        for bx in stride(from: 0, to: w - bs, by: bs) {
            blocks += 1
            var tex = false
            var bestDx = 0, bestDy = 0, bestSad = Int.max
            for dy in -4...4 {
                for dx in -4...4 {
                    var acc: UInt64 = 0
                    for yy in 0..<bs {
                        let ry = by + yy, sy = by + yy + dy
                        if sy < 0 || sy >= h { acc = UInt64.max; break }
                        for xx in 0..<bs {
                            let rx = bx + xx, sx = bx + xx + dx
                            if sx < 0 || sx >= w { acc = UInt64.max; break }
                            let a = Int(ref[ry * w + rx])
                            let b = Int(img[sy * w + sx])
                            acc += UInt64(abs(a - b))
                            if ((xx + yy) % 31) == 0 { tex = tex || abs(a - b) >= 24 }
                        }
                    }
                    if !tex { tex = acc < UInt64(bs * bs * 48) }
                    if acc < UInt64(bestSad) { bestSad = Int(acc); bestDx = dx; bestDy = dy }
                }
            }
            if tex {
                ptsX.append((Double(bx + bs / 2), Double(bestDx)))
                ptsY.append((Double(by + bs / 2), Double(bestDy)))
            }
        }
    }
    guard !ptsX.isEmpty else { return (0, 0, 0, 0, 0, 0, blocks, 0) }
    func regress(_ pts: [(x: Double, v: Double)]) -> (mean: Double, spread: Double, slope: Double) {
        let n = Double(pts.count)
        var sx = 0.0, sv = 0.0, sxx = 0.0, sxv = 0.0
        for p in pts { sx += p.x; sv += p.v; sxx += p.x * p.x; sxv += p.x * p.v }
        let mean = sv / n
        let denom = sxx - sx * sx / n
        let slope = abs(denom) < 1e-9 ? 0.0 : (sxv - sx * sv / n) / denom
        let varv = pts.reduce(0.0) { $0 + pow($1.v - mean, 2) } / n
        return (mean, varv.squareRoot(), slope)
    }
    let rx = regress(ptsX.map { ($0.x, $0.dx) })
    let ry = regress(ptsY.map { ($0.y, $0.dy) })
    return (rx.mean, ry.mean, rx.spread, ry.spread, rx.slope, ry.slope, blocks, ptsX.count)
}

private func scaleSAD(_ ref: [UInt16], _ img: [UInt16], w: Int, h: Int) -> (best: Double, atOne: Double, sadAt1: Double) {
    let margin = max(2, min(w, h) / 50)
    // Mascara de textura: gradiente local (promedio |dX|+|dY| de 3 vecinos).
    var tex = [Bool](repeating: false, count: w * h)
    for y in 1..<(h - 1) {
        for x in 1..<(w - 1) {
            let i = y * w + x
            let gx = abs(Int(ref[i - 1]) - Int(ref[i + 1]))
            let gy = abs(Int(ref[i - w]) - Int(ref[i + w]))
            tex[i] = (gx + gy) > 48 // 10-bit luma (~0.2 del rango 0..1023)
        }
    }
    func sampleScaled(_ s: Double, _ x: Int, _ y: Int) -> Double {
        let dx = Double(x) / s
        let dy = Double(y) / s
        guard dx >= 0 && dx <= Double(w - 1), dy >= 0 && dy <= Double(h - 1) else { return -1 }
        let x0 = min(w - 2, max(0, Int(dx)))
        let y0 = min(h - 2, max(0, Int(dy)))
        let fx = dx - Double(x0)
        let fy = dy - Double(y0)
        let v00 = Double(img[y0 * w + x0])
        let v10 = Double(img[y0 * w + (x0 + 1)])
        let v01 = Double(img[(y0 + 1) * w + x0])
        let v11 = Double(img[(y0 + 1) * w + (x0 + 1)])
        return (v00 * (1 - fx) + v10 * fx) * (1 - fy) + (v01 * (1 - fx) + v11 * fx) * fy
    }
    var best = 1.0
    var bestSad = Double.infinity
    var sadBase = Double.infinity
    let count = Double(w * h)
    for s in stride(from: 0.996, through: 1.004, by: 0.001) {
        var acc: Double = 0
        var n = 0
        for y in margin..<(h - margin) {
            for x in margin..<(w - margin) {
                guard tex[y * w + x] else { continue }
                let tv = sampleScaled(s, x, y)
                if tv < 0 { continue }
                acc += abs(Double(ref[y * w + x]) - tv)
                n += 1
            }
        }
        let mean = n > 0 ? acc / Double(n) : Double.infinity
        if s == 1.0 { sadBase = mean }
        if mean < bestSad { bestSad = mean; best = s }
    }
    _ = count
    return (best, bestSad / max(sadBase, 1e-9), sadBase)
}

private func dumpGeomDiagnostic(I0: CVPixelBuffer, I1: CVPixelBuffer, interp: CVPixelBuffer) {
    print("\n=== MV_GEOM: geometry parity native vs interpolated (pair 0) ===")
    print("I0      : \(pbInfo(I0))")
    print("I1      : \(pbInfo(I1))")
    print("interp  : \(pbInfo(interp))")

    let propOf = attachmentDict(I0, CVAttachmentMode.shouldPropagate)
    let nonPropNative = attachmentDict(I0, CVAttachmentMode.shouldNotPropagate)
    let propInterp = attachmentDict(interp, CVAttachmentMode.shouldPropagate)
    let nonPropInterp = attachmentDict(interp, CVAttachmentMode.shouldNotPropagate)
    let propI1 = attachmentDict(I1, CVAttachmentMode.shouldPropagate)
    let nonPropI1 = attachmentDict(I1, CVAttachmentMode.shouldNotPropagate)

    func listKeys(_ label: String, _ d: [String: Any]) {
        let keys = d.keys.sorted()
        print("  \(label): \(keys.isEmpty ? "(none)" : keys.joined(separator: ", "))")
    }
    print("-- attachments --")
    listKeys("I0   prop", propOf)
    listKeys("I0   nonP", nonPropNative)
    listKeys("I1   prop", propI1)
    listKeys("I1   nonP", nonPropI1)
    listKeys("inter prop", propInterp)
    listKeys("inter nonP", nonPropInterp)

    var allNative: [String: Any] = propOf
    for (k, v) in nonPropNative where allNative[k] == nil { allNative[k] = v }
    var allInterp: [String: Any] = propInterp
    for (k, v) in nonPropInterp where allInterp[k] == nil { allInterp[k] = v }

    var missingInInterp: [String] = []
    var modeMismatch: [String] = []
    for (k, nativeVal) in allNative {
        if let interpVal = allInterp[k] {
            let nativeProp = propOf[k] != nil
            let interpProp = propInterp[k] != nil
            if nativeProp != interpProp { modeMismatch.append("\(k) (nativo:\(nativeProp ? "prop" : "nonP") vs interp:\(interpProp ? "prop" : "nonP"))") }
            let nv = String(describing: nativeVal)
            let iv = String(describing: interpVal)
            if nv != iv { print("  DIFF value \(k): nativo=\(nv) interp=\(iv)") }
        } else {
            missingInInterp.append(k)
        }
    }
    var extraInInterp: [String] = []
    for k in allInterp.keys where allNative[k] == nil { extraInInterp.append(k) }
    if !missingInInterp.isEmpty { print("  FALTAN en interp (presentes en I0): \(missingInInterp.sorted().joined(separator: ", "))") }
    if !extraInInterp.isEmpty { print("  EXTRA en interp (ausentes en I0): \(extraInInterp.sorted().joined(separator: ", "))") }
    if !modeMismatch.isEmpty { print("  MODO distinto: \(modeMismatch.joined(separator: "; "))") }
    if missingInInterp.isEmpty && extraInInterp.isEmpty && modeMismatch.isEmpty {
        print("  attachments: conjuntos de claves identicos entre I0 e interp")
    }

    print("-- format description (via renderer path: CMVideoFormatDescriptionCreateForImageBuffer) --")
    for (label, pb) in [("I0", I0), ("I1", I1), ("interp", interp)] {
        let g = fmtGeom(pb)
        let cleanStr = g.clean?.description ?? "-"
        let parStr = g.par?.description ?? "-"
        print("  \(label): dims=\(g.dims)")
        print("    cleanAperture = \(cleanStr)")
        print("    pixelAspectRatio = \(parStr)")
        let geomKeys = g.exts.filter { $0.contains("Aperture") || $0.contains("Aspect") || $0.contains("Display") || $0.contains("Field") }
        if geomKeys.isEmpty { print("    extensiones de geometria: (ninguna)") }
        else { print("    extensiones de geometria: \(geomKeys.joined(separator: ", "))") }
    }
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

let seekTime = seekSecondsOverride ?? info.duration * seekFraction
do {
    try demuxer.seek(to: seekTime)
    decoder.flush()
} catch {
    print("WARNING: seek failed, decoding from start — \(error)")
}
print(String(format: "decoding from %.2f s (≈%.0f%%) until %d luma planes are ready…",
             seekTime, seekTime / max(info.duration, 1e-6) * 100.0, pairCount + 1))

var frames: [Data] = []
var frameBuffers: [CVPixelBuffer] = []
var readPackets = 0
while frames.count < pairCount + 1 && readPackets < 100_000 {
    guard let packet = try? demuxer.nextPacket() else { break }
    readPackets += 1
    guard packet.streamIndex == video.streamIndex else { continue }
    guard let buf = try? decoder.decodeFrame(packet) else { continue }
    guard let luma = scaledLuma(buf) else { continue }
    frames.append(luma)
    frameBuffers.append(buf)
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
        gateL0: envInt("MV_GATE", 1) == 1,
        temporalGatePx: UInt32(temporalGatePx)
    )
} catch {
    print("ENGINE INIT FAILED: \(error)")
    exit(3)
}
let warpEngine: WarpEngine
do {
    guard MTLCreateSystemDefaultDevice() != nil else { print("WARP INIT FAILED: no Metal device"); exit(3) }
    warpEngine = try WarpEngine(msl: warpShadersMSL)
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
// Warp-vs-copy discriminator (MV_WARPCOPY=1): sobre bloques con |MV|>0.5px,
// el warp t=0.5 es "genuino" si SAD(interp,I0) < SAD(I0,I1) Y SAD(interp,I1) <
// SAD(I0,I1) — un frame intermedio real queda estrictamente entre sus inputs,
// mientras que una copia no puede mejorar respecto a ambos a la vez.
// NOTA: con static-copy en el warp, los bloques copiados fallan el criterio
// estricto por construccion (SAD(interp,I1)==SAD(I0,I1)); por eso tambien se
// mide "no-peor" sobre TODOS los bloques: SAD(interp,I0)+SAD(interp,I1) <=
// SAD(I0,I1) — el interpolado no introduce mas error que repetir un input.
var wcMoving = 0
var wcGenuine = 0
var wcAll = 0
var wcNoWorse = 0
let wcOn = envInt("MV_WARPCOPY", 1) == 1
// Temporal-jitter collection: smoothed L0 field of every pair, kept in memory
// and (optionally) dumped as CSVs so the same 8640 blocks can be compared
// across consecutive pairs (MV_TJITTER=1).
var tjFields: [[SIMD2<Int32>]] = []
var tjW = 0
var tjH = 0
if tjitOn {
    try? FileManager.default.createDirectory(atPath: tjitDir, withIntermediateDirectories: true)
}

print("\n--- measuring \(pairCount) pairs @ \(workWidth)x\(workHeight) ---")
if temporalGatePx > 0 {
    print(String(format: "temporal EMA gating ON (gate %d px on post-median L0; reset at pair %d)",
                 temporalGatePx, tmaResetAt))
}
for i in 0..<pairCount {
    if i == tmaResetAt {
        engine.resetTemporalState()
        print("MV_TEMARESET_AT: temporal state reset before pair \(i + 1) (EMA starts clean)")
    }
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

    if tjitOn {
        let sm = engine.downloadMV(level: 0)
        if tjW == 0 { tjW = engine.grids[0].w; tjH = engine.grids[0].h }
        tjFields.append(sm)
        let tm = Int(Date().timeIntervalSince1970 * 1000) % 1000000
        writeMVCSV(sm, gridW: tjW, gridH: tjH, path: "\(tjitDir)/mv_pair\(i)_t\(tm).csv")
    }

    var diff: UInt64 = 0
    for k in 0..<measurePlaneCount {
        let a = UInt64(cur[k])
        let b = UInt64(ref[k])
        diff += a >= b ? a - b : b - a
    }
    let mad = Double(diff) / Double(measurePlaneCount)
    madSum += mad
    if mad > madMax { madMax = mad }

    // Textured-MAD calibration (MV_TEXMAD=1, pair 0): mean |I0-I1| over pixels
    // whose local gradient in I0 exceeds a threshold (10-bit work-plane units),
    // at several thresholds + textured fractions. Calibrates a texture-gated
    // static-skip gate (global MAD misfires on dark/low-contrast motion).
    if envInt("MV_TEXMAD", 0) == 1 && i == 0 {
        for thr in [12, 24, 48] {
            var acc: UInt64 = 0
            var n = 0
            for y in 1..<(workHeight - 1) {
                for x in 1..<(workWidth - 1) {
                    let c = Int(cur[y * workWidth + x])
                    let gx = abs(c - Int(cur[y * workWidth + (x - 1)])) + abs(Int(cur[y * workWidth + (x + 1)]) - c)
                    let gy = abs(c - Int(cur[(y - 1) * workWidth + x])) + abs(Int(cur[(y + 1) * workWidth + x]) - c)
                    if gx + gy > thr {
                        let a = Int(cur[y * workWidth + x])
                        let b = Int(ref[y * workWidth + x])
                        acc += UInt64(a >= b ? a - b : b - a)
                        n += 1
                    }
                }
            }
            print(String(format: "  TEXMAD thr>%d: textured=%.2f%% meanDiff=%.2f", thr,
                         100.0 * Double(n) / Double(measurePlaneCount),
                         n > 0 ? Double(acc) / Double(n) : 0.0))
        }
    }

    // Warp/blend at t=0.5 (OBMC omitted v1 — known limitation, see header)
    let mvForWarp = engine.downloadMV(level: 0)
    let (interpPlane, warpMS) = warpEngine.interpolate(I0: cur, I1: ref, mv: mvForWarp, width: workWidth, height: workHeight, gridW: measureGW, gridH: measureGH, blockSize: measureBS, t: 0.5)
    warpTotal.append(warpMS)

    if wcOn {
        let g0 = measureGW
        for by in 0..<measureGH {
            for bx in 0..<g0 {
                let m = mvForWarp[by * g0 + bx]
                let magPx = (Double(m.x) * Double(m.x) + Double(m.y) * Double(m.y)).squareRoot() / 2.0
                if magPx <= 0.5 { continue }
                var sI0: UInt64 = 0
                var sI1: UInt64 = 0
                var s01: UInt64 = 0
                for y in 0..<measureBS {
                    for x in 0..<measureBS {
                        let iy = by * measureBS + y
                        let ix = bx * measureBS + x
                        let vI = UInt64(interpPlane[iy * workWidth + ix])
                        let v0 = UInt64(cur[iy * workWidth + ix])
                        let v1 = UInt64(ref[iy * workWidth + ix])
                        func absd(_ a: UInt64, _ b: UInt64) -> UInt64 { a >= b ? a - b : b - a }
                        sI0 += absd(vI, v0)
                        sI1 += absd(vI, v1)
                        s01 += absd(v0, v1)
                    }
                }
                wcMoving += 1
                if sI0 < s01 && sI1 < s01 { wcGenuine += 1 }
            }
        }
        // Bypass-aware: sobre TODOS los bloques (incluye |MV|<=0.5px y copias),
        // el interpolado "no empeora" si su error total a ambos inputs no supera
        // el de repetir un frame (SAD(I0,I1)).
        if wcOn {
            let g0 = measureGW
            for by in 0..<measureGH {
                for bx in 0..<g0 {
                    var sI0: UInt64 = 0
                    var sI1: UInt64 = 0
                    var s01: UInt64 = 0
                    for y in 0..<measureBS {
                        for x in 0..<measureBS {
                            let iy = by * measureBS + y
                            let ix = bx * measureBS + x
                            let vI = UInt64(interpPlane[iy * workWidth + ix])
                            let v0 = UInt64(cur[iy * workWidth + ix])
                            let v1 = UInt64(ref[iy * workWidth + ix])
                            func absd(_ a: UInt64, _ b: UInt64) -> UInt64 { a >= b ? a - b : b - a }
                            sI0 += absd(vI, v0)
                            sI1 += absd(vI, v1)
                            s01 += absd(v0, v1)
                        }
                    }
                    wcAll += 1
                    if sI0 + sI1 <= s01 { wcNoWorse += 1 }
                }
            }
        }
    }

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

if tjitOn && tjFields.count >= 2 {
    print("\n--- temporal jitter: smoothed L0 MV across \(tjFields.count) consecutive pairs ---")
    func seriesStats(_ series: [SIMD2<Int32>], skipFirst: Int) -> (sig: Double, tstd: Double) {
        let xs = series.dropFirst(skipFirst).map { Double($0.x) / 2.0 }
        let ys = series.dropFirst(skipFirst).map { Double($0.y) / 2.0 }
        let mx = xs.reduce(0, +) / Double(xs.count)
        let my = ys.reduce(0, +) / Double(ys.count)
        var vx = 0.0, vy = 0.0, mag = 0.0
        for k in 0..<xs.count {
            vx += (xs[k] - mx) * (xs[k] - mx)
            vy += (ys[k] - my) * (ys[k] - my)
            mag += (xs[k] * xs[k] + ys[k] * ys[k]).squareRoot()
        }
        return ((mag / Double(xs.count)), (vx + vy).squareRoot() / Double(xs.count))
    }
    let g = tjFields[0].count
    var moving = 0
    var staticB = 0
    var rawTstd: [Double] = []
    var rawTstd2: [Double] = []
    var emaTstd: [Double] = []
    var emaTstd25: [Double] = []
    var emaTstd50: [Double] = []
    var consecDelta: [Double] = []
    var consecDeltaMax: [Double] = []
    var flicker = 0
    var flickerTot = 0
    var emaA: [Double] = []
    for bx in 0..<g {
        let series = tjFields.map { $0[bx] }
        let raw = seriesStats(series, skipFirst: 0)
        let rawSteady = seriesStats(series, skipFirst: 1)
        if raw.sig >= 3.0 { moving += 1 } else if raw.sig < 1.0 { staticB += 1 }
        if raw.sig >= 3.0 {
            rawTstd.append(raw.tstd)
            rawTstd2.append(rawSteady.tstd)
            var deltas: [Double] = []
            for i in 1..<series.count {
                let d = (Double(series[i].x - series[i - 1].x) * Double(series[i].x - series[i - 1].x)
                    + Double(series[i].y - series[i - 1].y) * Double(series[i].y - series[i - 1].y)).squareRoot() / 2.0
                deltas.append(d)
                if raw.sig >= 3.0 { consecDelta.append(d) }
            }
            consecDeltaMax.append(deltas.max() ?? 0)
            var on = 0
            for v in series where (Double(v.x) * Double(v.x) + Double(v.y) * Double(v.y)).squareRoot() / 2.0 >= 2.0 { on += 1 }
            if Double(on) < Double(series.count) * 0.75 { flicker += 1 }
            flickerTot += 1
        }
        for alpha in [0.5, 0.75, 0.9] where temporalGatePx == 0 {
            var emaX = 0.0, emaY = 0.0
            var stored: [SIMD2<Int32>] = []
            for v in series {
                let px = Double(v.x) / 2.0
                let py = Double(v.y) / 2.0
                if stored.isEmpty { emaX = px; emaY = py } else { emaX = alpha * px + (1 - alpha) * emaX; emaY = alpha * py + (1 - alpha) * emaY }
                stored.append(SIMD2<Int32>(Int32(emaX * 2), Int32(emaY * 2)))
            }
            let ema = seriesStats(stored, skipFirst: 1)
            if alpha == 0.5 { emaTstd.append(ema.tstd) }
            if alpha == 0.75 { emaTstd25.append(ema.tstd) }
            if alpha == 0.9 { emaTstd50.append(ema.tstd) }
        }
        _ = rawSteady
    }
    func pct(_ a: [Double], _ q: Double) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        return s[min(max(Int((Double(s.count - 1)) * q), 0), s.count - 1)]
    }
    func overFrac(_ a: [Double], _ th: Double) -> Double {
        guard !a.isEmpty else { return 0 }
        return 100.0 * Double(a.filter { $0 > th }.count) / Double(a.count)
    }
    print("  blocks: moving(|MV|≥3px)=\(moving) near-static(<1px)=\(staticB) of \(g)")
    let fieldLabel = temporalGatePx > 0 ? "EMA(gate \(temporalGatePx)px) field" : "RAW"
    if !rawTstd.isEmpty {
        print(String(format: "  %@ temporal std (px), on moving blocks: p50=%.2f p90=%.2f p99=%.2f | >1px=%.1f%% >2px=%.1f%% >4px=%.1f%%",
                     fieldLabel as NSString,
                     pct(rawTstd, 0.5), pct(rawTstd, 0.9), pct(rawTstd, 0.99),
                     overFrac(rawTstd, 1), overFrac(rawTstd, 2), overFrac(rawTstd, 4)))
        print(String(format: "  %@ steady-state std (pairs 1..N-1), moving: p50=%.2f p90=%.2f | >2px=%.1f%%",
                     fieldLabel as NSString,
                     pct(rawTstd2, 0.5), pct(rawTstd2, 0.9), overFrac(rawTstd2, 2)))
        print(String(format: "  consecutive-pair |dMV| (px), moving blocks: mean=%.2f p90=%.2f | per-block max: p90=%.2f",
                     (consecDelta.reduce(0, +) / Double(max(consecDelta.count, 1))),
                     pct(consecDelta, 0.9), pct(consecDeltaMax, 0.9)))
        print(String(format: "  flicker (has real MV but <75%% of pairs with |MV|≥2px): %d/%d (%.1f%%)",
                     flicker, flickerTot, 100.0 * Double(flicker) / Double(max(flickerTot, 1))))
        if temporalGatePx == 0 {
            print(String(format: "  EMA sim steady approx (offline, α=0.50/0.75/0.90), std on moving: p50=%.2f/%.2f/%.2f >2px=%.1f%%/%.1f%%/%.1f%%",
                         pct(emaTstd, 0.5), pct(emaTstd25, 0.5), pct(emaTstd50, 0.5),
                         overFrac(emaTstd, 2), overFrac(emaTstd25, 2), overFrac(emaTstd50, 2)))
        }
        _ = emaA
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

// --- Pipeline real: MotionCompensator sobre CVPixelBuffer full-res ---
// Mide el flujo de producción tal cual lo usa la UI: la luma se extrae y se baja
// a work-plane en host (MotionCompensator.scaledLuma), el ME corre en work-plane,
// el warp corrido AHORA en work-plane, y el upscale bilinear sube el luma a la
// resolución nativa del CVPixelBuffer de salida. CbCr se copia de I0 y los
// attachments HDR se propagan. Desglose ME / Warp / Upscale por par.
if envInt("MV_PIPELINE", 1) == 1 && frameBuffers.count >= pairCount + 1 {
    let mc: MotionCompensator
    do {
        mc = try MotionCompensator(config: .default)
    } catch {
        print("PIPELINE INIT FAILED: \(error)")
        print("\nOK — MVProbe finished (pipeline skipped)")
        exit(3)
    }
    var pipelineME: [Double] = []
    var pipelineWarp: [Double] = []
    var pipelineUpscale: [Double] = []
    var pipelineTotal: [Double] = []
    print("\n--- pipeline real (MotionCompensator, full-res CVPixelBuffer, warp work-plane + upscale) ---")
    for i in 0..<pairCount {
        let s = DispatchTime.now().uptimeNanoseconds
        let r = mc.interpolateWithTimings(I0: frameBuffers[i], I1: frameBuffers[i + 1], t: 0.5)
        let tot = Double(DispatchTime.now().uptimeNanoseconds - s) / 1_000_000.0
        pipelineME.append(r.meMS)
        pipelineWarp.append(r.warpMS)
        pipelineUpscale.append(r.upscaleMS)
        pipelineTotal.append(tot)
        print(String(format: "  pipeline %4d: ME %.3f + Warp %.3f + Upscale %.3f = %.3f ms (pb %@)",
                     i + 1, r.meMS, r.warpMS, r.upscaleMS, tot,
                     r.pixelBuffer != nil ? "ok" : "NIL"))
        // MV_GEOM: diagnostico de geometria/attachments en el par 0 con el mismo
        // fast-path que usa la UI (interpolatePair tValues=[0.5]).
        if envInt("MV_GEOM", 0) == 1 && i == 0, let rpb = r.pixelBuffer {
            var gpb: CVPixelBuffer?
            let gp = mc.interpolatePair(I0: frameBuffers[i], I1: frameBuffers[i + 1], tValues: [0.5])
            if let first = gp.pixelBuffers.first { gpb = first }
            dumpGeomDiagnostic(I0: frameBuffers[i], I1: frameBuffers[i + 1], interp: gpb ?? rpb)

            // Escala de CONTENIDO del camino pipeline completo, libre de movimiento:
            // par estatico sintetico (I0→I0) → el round-trip debe reproducir I0 a
            // escala exacta. Cualquier desvio = zoom introducido por el pipeline.
            if let staticPB = mc.interpolatePair(I0: frameBuffers[i], I1: frameBuffers[i], tValues: [0.5]).pixelBuffers.first,
               let ref = fullResLuma(frameBuffers[i]),
               let staticL = fullResLuma(staticPB),
               let interpL = fullResLuma(gpb ?? rpb) {
                let w = CVPixelBufferGetWidth(frameBuffers[i])
                let h = CVPixelBufferGetHeight(frameBuffers[i])
                let sSelf = scaleSAD(ref, staticL, w: w, h: h)
                let sInterp = scaleSAD(ref, interpL, w: w, h: h)
                let sIdent = scaleSAD(ref, ref, w: w, h: h)
                print(String(format: "MV_GEOM content-scale (full-res luma, bilinear, texture-gated, SAD argmin 0.996..1.004):"))
                print(String(format: "  CALIBRACION identidad ref-vs-ref (esperado 1.000): best=%.4f ratioSAD=%.4f",
                             sIdent.best, sIdent.atOne))
                print(String(format: "  static self-pair I0->I0: bestScale=%.4f  SAD@best/SAD@1=%.4f  SAD@1=%.1f  \(abs(sSelf.best - 1.0) < 0.001 ? "→ escala 1.000 (sin zoom del pipeline)" : "→ ¡DESVIO!")",
                             sSelf.best, sSelf.atOne, sSelf.sadAt1))
                print(String(format: "  real pair I0->I1 @0.5    : bestScale=%.4f  SAD@best/SAD@1=%.4f  (contiene movimiento real, no es escala pura)",
                             sInterp.best, sInterp.atOne))
                // Curva fina + calibracion sintetica: si la curva fina del self-pair
                // marca un valle real fuera de 1.000, cuantificarlo con precision.
                _ = scaleSADFine(ref, ref, w: w, h: h, label: "IDENTIDAD")
                let fineSelf = scaleSADFine(ref, staticL, w: w, h: h, label: "SELF-PAIR")
                // Validar el estimador: escalar ref sinteticamente a 0.9990 y ver si
                // escalaSAD lo recupera (debe dar ≈0.999).
                if fineSelf.best < 0.9995 || fineSelf.best > 1.0005 {
                    var synth = [UInt16](repeating: 0, count: w * h)
                    for y in 0..<h {
                        let sy = min(h - 1, Int(Double(y) / 0.9990))
                        for x in 0..<w {
                            let sx = min(w - 1, Int(Double(x) / 0.9990))
                            synth[y * w + x] = staticL[sy * w + sx]
                        }
                    }
                    let sSynth = scaleSAD(ref, synth, w: w, h: h)
                    print(String(format: "  VALIDACION estimador: ref sintetizado a 0.9990 → estimado=%.4f (debe ≈0.999)", sSynth.best))
                }
                // Campo de desplazamiento self-pair: si es constante → traslacion pura
                // (escala 1.0). Si tiene gradiente (spread alto / tendencia bx→dx),
                // habria zoom real.
                let sf = blockShiftField(ref, staticL, w: w, h: h)
                print(String(format: "  BLOQUES self-pair: mean(dx,dy)=(%.2f, %.2f)  spread=(%.2f, %.2f)  slope(dx/bx, dy/by)=(%.5f, %.5f)  %d/%d texturizados",
                             sf.meanX, sf.meanY, sf.xSpread, sf.ySpread, sf.slopeX, sf.slopeY, sf.textured, sf.blocks))
                if abs(sf.slopeX) < 0.002 && abs(sf.slopeY) < 0.002 {
                    print(String(format: "  → campo de desplazamiento constante (spread ~±%.1fpx), NO hay gradiente → traslacion sub-pixel, escala = 1.000", max(sf.xSpread, sf.ySpread)))
                } else {
                    print("  → ¡pendiente no nula! zoom real posible")
                }
                // Dump visual (MV_DUMP=1): ref, roundtrip estatico y diff escalada.
                // Antes del fix de fase el diff muestra halos ~1.7px en bordes
                // (la traslacion del contenido); despues debe quedar ~negro.
                if envInt("MV_DUMP", 1) == 1 {
                    try? FileManager.default.createDirectory(atPath: dumpDir, withIntermediateDirectories: true)
                    let grayRef = ref.map { UInt8(min(255, Int($0 >> 2))) }
                    let grayStatic = staticL.map { UInt8(min(255, Int($0 >> 2))) }
                    _ = writeGrayPNG(grayRef, width: w, height: h, to: "\(dumpDir)/geom_static_ref.png")
                    _ = writeGrayPNG(grayStatic, width: w, height: h, to: "\(dumpDir)/geom_static_roundtrip.png")
                    var diff = [UInt8](repeating: 0, count: w * h)
                    for i in 0..<(w * h) {
                        let a = Int(ref[i])
                        let b = Int(staticL[i])
                        let d = a >= b ? a - b : b - a
                        diff[i] = UInt8(min(255, (d >> 2) * 4))
                    }
                    _ = writeGrayPNG(diff, width: w, height: h, to: "\(dumpDir)/geom_static_diff.png")
                    print("  dumps: \(dumpDir)/geom_static_{ref,roundtrip,diff}.png")
                }
            }
        }
    }
    let pME = stats(pipelineME)
    let pWarp = stats(pipelineWarp)
    let pUp = stats(pipelineUpscale)
    let pTot = stats(pipelineTotal)
    let pCombined = pME.mean + pWarp.mean + pUp.mean
    print("\n--- pipeline real per-pair timings (ms) ---")
    print(String(format: "  %-12@ %10@ %10@ %10@", "stage" as NSString, "mean" as NSString, "p50" as NSString, "p95" as NSString))
    print(String(format: "  %-12@ %10.3f %10.3f %10.3f", "ME" as NSString, pME.mean, pME.p50, pME.p95))
    print(String(format: "  %-12@ %10.3f %10.3f %10.3f", "Warp" as NSString, pWarp.mean, pWarp.p50, pWarp.p95))
    print(String(format: "  %-12@ %10.3f %10.3f %10.3f", "Upscale" as NSString, pUp.mean, pUp.p50, pUp.p95))
    print(String(format: "  %-12@ %10.3f %10.3f %10.3f", "Total(host)" as NSString, pTot.mean, pTot.p50, pTot.p95))
    print(String(format: "  Comb ME+Warp+Up : mean=%.3f ms (%.1f%% of 41.7ms budget) — margen %.1f ms %@",
                 pCombined, pCombined / 41.7 * 100.0, 41.7 - pCombined,
                 pCombined <= 41.7 ? "dentro" : "EXCEDE"))
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
if wcOn {
    print(String(format: "\nwarp-vs-copy (MV_WARPCOPY): %d de %d bloques en movimiento (%d pares) con warp genuino "
                 + "(SAD(interp,I0)<SAD(I0,I1) y SAD(interp,I1)<SAD(I0,I1)) = %.1f%%",
                 wcGenuine, wcMoving, pairCount,
                 wcMoving > 0 ? 100.0 * Double(wcGenuine) / Double(wcMoving) : 0.0))
    print(String(format: "warp-no-peor (bypass-aware, TODOS los bloques): %d de %d (%d pares) con "
                 + "SAD(interp,I0)+SAD(interp,I1)<=SAD(I0,I1) = %.1f%%",
                 wcNoWorse, wcAll, pairCount,
                 wcAll > 0 ? 100.0 * Double(wcNoWorse) / Double(wcAll) : 0.0))
}

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