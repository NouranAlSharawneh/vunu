import Foundation
import Synchronization

/// Lock-free single-producer / single-consumer ring of Float samples.
/// The realtime input callback writes; the drain queue reads. No allocation or locking on either side.
final class SampleRing: @unchecked Sendable {
    let capacity: Int
    private let buffer: UnsafeMutablePointer<Float>
    /// Monotonic totals; `write - read` is the fill level.
    private let writeTotal = Atomic<Int>(0)
    private let readTotal = Atomic<Int>(0)

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        buffer = .allocate(capacity: self.capacity)
        buffer.initialize(repeating: 0, count: self.capacity)
    }

    deinit { buffer.deallocate() }

    var available: Int { writeTotal.load(ordering: .acquiring) - readTotal.load(ordering: .acquiring) }

    /// Producer. Writes all `count` floats or nothing (returns false on overrun, so frames never split).
    @discardableResult
    func write(_ src: UnsafePointer<Float>, count: Int) -> Bool {
        let w = writeTotal.load(ordering: .relaxed)
        let r = readTotal.load(ordering: .acquiring)
        guard count > 0, capacity - (w - r) >= count else { return count == 0 }
        let start = w % capacity
        let first = min(count, capacity - start)
        (buffer + start).update(from: src, count: first)
        if first < count { buffer.update(from: src + first, count: count - first) }
        writeTotal.store(w + count, ordering: .releasing)
        return true
    }

    /// Consumer. Reads up to `max` floats; returns how many were read.
    func read(into dst: UnsafeMutablePointer<Float>, max: Int) -> Int {
        let r = readTotal.load(ordering: .relaxed)
        let w = writeTotal.load(ordering: .acquiring)
        let n = min(max, w - r)
        guard n > 0 else { return 0 }
        let start = r % capacity
        let first = min(n, capacity - start)
        dst.update(from: buffer + start, count: first)
        if first < n { (dst + first).update(from: buffer, count: n - first) }
        readTotal.store(r + n, ordering: .releasing)
        return n
    }
}
