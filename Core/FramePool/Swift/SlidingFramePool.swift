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
    /// Ya se descartó un repetido para el frame más antiguo actual: reservar de
    /// nuevo sin consumir no descarta otro, así un par abarca ≤ 2 periodos fuente.
    private var droppedForOldest = false

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
            droppedForOldest = false
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
        guard storage.count >= 2 else { return nil }
        guard droppingRepeats else { return ((storage[0], storage[1]), nil) }
        if !droppedForOldest, storage.count >= 3,
           let first = signature(of: storage[0]), let second = signature(of: storage[1]),
           RepeatedFrameDetector.isRepeat(first, second) {
            let dropped = storage.remove(at: 1)
            signatures[dropped.pts] = nil
            droppedForOldest = true
            return ((storage[0], storage[1]), dropped)
        }
        return ((storage[0], storage[1]), nil)
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
        droppedForOldest = false
        pruneSignatures()
    }

    /// Removes the oldest frame from the window and returns it.
    /// Use after `oldest()` to consume the frame and allow the next
    /// `oldest()` call to return the following frame.
    /// Does nothing if the window is empty.
    public func removeFirst() {
        if !storage.isEmpty {
            storage.removeFirst()
            droppedForOldest = false
            pruneSignatures()
        }
    }

    /// Empties the window. Call after a demux/decoder seek so new frames never
    /// mix with frames from before the jump.
    public func flush() {
        storage.removeAll()
        signatures.removeAll()
        droppedForOldest = false
    }
}