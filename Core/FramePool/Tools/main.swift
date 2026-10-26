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

// MARK: Repeated-frame mode (FRAMEPOOL_MODE=dedup)
//   FRAMEPOOL_SEEK=<s> FRAMEPOOL_SECONDS=<s>: streams the span through an N=4
//   window consuming pairs like the player, once with droppingRepeats and once
//   without; prints every dropped pts (DEDUP_DROP), pair spans, detector cost,
//   RSS, and checks that droppingRepeats:false equals reservePair().
if ProcessInfo.processInfo.environment["FRAMEPOOL_MODE"] == "dedup" {
    let seekAt = Double(ProcessInfo.processInfo.environment["FRAMEPOOL_SEEK"] ?? "1170")!
    let seconds = Double(ProcessInfo.processInfo.environment["FRAMEPOOL_SECONDS"] ?? "120")!
    func run(dropping: Bool) throws -> (pairs: [(Double, Double)], dropped: [Double], ms: [Double], rss: [Int64]) {
        try demuxer.seek(to: seekAt)
        decoder.flush()
        let window = SlidingFramePool(capacity: 4)
        var pairs: [(Double, Double)] = [], dropped: [Double] = [], ms: [Double] = [], rss: [Int64] = []
        var decoded = 0
        func consume(minimum: Int) {
            while window.count >= minimum {
                let start = DispatchTime.now().uptimeNanoseconds
                guard let reserved = window.reservePair(droppingRepeats: dropping) else { return }
                ms.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                if !dropping, let plain = window.reservePair(), plain.0.pts != reserved.pair.0.pts || plain.1.pts != reserved.pair.1.pts {
                    print("FAIL: droppingRepeats:false differs from reservePair()"); exit(1)
                }
                if let gone = reserved.dropped { dropped.append(gone.pts) }
                pairs.append((reserved.pair.0.pts, reserved.pair.1.pts))
                window.consumePair()
            }
        }
        while let packet = try demuxer.nextPacket() {
            guard packet.streamIndex == video.streamIndex else { continue }
            guard let frame = try decoder.decodeFrame(packet) else { continue }
            if frame.pts < seekAt { continue }
            if frame.pts > seekAt + seconds { break }
            window.add(buffer: frame.pixelBuffer, pts: frame.pts)
            decoded += 1
            if decoded % 250 == 0 { rss.append(physicalFootprintBytes()) }
            consume(minimum: 4)
        }
        consume(minimum: 2)
        return (pairs, dropped, ms, rss)
    }
    let plain = try run(dropping: false)
    let dedup = try run(dropping: true)
    let ordered = dedup.pairs.allSatisfy { $0.0 < $0.1 } && zip(dedup.pairs, dedup.pairs.dropFirst()).allSatisfy { $0.1 == $1.0 }
    let period = plain.pairs.map { $0.1 - $0.0 }.sorted()[plain.pairs.count / 2]
    let longest = dedup.pairs.map { $0.1 - $0.0 }.max() ?? 0
    let sortedMS = dedup.ms.sorted()
    let rssMB = dedup.rss.map { Double($0) / 1048576 }
    for pts in dedup.dropped { print(String(format: "DEDUP_DROP %.3f", pts)) }
    print(String(format: "DEDUP pairs plain=%d dedup=%d dropped=%d chained+ordered=%@ longest span=%.1f periods",
                 plain.pairs.count, dedup.pairs.count, dedup.dropped.count, ordered ? "yes" : "NO", longest / period))
    print(String(format: "DEDUP reserve cost median=%.2f ms p95=%.2f ms max=%.2f ms",
                 sortedMS[sortedMS.count / 2], sortedMS[Int(Double(sortedMS.count - 1) * 0.95)], sortedMS.last ?? 0))
    print(String(format: "DEDUP RSS min=%.1f max=%.1f MB", rssMB.min() ?? 0, rssMB.max() ?? 0))
    exit(ordered && longest <= period * 2.05 ? 0 : 1)
}

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
        guard let decodedFrame = try decoder.decodeFrame(packet) else { continue }
        if dropMode {
            // buffer goes out of scope here → released immediately
        } else {
            pool.add(buffer: decodedFrame.pixelBuffer, pts: decodedFrame.pts)
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
    guard let decodedFrame = try decoder.decodeFrame(packet) else { continue }
    pool.add(buffer: decodedFrame.pixelBuffer, pts: decodedFrame.pts)
    postSeekPts.append(decodedFrame.pts)
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
