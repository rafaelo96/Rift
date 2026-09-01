// DemuxProbe — standalone validation tool for Core/Demux.
//
// Usage:
//   swift run DemuxProbe [path/to/file.mkv]
//
// Validates the measurable success criteria:
//   - open reads only headers/index (expect < 1 s on a multi-GB file)
//   - memory stays flat while pulling packets (RSS printed every 5 packets)
//   - seek(to: mid) jumps to the closest keyframe without reading from the start
//
// Depends only on Core/Demux — no UI/, no Contracts/.

import Foundation
import Demux

let defaultPath = "/Users/rafael/Downloads/Avatar.Aang.el.ultimo.maestro.del.aire.2026.WEB-DL.4k.HDR-Dual-Lat.mkv"

// MARK: - Memory measurement (physical footprint)

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

private func elapsedMilliseconds(from start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
}

// MARK: - Main probe

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultPath
let url = URL(fileURLWithPath: path)

print("=== DemuxProbe ===")
print("file : \(path)")
let fileSize: Int64 = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
print("size : \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))")

let demuxer = FFmpegDemuxer()

// 1. Open — must be fast (< 1 s) and only read headers.
let start = DispatchTime.now().uptimeNanoseconds
let info: ContainerInfo
do {
    info = try demuxer.open(url: url)
} catch {
    print("OPEN FAILED: \(error)")
    exit(1)
}
print(String(format: "open  : %.1f ms (headers/index only)", elapsedMilliseconds(from: start)))
print(String(format: "duration : %.2f s", info.duration))
print("tracks:")
for track in info.tracks {
    let kind = track.kind == .video ? "video" : (track.kind == .audio ? "audio" : "other")
    var extra: [String] = []
    if let w = track.width, let h = track.height { extra.append("\(w)x\(h)") }
    if let fps = track.frameRate { extra.append(String(format: "%.2f fps", fps)) }
    extra.append("ct=\(track.colorTransfer.map(String.init) ?? "-")")
    extra.append("cp=\(track.colorPrimaries.map(String.init) ?? "-")")
    extra.append("extradata=\(track.codecExtradata.count)B")
    print(String(format: "  [%d] %@ %@ %@",
                 track.streamIndex, kind, track.codecName, extra.joined(separator: ", ")))
}

// Success criterion for this task: the video track must expose non-empty
// codec extradata (VPS/SPS/PPS for HEVC) for a future CMFormatDescription.
if let video = info.tracks.first(where: { $0.kind == .video }) {
    if video.codecExtradata.isEmpty {
        print("FAIL: video track has EMPTY codecExtradata")
        exit(3)
    }
    print(String(format: "video extradata : %d bytes (non-empty ✓)", video.codecExtradata.count))
}

// 2. Pull 20 packets, printing memory every 5.
print("\n--- reading 20 packets (compressed, not decoded) ---")
for i in 0..<20 {
    guard let packet = try? demuxer.nextPacket() else {
        print("  EOF earlier than expected at packet \(i)")
        break
    }
    let isKey = packet.isKeyframe ? "K" : " "
    print(String(format: "  [%2d] s%d %@ pts=%10.3f dts=%10.3f size=%6d bytes",
                 i, packet.streamIndex, isKey, packet.pts, packet.dts, packet.data.count))
    if (i + 1) % 5 == 0 {
        let mb = Double(physicalFootprintBytes()) / 1_048_576.0
        print(String(format: "  --- RSS after %2d packets: %.1f MB", i + 1, mb))
    }
}

// 3. Seek to the middle of the file, then confirm the next packet is a
//    keyframe near the target — proof we did NOT read from the start.
let target = info.duration / 2.0
print(String(format: "\n--- seek(to: %.2f s = mid) ---", target))
do {
    try demuxer.seek(to: target)
} catch {
    print("SEEK FAILED: \(error)")
    exit(2)
}

for _ in 0..<5 {
    guard let packet = try? demuxer.nextPacket() else {
        print("  EOF right after seek")
        break
    }
    let gap = packet.pts - target
    let isKey = packet.isKeyframe ? "K" : " "
    print(String(format: "  s%d %@ pts=%10.3f gapToTarget=%+8.3f s",
                 packet.streamIndex, isKey, packet.pts, gap))
}

// 4. Close and report final memory (should match the first reading).
let finalMB = Double(physicalFootprintBytes()) / 1_048_576.0
print(String(format: "\nfinal RSS: %.1f MB (expect ≈ the value after reading)", finalMB))

demuxer.close()
print(String(format: "after close RSS: %.1f MB", Double(physicalFootprintBytes()) / 1_048_576.0))
print("\nOK — DemuxProbe finished")