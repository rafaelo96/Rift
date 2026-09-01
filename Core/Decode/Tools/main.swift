// DecodeProbe — standalone validation tool for Core/Decode.
//
// Usage:
//   swift run DecodeProbe [path/to/file.mkv]
//
// Validates the measurable success criteria of Core/Decode:
//   - a static frame decodes correctly and is dumped to PNG for visual check
//   - decode time per frame is reported (hardware vs software reasoning)
//   - HDR color attachments (color_trc / color_primaries) survive on the buffer
//
// Depends only on Core/Demux (consumed as-is) and Core/Decode — no UI/,
// no Contracts/.

import Foundation
import CoreVideo
import CoreMedia
import VideoToolbox
import Demux
import Decode
import CoreImage
import ImageIO
import Accelerate

let defaultPath = "/Users/rafael/Downloads/Avatar.Aang.el.ultimo.maestro.del.aire.2026.WEB-DL.4k.HDR-Dual-Lat.mkv"
let outputToneMappedPNG = "/tmp/rift_decode_frame0_tone.png"

private func elapsedMilliseconds(from start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
}

private func dumpBufferMetadata(_ buffer: CVPixelBuffer) {
    let format = CVPixelBufferGetPixelFormatType(buffer)
    let fourCC = String(
        bytes: [UInt8(format & 0xFF), UInt8((format >> 8) & 0xFF),
                UInt8((format >> 16) & 0xFF), UInt8((format >> 24) & 0xFF)],
        encoding: .ascii) ?? "?"
    print("  buffer: \(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) "
        + "format=\(fourCC) (0x\(String(format: "%08x", format)))")
    for key in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey] {
        if let attachment = CVBufferCopyAttachment(buffer, key, nil) {
            print("  attachment \(key as CFString): \(attachment)")
        }
    }
}

/// Reports raw luma/chroma sample values (normalized 0-1) so we can tell
/// whether the decoded buffer is genuinely black or the PNG dump was at fault.
private func dumpPlaneStats(_ buffer: CVPixelBuffer, label: String, sampleRegions: Bool = false) {
    guard CVPixelBufferIsPlanar(buffer) else { return }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let planeCount = CVPixelBufferGetPlaneCount(buffer)
    for p in 0..<planeCount {
        let w = CVPixelBufferGetWidthOfPlane(buffer, p)
        let h = CVPixelBufferGetHeightOfPlane(buffer, p)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, p)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, p) else { continue }
        var minV: UInt16 = 0xFFFF
        var maxV: UInt16 = 0
        var sum: Double = 0
        var count: Double = 0
        var distinct = Set<UInt16>()
        for row in 0..<h {
            let rowPtr = base.advanced(by: row * bpr).assumingMemoryBound(to: UInt16.self)
            for col in 0..<w {
                // 420YpCbCr10BiPlanar stores each 10-bit sample in the HIGH
                // bits of a 16-bit word; shift down to recover the real value.
                let v10 = rowPtr[col] >> 6
                distinct.insert(v10)
                if v10 < minV { minV = v10 }
                if v10 > maxV { maxV = v10 }
                sum += Double(v10)
                count += 1
            }
        }
        print(String(format: "  [%@] plane[%d] %dx%d: min=%.3f max=%.3f mean=%.3f distinct=%d",
                     label, p, w, h,
                     Double(minV) / 1023.0, Double(maxV) / 1023.0, sum / count / 1023.0,
                     distinct.count))
        if sampleRegions && p == 0 && h > 4 && w > 4 {
            // Sample 4 corners + center to show spatial variation within the frame.
            func px(_ x: Int, _ y: Int) -> UInt16 {
                base.advanced(by: y * bpr).assumingMemoryBound(to: UInt16.self)[x] >> 6
            }
            let xs = [0, w / 2, w - 1]
            let ys = [0, h / 2, h - 1]
            for y in ys {
                var row = "    "
                for x in xs {
                    row += String(format: "(\(x),\(y))=%6.3f ", Double(px(x, y)) / 1023.0)
                }
                print(row)
            }
        }
    }
}

/// Saves a HDR (PQ) pixel buffer as a viewable sRGB PNG. The buffer is decoded
/// as PQ/BT.2020 10-bit; forcing it through a plain sRGB working space yields a
/// near-black image, so we create the Core Image context with a linear P3
/// working space and let Core Image run its automatic PQ tone-mapping.
private func saveHDRtoPNG(_ pixelBuffer: CVPixelBuffer, to url: URL) -> Bool {
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    let linearP3 = CGColorSpace(name: CGColorSpace.linearDisplayP3)!
    let context = CIContext(options: [
        .workingColorSpace: linearP3,
        .outputColorSpace: sRGB,
    ])
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    guard let cgImage = context.createCGImage(
        image, from: image.extent, format: .RGBA8, colorSpace: sRGB) else {
        return false
    }
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(destination, cgImage, nil)
    return CGImageDestinationFinalize(destination)
}

// MARK: - Main probe

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultPath
print("=== DecodeProbe ===")
print("file : \(path)")

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
print("video: \(video.width ?? 0)x\(video.height ?? 0) \(video.codecName) "
    + "ct=\(video.colorTransfer.map(String.init) ?? "-") "
    + "cp=\(video.colorPrimaries.map(String.init) ?? "-")")
print(String(format: "extradata : %d bytes (hvcC)", video.codecExtradata.count))
print("VT hardware decode supported (HEVC): \(VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC))")

let decoder = VTDecoder()
do {
    try decoder.prepare(track: video)
} catch {
    print("PREPARE FAILED: \(error)")
    exit(1)
}

print("\n--- decoding video packets (one at a time) ---")
// This WEB-DL begins with a solid-black leader frame, so kick off near the
// middle of the file where real content lives (proves real decode, and lets
// the summary compare black vs. content).
let startTime = info.duration / 3.0
do {
    try demuxer.seek(to: startTime)
    decoder.flush()
} catch {
    print("SEEK FAILED: \(error)")
}
print(String(format: "seeking to %.2f s (≈1/3) then decoding…", startTime))
var decoded = 0
var totalMs = 0.0
var readPackets = 0
while decoded < 10 && readPackets < 500 {
    guard let packet = try? demuxer.nextPacket() else { break }
    readPackets += 1
    guard packet.streamIndex == video.streamIndex else { continue }

    let start = DispatchTime.now().uptimeNanoseconds
    let buffer: CVPixelBuffer?
    do {
        buffer = try decoder.decodeFrame(packet)
    } catch {
        print("DECODE FAILED at packet \(readPackets): \(error)")
        break
    }
    let ms = elapsedMilliseconds(from: start)

    guard let buffer else { continue }
    decoded += 1
    totalMs += ms
    print(String(format: "  video frame %2d decoded in %7.2f ms (keyframe=%@)",
                 decoded, ms, packet.isKeyframe ? "yes" : "no"))
    if !video.codecExtradata.isEmpty && decoded == 1 {
        dumpBufferMetadata(buffer)
        dumpPlaneStats(buffer, label: "frame 1", sampleRegions: true)
        if saveHDRtoPNG(buffer, to: URL(fileURLWithPath: outputToneMappedPNG)) {
            print("  saved tone-mapped PNG: \(outputToneMappedPNG)")
        } else {
            print("  WARNING: could not write tone-mapped PNG")
        }
    } else if decoded == 3 {
        dumpPlaneStats(buffer, label: "frame 3")
    } else if decoded == 5 {
        dumpPlaneStats(buffer, label: "frame 5")
    }
}

if decoded > 0 {
    print(String(format: "\navg decode: %.2f ms/frame over %d frames (%.1f fps effective)",
                 totalMs / Double(decoded), decoded, 1000.0 / (totalMs / Double(decoded))))
    if totalMs / Double(decoded) > 16.6 {
        print("note: >16.6 ms/frame → likely NOT keeping up with realtime 60fps; check HW decode")
    }
} else {
    print("\nFAIL: no frames were decoded")
    exit(2)
}

decoder.close()
demuxer.close()
print("\nOK — DecodeProbe finished")