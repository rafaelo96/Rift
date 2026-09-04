import Foundation
import Demux
import DecodeAudio

let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: DecodeAudioProbe <file.mkv> [seconds_to_decode]")
    exit(1)
}
let url = URL(fileURLWithPath: args[1])
let secondsLimit = args.count > 2 ? Double(args[2]) ?? 5.0 : 5.0

let demuxer = FFmpegDemuxer()
guard let info = try? demuxer.open(url: url) else {
    print("ERROR: failed to open \(url.path)")
    exit(1)
}

guard let audioTrack = info.tracks.first(where: { $0.kind == .audio }) else {
    print("ERROR: no audio track")
    exit(1)
}
print("=== DecodeAudioProbe ===")
print("audio track: [\(audioTrack.streamIndex)] \(audioTrack.codecName)")

let decoder = try AudioDecoder(codecName: audioTrack.codecName)
print("decoder opened OK")
var firstFormatPrinted = false

var packetsSeen = 0
var framesDecoded = 0
var totalSamples: Int64 = 0
var firstPts: Double? = nil
var lastPts: Double? = nil
var minSample: Float = .greatestFiniteMagnitude
var maxSample: Float = -.greatestFiniteMagnitude
var sumSquares: Double = 0
var allZeros = true

while true {
    guard let pkt = try? demuxer.nextPacket() else { break }
    if pkt.streamIndex != audioTrack.streamIndex { continue }
    packetsSeen += 1
    let frames = decoder.decode(packet: pkt)
    for f in frames {
        framesDecoded += 1
        if !firstFormatPrinted {
            print("lastSampleFmtName: \(decoder.lastSampleFmtName)")
            firstFormatPrinted = true
        }
        if firstPts == nil { firstPts = f.pts }
        lastPts = f.pts
        totalSamples += Int64(f.sampleCount) * Int64(f.channels)
        f.data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            let n = ptr.count / MemoryLayout<Float>.stride
            for i in 0..<n {
                let v = base[i]
                minSample = min(minSample, v)
                maxSample = max(maxSample, v)
                sumSquares += Double(v) * Double(v)
                if v != 0 { allZeros = false }
            }
        }
    }
    if let lp = lastPts, lp >= secondsLimit { break }
}

let rms = totalSamples > 0 ? sqrt(sumSquares / Double(max(totalSamples, 1))) : 0
print("--- results ---")
print("audio packets seen   : \(packetsSeen)")
print("frames decoded       : \(framesDecoded)")
print("total samples        : \(totalSamples)")
print("first pts            : \(firstPts ?? -1)")
print("last pts             : \(lastPts ?? -1)")
print("min sample           : \(minSample)")
print("max sample           : \(maxSample)")
print("RMS                  : \(rms)")
print("all zeros            : \(allZeros)")

if allZeros {
    print("RESULT: FAIL — decoded audio is all zeros (silent)")
    exit(1)
} else if rms < 1e-6 {
    print("RESULT: FAIL — RMS too low (effectively silent)")
    exit(1)
} else {
    print("RESULT: PASS — decoded audio has real signal")
    exit(0)
}
