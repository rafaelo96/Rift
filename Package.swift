// swift-tools-version: 5.9
import PackageDescription
import Foundation

// MARK: - FFmpeg prefix resolution (no hardcoded paths)
//
// Resolves the Homebrew prefix for the FFmpeg libraries dynamically, so the
// package builds on Apple Silicon (/opt/homebrew), Intel (/usr/local) and any
// machine where the prefix lives elsewhere. Precedence:
//   1. Environment variable RIFT_FFMPEG_PREFIX (explicit override)
//   2. `brew --prefix` (runs the installed Homebrew binary)
//   3. Well-known fallbacks: /usr/local (Intel) then /opt/homebrew (Apple Silicon)

func ffmpegPrefix() -> String {
    if let env = ProcessInfo.processInfo.environment["RIFT_FFMPEG_PREFIX"],
       !env.isEmpty {
        return env
    }

    let brewCandidates = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
    ]
    for brew in brewCandidates where FileManager.default.isExecutableFile(atPath: brew) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["--prefix"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let prefix = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !prefix.isEmpty {
                return prefix
            }
        } catch {
            break
        }
    }

    if FileManager.default.fileExists(atPath: "/usr/local/lib/libavformat.dylib") {
        return "/usr/local"
    }
    return "/opt/homebrew"
}

let ffmpegPrefix_ = ffmpegPrefix()

let package = Package(
    name: "Rift",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Rift", targets: ["Rift"]),
        .executable(name: "DemuxProbe", targets: ["DemuxProbe"]),
        .executable(name: "DecodeProbe", targets: ["DecodeProbe"]),
        .executable(name: "FramePoolProbe", targets: ["FramePoolProbe"]),
        .executable(name: "MVProbe", targets: ["MVProbe"]),
        .executable(name: "SchedulerProbe", targets: ["SchedulerProbe"]),
        .executable(name: "DecodeAudioProbe", targets: ["DecodeAudioProbe"]),
    ],
    targets: [
        .target(
            name: "Contracts",
            path: "Contracts",
            sources: ["PlayerTypes.swift", "PlayerStateProviding.swift"]
        ),
        .executableTarget(
            name: "Rift",
            dependencies: ["Contracts", "Demux", "Decode", "DecodeAudio", "FramePool", "Scheduler", "Rendering", "Interpolation"],
            path: "UI"
        ),
        // Core/Demux — split into a pure C target (shim over libavformat) and
        // a Swift target that wraps it. Container access only; never decodes.
        .target(
            name: "CDemuxShim",
            path: "Core/Demux/CSource",
            cSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(["-I\(ffmpegPrefix_)/include"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(ffmpegPrefix_)/lib",
                    "-lavformat",
                    "-lavcodec",
                    "-lavutil",
                ]),
            ]
        ),
        .target(
            name: "Demux",
            dependencies: ["CDemuxShim"],
            path: "Core/Demux",
            sources: ["Swift"]
        ),
        // Standalone probe/demo tool for Core/Demux (no UI/, no Contracts/).
        .executableTarget(
            name: "DemuxProbe",
            dependencies: ["Demux"],
            path: "Core/Demux/Tools"
        ),
        // Core/Decode — consumes Core/Demux output; VTDecompressionSession
        // (hardware). System frameworks only, no UI/Contracts.
        .target(
            name: "Decode",
            dependencies: ["Demux"],
            path: "Core/Decode",
            sources: ["Swift"]
        ),
        // Standalone validation tool for Core/Decode (uses Core/Demux as-is).
        .executableTarget(
            name: "DecodeProbe",
            dependencies: ["Demux", "Decode"],
            path: "Core/Decode/Tools"
        ),
        // Core/DecodeAudio — FFmpeg libavcodec decode of audio packets (EAC3
        // → PCM float32). Separated from Core/Decode (which is VT-only).
        .target(
            name: "CDecodeAudioShim",
            path: "Core/DecodeAudio/CSource",
            cSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(["-I\(ffmpegPrefix_)/include"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(ffmpegPrefix_)/lib",
                    "-lavcodec",
                    "-lavutil",
                ]),
            ]
        ),
        .target(
            name: "DecodeAudio",
            dependencies: ["CDecodeAudioShim", "Demux"],
            path: "Core/DecodeAudio",
            sources: ["Swift"]
        ),
        .executableTarget(
            name: "DecodeAudioProbe",
            dependencies: ["Demux", "DecodeAudio"],
            path: "Core/DecodeAudio/Tools"
        ),
        // Core/FramePool — bounded sliding window over decoded frames for
        // Interpolation and Scheduler. Consumes Core/Decode output as-is.
        // No UI/, no Contracts/. Recycling is by ARC: dropping the window's
        // reference on evict lets VT recycle the buffer; no own pool.
        .target(
            name: "FramePool",
            dependencies: ["Demux", "Decode"],
            path: "Core/FramePool",
            sources: ["Swift"]
        ),
        // Standalone validation tool for Core/FramePool (chains Demux+Decode).
        .executableTarget(
            name: "FramePoolProbe",
            dependencies: ["Demux", "Decode", "FramePool"],
            path: "Core/FramePool/Tools"
        ),
        // Core/Interpolation — Swift module: MCFI clásico (MotionSearchEngine +
        // WarpEngine + shaders MSL). API pública única: MotionCompensator, que
        // toma dos CVPixelBuffer y devuelve uno interpolado conservando
        // attachments HDR del I0. Cero archivos derivados en disco: el flujo
        // opera sobre los CVPixelBuffer IOSurface-backed del decoder.
        .target(
            name: "Interpolation",
            path: "Core/Interpolation",
            sources: ["Swift"]
        ),
        // Standalone measurement probe (MVProbe) — reutiliza los archivos del
        // módulo Interpolation via include implícito del path Core/Interpolation
        // (los shaders y engines viven ahora en Swift/). Necesita acceso al
        // directorio Swift/ para compilar main.swift junto con los engines.
        .executableTarget(
            name: "MVProbe",
            dependencies: ["Demux", "Decode", "Interpolation"],
            path: "Core/Interpolation/Tools"
        ),
        // Core/Scheduler — presentation timing for real + interpolated frames
        // (SDR only, no HDR yet). Consumes FramePool pts, Interpolation MVs.
        .target(
            name: "Scheduler",
            path: "Core/Scheduler",
            sources: ["Swift"]
        ),
        .executableTarget(
            name: "SchedulerProbe",
            dependencies: ["Scheduler"],
            path: "Core/Scheduler/Tools"
        ),
        // Rendering — presentation respecting HDR10 metadata (BT.2020/PQ)
        .target(
            name: "Rendering",
            path: "Rendering",
            sources: ["Swift"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)