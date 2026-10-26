import Foundation
import CoreVideo

// MARK: - SlidingFramePool
//
// Bounded sliding window of decoded frames, ready for Interpolation and
// Scheduler to consume. It stores at most `capacity` (N) (buffer, pts) pairs,
// ordered by pts ascending. Adding beyond N evicts the oldest.
//
// Recycling: the buffers come from Core/Decode's `decodeFrame`, which hands
// over ownership of a CVPixelBuffer already retained for the caller. VT's own
// internal pool recycles a buffer once the last reference drops, so evicting
// means simply dropping this window's strong reference — no CVPixelBufferPool
// of our own is needed (CVPixelBufferPoolCreate* only allocates NEW buffers and
// there is no API to re-insert an existing buffer into a pool).

/// One decoded frame plus the pts it belongs to (seconds, from the originating
/// CompressedPacket).
public struct Frame: Equatable {
    public let pixelBuffer: CVPixelBuffer
    public let pts: Double

    public init(pixelBuffer: CVPixelBuffer, pts: Double) {
        self.pixelBuffer = pixelBuffer
        self.pts = pts
    }
}

public final class SlidingFramePool {
    /// Maximum number of frames kept in memory at once (N).
    public let capacity: Int

    /// Ordered by pts ascending.
    private var storage: [Frame] = []
    /// Firmas de repetición ya calculadas, por pts (solo frames aún en la ventana).
    private var signatures: [Double: RepeatedFrameDetector.Signature] = [:]
    /// Repetidos ya descartados para el frame más antiguo actual: reservar de nuevo
    /// sin consumir no pasa del límite, así un par abarca ≤ límite+1 periodos.
    private var droppedForOldest = 0

    public init(capacity: Int = 4) {
        precondition(capacity > 0, "SlidingFramePool capacity must be > 0")
        self.capacity = capacity
    }

    public var count: Int { storage.count }

    /// The current window, ordered by pts ascending (bounded by `capacity`).
    public var frames: [Frame] { storage }

    /// Earliest frame in the window (the pair's "from" side for interpolation).
    public func oldest() -> Frame? { storage.first }

    /// Newest frame in the window.
    public func latest() -> Frame? { storage.last }

    /// Inserts a decoded frame. If the window is at capacity the oldest frame
    /// is evicted — its CVPixelBuffer reference is dropped here, letting VT
    /// recycle it. Out-of-order pts are tolerated and re-sorted (window stays
    /// small, so the sort is trivial).
    public func add(buffer: CVPixelBuffer, pts: Double) {
        storage.append(Frame(pixelBuffer: buffer, pts: pts))
        storage.sort { $0.pts < $1.pts }
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
            droppedForOldest = 0
            pruneSignatures()
        }
    }

    /// Consecutive ordered pairs — the input for a frame-interpolation engine.
    /// A window of N frames yields N-1 pairs.
    public func consecutivePairs() -> [(Frame, Frame)] {
        guard storage.count >= 2 else { return [] }
        var result: [(Frame, Frame)] = []
        result.reserveCapacity(storage.count - 1)
        for i in 0..<(storage.count - 1) {
            result.append((storage[i], storage[i + 1]))
        }
        return result
    }

    /// Reserva los dos frames más antiguos SIN removerlos del pool (el pool NO
    /// usa lock; se asume acceso serializado como el resto de las operaciones).
    /// El llamador debe invocar `consumePair()` solo DESPUÉS de haber encolado
    /// todos los frames derivados del par (originales + interpolados).
    /// - Returns: (I0, I1) si hay al menos 2 frames, nil en caso contrario.
    public func reservePair() -> (Frame, Frame)? {
        guard storage.count >= 2 else { return nil }
        return (storage[0], storage[1])
    }

    /// Como `reservePair()`, pero si el segundo frame repite al primero
    /// (`RepeatedFrameDetector`), hay un tercero en la ventana y no se descartó
    /// ya un repetido para este frame más antiguo, saca el repetido de la ventana y reserva
    /// (frame 0, frame 2): la interpolación reparte el movimiento del dibujo
    /// siguiente sobre los dos periodos en vez de "quieto + salto doble".
    /// Devuelve el frame descartado para que el llamador libere su slot
    /// (permiso del decode loop). Con solo 2 frames no deduplica: no espera.
    public func reservePair(droppingRepeats: Bool) -> (pair: (Frame, Frame), dropped: Frame?)? {
        guard let reserved = reservePair(droppingRepeats: droppingRepeats, maxConsecutive: 1) else { return nil }
        return (reserved.pair, reserved.dropped.first)
    }

    /// Como `reservePair(droppingRepeats:)`, pero descarta hasta `maxConsecutive`
    /// repetidos seguidos del frame más antiguo (anime "en tres": 2 → el par abarca
    /// hasta 3 periodos). Cada descarte compara de nuevo contra el frame más
    /// antiguo y exige un frame detrás del candidato. Devuelve todos los descartes.
    public func reservePair(droppingRepeats: Bool, maxConsecutive: Int) -> (pair: (Frame, Frame), dropped: [Frame])? {
        guard storage.count >= 2 else { return nil }
        var dropped: [Frame] = []
        // El decoder entrega en orden de decodificación: un frame intermedio puede no
        // haber llegado aún. Solo se descarta si el frame que sigue al candidato es su
        // sucesor inmediato (periodo = menor salto de la ventana), si no el par
        // saltaría un frame que llega después y rompería la cadena de pares.
        let period = zip(storage, storage.dropFirst()).map { $1.pts - $0.pts }.filter { $0 > 0 }.min() ?? 0
        while droppingRepeats, droppedForOldest < maxConsecutive, storage.count >= 3,
              storage[2].pts - storage[1].pts <= period * 1.5,
              let first = signature(of: storage[0]), let second = signature(of: storage[1]),
              RepeatedFrameDetector.isRepeat(first, second) {
            let gone = storage.remove(at: 1)
            signatures[gone.pts] = nil
            droppedForOldest += 1
            dropped.append(gone)
        }
        return ((storage[0], storage[1]), dropped)
    }

    private func signature(of frame: Frame) -> RepeatedFrameDetector.Signature? {
        if let cached = signatures[frame.pts] { return cached }
        let computed = RepeatedFrameDetector.signature(frame.pixelBuffer)
        if let computed { signatures[frame.pts] = computed }
        return computed
    }

    private func pruneSignatures() {
        guard !signatures.isEmpty else { return }
        let live = Set(storage.map(\.pts))
        for key in signatures.keys where !live.contains(key) { signatures[key] = nil }
    }

    /// Consume el frame más antiguo del pool, liberando su slot. Debe llamarse
    /// DESPUÉS de que todos los frames derivados del par (originales +
    /// interpolados) hayan sido encolados en el display layer. No hace nada si
    /// el pool está vacío.
    public func consumePair() {
        guard !storage.isEmpty else { return }
        storage.removeFirst()
        droppedForOldest = 0
        pruneSignatures()
    }

    /// Removes the oldest frame from the window and returns it.
    /// Use after `oldest()` to consume the frame and allow the next
    /// `oldest()` call to return the following frame.
    /// Does nothing if the window is empty.
    public func removeFirst() {
        if !storage.isEmpty {
            storage.removeFirst()
            droppedForOldest = 0
            pruneSignatures()
        }
    }

    /// Empties the window. Call after a demux/decoder seek so new frames never
    /// mix with frames from before the jump.
    public func flush() {
        storage.removeAll()
        signatures.removeAll()
        droppedForOldest = 0
    }
}