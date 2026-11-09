import Foundation
import Synchronization

/// A single-producer, single-consumer ring of deinterleaved Float32 frames.
///
/// The I/O block (producer) writes converted samples straight into preallocated memory and publishes them by
/// advancing `writeIndex`; the capture writer's queue (consumer) copies them out and advances `readIndex`.
/// Neither side allocates, locks or sends Objective-C messages. Indices are absolute frame counts, so the
/// ring position is `index & mask`.
///
/// It also carries split markers: absolute frame positions where the current take must end.
final class CaptureRingBuffer: @unchecked Sendable {
    let channelCount: Int
    /// Capacity in frames (a power of two).
    let capacity: Int
    private let mask: Int
    private let channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    private static let markerCapacity = 64
    private let markers: UnsafeMutablePointer<Int>
    private let markerWrite = Atomic<Int>(0)
    private let markerRead = Atomic<Int>(0)

    /// Frames the producer could not store because the ring was full.
    let overflowFrames = Atomic<Int>(0)

    init(channelCount: Int, minimumCapacity: Int) {
        precondition(channelCount > 0)
        var capacity = 1
        while capacity < max(minimumCapacity, 1_024) { capacity <<= 1 }
        self.channelCount = channelCount
        self.capacity = capacity
        self.mask = capacity - 1
        channels = .allocate(capacity: channelCount)
        for c in 0..<channelCount {
            let storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            storage.initialize(repeating: 0, count: capacity)
            channels[c] = storage
        }
        markers = .allocate(capacity: Self.markerCapacity)
        markers.initialize(repeating: 0, count: Self.markerCapacity)
    }

    deinit {
        for c in 0..<channelCount { channels[c].deallocate() }
        channels.deallocate()
        markers.deallocate()
    }

    // MARK: Producer (I/O thread)

    /// Absolute position of the next frame the producer writes.
    var producedFrames: Int { writeIndex.load(ordering: .relaxed) }

    /// Frames staged by `stage` and not committed yet. Producer-only.
    private var stagedCount = 0

    /// Converts up to `frameCount` frames into free space without publishing them yet.
    /// `fill(offset, count, destination)` must write `count` frames of every channel, starting at source
    /// frame `offset`, to `destination(channel)`; it is called once, or twice when the ring wraps.
    /// Frames that don't fit are counted in `overflowFrames` once committed. Returns the frames staged.
    @discardableResult
    func stage(frameCount: Int, fill: (_ sourceOffset: Int, _ count: Int, _ destination: (Int) -> UnsafeMutablePointer<Float>) -> Void) -> Int {
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let count = min(frameCount, capacity - (write - read))
        stagedCount = count
        stagedOverflow = frameCount - count
        guard count > 0 else { return 0 }

        let start = write & mask
        let first = min(count, capacity - start)
        let channels = self.channels
        fill(0, first) { channels[$0] + start }
        if first < count {
            fill(first, count - first) { channels[$0] }
        }
        return count
    }
    private var stagedOverflow = 0

    /// Publishes the frames of the last `stage` call to the consumer.
    func commitStaged() {
        if stagedOverflow > 0 { overflowFrames.add(stagedOverflow, ordering: .relaxed) }
        if stagedCount > 0 {
            writeIndex.store(writeIndex.load(ordering: .relaxed) + stagedCount, ordering: .releasing)
        }
        stagedCount = 0
        stagedOverflow = 0
    }

    /// Stages and commits in one step. Returns the frames stored.
    @discardableResult
    func write(frameCount: Int, fill: (_ sourceOffset: Int, _ count: Int, _ destination: (Int) -> UnsafeMutablePointer<Float>) -> Void) -> Int {
        let count = stage(frameCount: frameCount, fill: fill)
        commitStaged()
        return count
    }

    /// Marks the current write position as the end of the take. Returns `false` if the marker queue is full.
    @discardableResult
    func pushMarker() -> Bool {
        let w = markerWrite.load(ordering: .relaxed)
        let r = markerRead.load(ordering: .acquiring)
        guard w - r < Self.markerCapacity else { return false }
        markers[w & (Self.markerCapacity - 1)] = writeIndex.load(ordering: .relaxed)
        markerWrite.store(w + 1, ordering: .releasing)
        return true
    }

    // MARK: Consumer (writer queue)

    /// Absolute position of the next frame the consumer reads.
    var consumedFrames: Int { readIndex.load(ordering: .relaxed) }

    /// Frames published by the producer and not read yet.
    var availableFrames: Int { writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .relaxed) }

    /// The oldest pending split marker, if any.
    func peekMarker() -> Int? {
        let r = markerRead.load(ordering: .relaxed)
        guard r < markerWrite.load(ordering: .acquiring) else { return nil }
        return markers[r & (Self.markerCapacity - 1)]
    }

    func popMarker() {
        markerRead.add(1, ordering: .releasing)
    }

    /// Copies `count` frames (at most `availableFrames`) into `destination(channel)` and releases them.
    func read(count: Int, into destination: (Int) -> UnsafeMutablePointer<Float>) {
        let read = readIndex.load(ordering: .relaxed)
        let start = read & mask
        let first = min(count, capacity - start)
        for c in 0..<channelCount {
            let out = destination(c)
            out.update(from: channels[c] + start, count: first)
            if first < count { (out + first).update(from: channels[c], count: count - first) }
        }
        readIndex.store(read + count, ordering: .releasing)
    }
}
