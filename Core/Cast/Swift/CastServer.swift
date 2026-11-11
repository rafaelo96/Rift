import Foundation
import Network

/// Servidor HTTP local que entrega un `CastSource` como HLS. La TV pide las
/// listas y los segmentos directamente al Mac por la red local, así que escucha
/// en todas las interfaces; la ruta lleva un token aleatorio para que no baste
/// con conocer el puerto.
public final class CastServer {
    private let source: CastSource
    private let listener: NWListener
    private let queue = DispatchQueue(label: "rift.cast.server")
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    public init(source: CastSource) throws {
        self.source = source
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    /// Arranca y devuelve el puerto asignado.
    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let pending = PendingStart(continuation)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: pending.finish(.success(listener.port?.rawValue ?? 0))
                case .failed(let error): pending.finish(.failure(error))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener.cancel()
        queue.async { [self] in
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    /// Dirección que se le pasa a AVPlayer. `host` debe ser la IP del Mac en la
    /// red local: la TV la usa tal cual para pedir el video.
    public func playbackURL(host: String, port: UInt16) -> URL? {
        // La lista de medios directamente: con la lista maestra, AVPlayer
        // descarta un video HDR en un Mac sin pantalla HDR (error -11868) antes
        // de llegar a enviarlo a la TV.
        URL(string: "http://\(host):\(port)/\(token)/media.m3u8")
    }

    /// Primera IPv4 de una interfaz activa que no sea loopback.
    public static func localAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var candidate: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0, interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: interface.ifa_name)
            let value = String(cString: host)
            // Ethernet/Wi-Fi antes que túneles o puentes.
            if name.hasPrefix("en") { return value }
            candidate = candidate ?? value
        }
        return candidate
    }

    // MARK: - HTTP

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections[ObjectIdentifier(connection)] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let rest = Data(buffer[end.upperBound...])
                self.respond(to: head, on: connection) { keepAlive in
                    if keepAlive { self.receive(on: connection, buffer: rest) } else { connection.cancel() }
                }
            } else if isComplete || error != nil || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection, then: @escaping (Bool) -> Void) {
        let lines = head.components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ") ?? []
        guard request.count >= 2, request[0] == "GET" || request[0] == "HEAD" else {
            return send(status: "405 Method Not Allowed", type: "text/plain", body: Data(), headOnly: false,
                        keepAlive: false, on: connection, then: then)
        }
        let headOnly = request[0] == "HEAD"
        let keepAlive = !lines.contains { $0.lowercased() == "connection: close" }
        let path = String(request[1]).components(separatedBy: "?")[0]
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == token else {
            return send(status: "404 Not Found", type: "text/plain", body: Data(), headOnly: headOnly,
                        keepAlive: keepAlive, on: connection, then: then)
        }
        let name = parts[1]
        var body: Data?
        var type = "application/vnd.apple.mpegurl"
        if name == "master.m3u8" {
            body = Data(source.masterPlaylist.utf8)
        } else if name == "media.m3u8" {
            body = Data(source.mediaPlaylist.utf8)
        } else if name == "init.mp4" {
            type = "video/mp4"
            body = source.initSegment()
        } else if name.hasPrefix("segment-"), name.hasSuffix(".m4s"),
                  let index = Int(name.dropFirst(8).dropLast(4)) {
            type = "video/iso.segment"
            // HEAD no necesita generar el segmento.
            body = headOnly ? Data() : source.mediaSegment(index)
        }
        guard let body else {
            return send(status: "404 Not Found", type: "text/plain", body: Data(), headOnly: headOnly,
                        keepAlive: keepAlive, on: connection, then: then)
        }
        send(status: "200 OK", type: type, body: body, headOnly: headOnly, keepAlive: keepAlive, on: connection, then: then)
    }

    private func send(status: String, type: String, body: Data, headOnly: Bool, keepAlive: Bool,
                      on connection: NWConnection, then: @escaping (Bool) -> Void) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var payload = Data(head.utf8)
        if !headOnly { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { error in
            then(keepAlive && error == nil)
        })
    }
}

/// Reanuda la espera de `start()` una sola vez. Los cambios de estado del
/// listener llegan en serie por su cola.
private final class PendingStart: @unchecked Sendable {
    private var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    func finish(_ result: Result<UInt16, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
