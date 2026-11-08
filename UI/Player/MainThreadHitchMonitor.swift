import Foundation

/// Solo para la sonda de fluidez: mide cuánto tarda el hilo principal en
/// atender un bloque encolado cada 5 ms desde otra cola. Un retraso grande
/// significa que la interfaz (u otra cosa en el hilo principal) lo tuvo ocupado,
/// el mismo hilo donde corre el bucle que entrega cuadros a la pantalla.
final class MainThreadHitchMonitor: @unchecked Sendable {
    struct Snapshot {
        var over8 = 0, over16 = 0, over33 = 0
        var maxMS = 0.0
    }

    private let queue = DispatchQueue(label: "rift.probe.hitch", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var total = Snapshot()
    private var inFlight = false
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in self?.ping() }
        self.timer = timer
        timer.resume()
    }

    func stop() { timer?.cancel(); timer = nil }

    /// Totales acumulados desde el arranque.
    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return total }

    private func ping() {
        lock.lock()
        if inFlight { lock.unlock(); return }   // el anterior aún no se atiende: sigue contando
        inFlight = true
        lock.unlock()
        let sent = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [weak self] in
            let ms = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000
            guard let self else { return }
            self.lock.lock()
            if ms > 8 { self.total.over8 += 1 }
            if ms > 16 { self.total.over16 += 1 }
            if ms > 33 { self.total.over33 += 1 }
            self.total.maxMS = max(self.total.maxMS, ms)
            if ms > 33 {
                // Hora de reloj para alinear con `log show` (OPEN, admisión, seek).
                let stamp = Self.clockFormatter.string(from: Date())
                FileHandle.standardOutput.write(Data(String(format: "HITCH at=%@ ms=%.1f\n", stamp, ms).utf8))
            }
            self.inFlight = false
            self.lock.unlock()
        }
    }
}
