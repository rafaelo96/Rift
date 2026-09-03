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

    /// Removes the oldest frame from the window and returns it.
    /// Use after `oldest()` to consume the frame and allow the next
    /// `oldest()` call to return the following frame.
    /// Does nothing if the window is empty.
    public func removeFirst() {
        if !storage.isEmpty {
            storage.removeFirst()
        }
    }

    /// Empties the window. Call after a demux/decoder seek so new frames never
    /// mix with frames from before the jump.
    public func flush() {
        storage.removeAll()
    }
}