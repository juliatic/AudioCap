import Foundation
import AVFoundation

/// A fixed-capacity ring of deinterleaved Float32 frames that keeps the most recent `capacity` frames.
///
/// All storage is allocated in `init`. `append` and `removeAll` never allocate, so they are safe on the I/O path.
/// Only `makeBuffer(format:)`, which hands the frames over to the writer, creates a buffer.
final class AudioRingBuffer {
    let capacity: Int
    let channelCount: Int

    /// Frames currently held (at most `capacity`).
    private(set) var count = 0
    /// Index of the next frame to write.
    private var head = 0
    /// `channelCount` blocks of `capacity` samples, one block per channel.
    private let storage: UnsafeMutablePointer<Float>

    init(capacity: Int, channelCount: Int) {
        precondition(capacity > 0 && channelCount > 0)
        self.capacity = capacity
        self.channelCount = channelCount
        storage = .allocate(capacity: capacity * channelCount)
        storage.initialize(repeating: 0, count: capacity * channelCount)
    }

    deinit { storage.deallocate() }

    func removeAll() {
        count = 0
        head = 0
    }

    /// Appends `frameCount` frames of `buffer` starting at `start`; the oldest frames are dropped when full.
    /// `buffer` must be deinterleaved Float32 with `channelCount` channels.
    func append(_ buffer: AVAudioPCMBuffer, from start: Int = 0, count frameCount: Int? = nil) {
        guard let data = buffer.floatChannelData else { return }
        precondition(!buffer.format.isInterleaved && Int(buffer.format.channelCount) == channelCount)
        var n = frameCount ?? (Int(buffer.frameLength) - start)
        guard n > 0 else { return }
        var offset = start
        // Only the last `capacity` frames can survive.
        if n > capacity {
            offset += n - capacity
            n = capacity
        }
        let first = min(n, capacity - head)
        for c in 0..<channelCount {
            let dst = storage + c * capacity
            (dst + head).update(from: data[c] + offset, count: first)
            if n > first { dst.update(from: data[c] + offset + first, count: n - first) }
        }
        head = (head + n) % capacity
        count = min(count + n, capacity)
    }

    /// A new buffer with the held frames, oldest first, or `nil` when empty. Does not clear the ring.
    func makeBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard count > 0,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let outData = out.floatChannelData else { return nil }
        precondition(!format.isInterleaved && Int(format.channelCount) == channelCount)
        out.frameLength = AVAudioFrameCount(count)
        let tail = (head - count + capacity) % capacity
        let first = min(count, capacity - tail)
        for c in 0..<channelCount {
            let src = storage + c * capacity
            outData[c].update(from: src + tail, count: first)
            if count > first { (outData[c] + first).update(from: src, count: count - first) }
        }
        return out
    }
}
