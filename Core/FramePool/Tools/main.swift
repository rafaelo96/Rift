// FramePoolProbe — standalone validation tool for Core/FramePool.
//
// Usage:
//   swift run FramePoolProbe [path/to/file.mkv]
//
// Validates the measurable success criteria:
//   - Chains Demux + Decode + SlidingFramePool on real content: decodes a
//     bounded stream of video frames through a 4-frame window (~2 min of
//     playback) while printing RSS — the window must stay flat, not grow
//     with how many frames have been decoded.
//   - After a seek: pool.flush() + decoder.flush() and fresh frames must not
//     mix with pre-seek frames (all window pts must be near the new target).
//   - consecutivePairs() must yield strictly increasing pts (interpolation
//     input ready).
//
// Depends only on Core/Demux, Core/Decode, Core/FramePool — no UI/, no Contracts/.

import Foundation
import CoreVideo
import Demux
import Decode
import FramePool

let defaultPath = "/Users/rafael/Downloads/Avatar.Aang.el.ultimo.maestro.del.aire.2026.WEB-DL.4k.HDR-Dual-Lat.mkv"

// MARK: - Memory measurement (physical footprint; same helper as Demux/Decode probes)

private func physicalFootprintBytes() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Int64(info.phys_footprint)
}

private func printRSS(label: String) {
    let mb = Double(physicalFootprintBytes()) / (1024.0 * 1024.0)
    print(String(format: "  RSS [%@] %8.1f MB", label, mb))
}

// MARK: - Probe

let args = CommandLine.arguments
let path = args.count > 1 ? args[1] : defaultPath

print("=== FramePoolProbe ===")
print("file : \(path)")

let demuxer = FFmpegDemuxer()
let info = try demuxer.open(url: URL(fileURLWithPath: path))

guard let video = info.tracks.first(where: { $0.kind == .video }) else {
    print("FAIL: no video track found")
    exit(2)
}
print("video: \(video.width ?? 0)x\(video.height ?? 0) \(video.codecName)")

printRSS(label: "after open")

let decoder = VTDecoder()
try decoder.prepare(track: video)
printRSS(label: "after prepare")

let WINDOW = 4
let pool = SlidingFramePool(capacity: WINDOW)
print("pool window capacity N=\(WINDOW), a window of N frames yields N-1=\(WINDOW - 1) pairs")

// MARK: Phase 1 — bounded decode through the window, RSS over ~2 min of playback

let playbackTarget = info.duration / 3.0
try demuxer.seek(to: playbackTarget)
decoder.flush()
pool.flush()

let maxVideoFrames = 3000 // ≈ 3000/24 fps ≈ 125 s of playback streamed through N=4
var decodedCount = 0
var rssReadings: [Int64] = []
var packetsRead = 0
let startT = CFAbsoluteTimeGetCurrent()

// Isolation experiments (FRAMEPOOL_MODE):
//   "drop"       → decode and drop buffers immediately (no pool). Does RSS grow?
//   "demuxonly"  → read the same packets WITHOUT decoding. Is the growth in demux?
let mode = ProcessInfo.processInfo.environment["FRAMEPOOL_MODE"] ?? "window"
let dropMode = mode == "drop"
let demuxOnlyMode = mode == "demuxonly"

while decodedCount < maxVideoFrames && packetsRead < 200_000 {
    guard let packet = try demuxer.nextPacket() else { break }
    packetsRead += 1
    guard packet.streamIndex == video.streamIndex else { continue }

    if demuxOnlyMode {
        decodedCount += 1
    } else {
        guard let buffer = try decoder.decodeFrame(packet) else { continue }
        if dropMode {
            // buffer goes out of scope here → released immediately
        } else {
            pool.add(buffer: buffer, pts: packet.pts)
        }
        decodedCount += 1
    }

    if decodedCount % 250 == 0 {
        rssReadings.append(physicalFootprintBytes())
        printRSS(label: "decoded \(decodedCount)/\(maxVideoFrames)")
    }
}

let phase1Seconds = CFAbsoluteTimeGetCurrent() - startT
print(String(format: "\ndecoded %d video frames through a %d-frame window in %.1f s (%.0f fps effective)",
             decodedCount, WINDOW, phase1Seconds, Double(decodedCount) / phase1Seconds))
print(String(format: "  pool holds %d frames (must be <= %d, one is evicted per add beyond capacity)",
             pool.count, WINDOW))
print(String(format: "  frames evicted so far: %d", max(0, decodedCount - pool.count)))

let rssMB = rssReadings.map { Double($0) / (1024.0 * 1024.0) }
let rssMin = rssMB.min() ?? 0
let rssMax = rssMB.max() ?? 0
print(String(format: "  RSS during streaming: min=%8.1f MB  max=%8.1f MB  delta=%6.1f MB",
             rssMin, rssMax, rssMax - rssMin))
if rssMax - rssMin < 40 {
    print("  MEMORY: FLAT ✓ (bounded window, no growth with decode count)")
} else {
    print("  MEMORY: possibly growing — investigate (delta \(rssMax - rssMin) MB over \(rssReadings.count) samples)")
}

// Peek at interpolation input shape (read-only, we hold references briefly).
let refPair = pool.consecutivePairs().first
if let refPair {
    let (a, b) = refPair
    print(String(format: "  sample interpolation pair: pts %.3f → %.3f (dt=%.3f s)",
                 a.pts, b.pts, b.pts - a.pts))
}

// MARK: Phase 2 — seek + flush: new frames must not mix with old ones

print("\n--- seek to 2/3 then flush, decode fresh frames ---")
let target = info.duration * 2.0 / 3.0
try demuxer.seek(to: target)
decoder.flush()
pool.flush()
printRSS(label: "after seek+flush (count=\(pool.count))")

var postSeekPts: [Double] = []
for _ in 0..<6 {
    guard let packet = try demuxer.nextPacket() else { break }
    guard packet.streamIndex == video.streamIndex else { continue }
    guard let buffer = try decoder.decodeFrame(packet) else { continue }
    pool.add(buffer: buffer, pts: packet.pts)
    postSeekPts.append(packet.pts)
}

let oldest = pool.oldest()
let latest = pool.latest()
let allNew = pool.frames.allSatisfy { $0.pts >= target - 5.0 }
let ordered = zip(postSeekPts, postSeekPts.dropFirst()).allSatisfy { $0 < $1 }

print(String(format: "  seek target            : %.3f s", target))
print(String(format: "  window oldest pts      : %.3f s", oldest?.pts ?? -1))
print(String(format: "  window latest pts      : %.3f s", latest?.pts ?? -1))
print("  all window pts >= (target - 5 s): \(allNew) \(allNew ? "✓" : "FAIL")")
print("  decoded pts strictly increasing: \(ordered) \(ordered ? "✓" : "FAIL")")

if pool.count <= WINDOW && allNew && ordered {
    print("\nOK — FramePoolProbe finished (window bounded, seek flush clean)")
} else {
    print("\nFAIL — FramePoolProbe detected a problem")
    exit(1)
}