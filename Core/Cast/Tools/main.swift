import Foundation
import Cast

// CastProbe <video> [--dump <carpeta> [n]] [--serve <segundos>]
// --dump  escribe las listas, el init y los primeros n segmentos para revisarlos con ffprobe.
// --serve deja el servidor encendido e imprime la dirección HLS.
let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("uso: CastProbe <video> [--dump <carpeta> [n]] [--serve <segundos>]")
    exit(2)
}
do {
    let source = try CastSource(url: URL(fileURLWithPath: arguments[1]))
    print("segments=\(source.segmentCount) duration=\(String(format: "%.3f", source.duration)) " +
          "\(source.width)x\(source.height) fps=\(String(format: "%.3f", source.frameRate)) " +
          "range=\(source.videoRange) codecs=\(source.codecs) audio=\(source.audioStreamIndex.map(String.init) ?? "none")")

    if let flag = arguments.firstIndex(of: "--dump"), arguments.count > flag + 1 {
        let folder = URL(fileURLWithPath: arguments[flag + 1])
        let count = arguments.count > flag + 2 ? Int(arguments[flag + 2]) ?? 3 : 3
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(source.masterPlaylist.utf8).write(to: folder.appendingPathComponent("master.m3u8"))
        try Data(source.mediaPlaylist.utf8).write(to: folder.appendingPathComponent("media.m3u8"))
        guard let initSegment = source.initSegment() else { print("init: FAILED"); exit(1) }
        try initSegment.write(to: folder.appendingPathComponent("init.mp4"))
        print("init bytes=\(initSegment.count)")
        for index in 0..<min(count, source.segmentCount) {
            let started = Date()
            guard let segment = source.mediaSegment(index) else { print("segment \(index): FAILED"); exit(1) }
            try segment.write(to: folder.appendingPathComponent("segment-\(index).m4s"))
            print(String(format: "segment %d start=%.3f bytes=%d ms=%.1f", index, source.segmentStart(index),
                         segment.count, Date().timeIntervalSince(started) * 1000))
        }
    }

    if let flag = arguments.firstIndex(of: "--serve"), arguments.count > flag + 1, let seconds = Double(arguments[flag + 1]) {
        let server = try CastServer(source: source)
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let port = try await server.start()
                let host = CastServer.localAddress() ?? "127.0.0.1"
                print("url=\(server.playbackURL(host: host, port: port)?.absoluteString ?? "?")")
                fflush(stdout)
            } catch { print("server: \(error)") }
            semaphore.signal()
        }
        semaphore.wait()
        Thread.sleep(forTimeInterval: seconds)
        server.stop()
    }
} catch {
    print("error: \(error)")
    exit(1)
}
