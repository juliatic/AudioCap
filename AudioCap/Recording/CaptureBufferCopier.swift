import Foundation
import AVFoundation

/// Converts the tap's buffers of one I/O cycle into the canonical writer format (Float32, one array per channel).
///
/// The layout is read from the `AudioBufferList` itself (number of buffers, channels per buffer, byte size),
/// so a list that disagrees with the reported stream format is still copied correctly instead of being
/// misread. `convert` allocates nothing, so it can run inside the I/O block; `copy` wraps it in a new
/// `AVAudioPCMBuffer` for tests and offline use.
enum CaptureBufferCopier {
    struct Result {
        var buffer: AVAudioPCMBuffer
        /// `true` when the buffer list's channel layout did not match the declared format.
        var layoutMismatch: Bool
    }

    struct Layout {
        /// Frames available in every tap buffer.
        var frames: Int
        /// Channels found in the tap's buffers.
        var sourceChannels: Int
    }

    /// Frames and channels in the tap's part of `list`.
    static func layout(of list: UnsafePointer<AudioBufferList>, format: CaptureFormat) -> Layout {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let (first, last) = range(in: buffers, format: format)
        let bytesPerSample = format.sampleType.bytesPerSample
        var frames = Int.max
        var channels = 0
        var index = first
        while index < last {
            let buffer = buffers[index]
            let channelsInBuffer = max(Int(buffer.mNumberChannels), 1)
            channels += channelsInBuffer
            frames = min(frames, Int(buffer.mDataByteSize) / (channelsInBuffer * bytesPerSample))
            index += 1
        }
        return Layout(frames: first < last ? frames : 0, sourceChannels: channels)
    }

    /// Converts `frameCount` frames starting at `sourceOffset` into `channelCount` Float32 channels.
    /// `destination(c)` returns where channel `c` goes. Missing source channels are zero-filled. Allocates nothing.
    static func convert(_ list: UnsafePointer<AudioBufferList>, format: CaptureFormat, sourceOffset: Int, frameCount: Int,
                        channelCount: Int, destination: (Int) -> UnsafeMutablePointer<Float>) {
        guard frameCount > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let (first, last) = range(in: buffers, format: format)
        var channel = 0
        var index = first
        while index < last {
            let buffer = buffers[index]
            let stride = max(Int(buffer.mNumberChannels), 1)
            if let raw = buffer.mData {
                var c = 0
                while c < stride, channel + c < channelCount {
                    convert(raw, type: format.sampleType, bigEndian: format.isBigEndian, offset: c, stride: stride,
                            sourceFrame: sourceOffset, frames: frameCount, into: destination(channel + c))
                    c += 1
                }
            } else {
                var c = 0
                while c < stride, channel + c < channelCount {
                    destination(channel + c).update(repeating: 0, count: frameCount)
                    c += 1
                }
            }
            channel += stride
            index += 1
        }
        while channel < channelCount {
            destination(channel).update(repeating: 0, count: frameCount)
            channel += 1
        }
    }

    /// Copies the tap's buffers into a new buffer in `writerFormat`.
    static func copy(_ list: UnsafePointer<AudioBufferList>, maxFrames: UInt32? = nil, format: CaptureFormat, writerFormat: AVAudioFormat) -> Result? {
        let layout = layout(of: list, format: format)
        let frames = min(layout.frames, Int(maxFrames ?? UInt32.max))
        let outChannels = Int(writerFormat.channelCount)
        guard frames > 0,
              let out = AVAudioPCMBuffer(pcmFormat: writerFormat, frameCapacity: AVAudioFrameCount(frames)),
              let outData = out.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(frames)
        convert(list, format: format, sourceOffset: 0, frameCount: frames, channelCount: outChannels) { outData[$0] }
        return Result(buffer: out, layoutMismatch: layout.sourceChannels != outChannels)
    }

    private static func range(in buffers: UnsafeMutableAudioBufferListPointer, format: CaptureFormat) -> (Int, Int) {
        let first = min(format.firstBufferIndex, buffers.count)
        let last = format.bufferCount.map { min(first + $0, buffers.count) } ?? buffers.count
        return (first, last)
    }

    private static func convert(_ raw: UnsafeMutableRawPointer, type: CaptureFormat.SampleType, bigEndian: Bool, offset: Int, stride: Int,
                                sourceFrame: Int, frames: Int, into dst: UnsafeMutablePointer<Float>) {
        let base = sourceFrame * stride + offset
        switch type {
        case .float32:
            let src = raw.assumingMemoryBound(to: UInt32.self)
            for i in 0..<frames {
                let bits = src[base + i * stride]
                dst[i] = Float(bitPattern: bigEndian ? bits.byteSwapped : bits)
            }
        case .float64:
            let src = raw.assumingMemoryBound(to: UInt64.self)
            for i in 0..<frames {
                let bits = src[base + i * stride]
                dst[i] = Float(Double(bitPattern: bigEndian ? bits.byteSwapped : bits))
            }
        case .int16:
            let src = raw.assumingMemoryBound(to: Int16.self)
            for i in 0..<frames {
                let v = src[base + i * stride]
                dst[i] = Float(bigEndian ? v.byteSwapped : v) / 32_768
            }
        case .int32:
            let src = raw.assumingMemoryBound(to: Int32.self)
            for i in 0..<frames {
                let v = src[base + i * stride]
                dst[i] = Float(Double(bigEndian ? v.byteSwapped : v) / 2_147_483_648)
            }
        case .int24:
            let src = raw.assumingMemoryBound(to: UInt8.self)
            for i in 0..<frames {
                let p = (base + i * stride) * 3
                let (b0, b1, b2) = bigEndian ? (src[p + 2], src[p + 1], src[p]) : (src[p], src[p + 1], src[p + 2])
                let value = Int32(bitPattern: (UInt32(b2) << 24) | (UInt32(b1) << 16) | (UInt32(b0) << 8)) >> 8
                dst[i] = Float(value) / 8_388_608
            }
        }
    }
}
