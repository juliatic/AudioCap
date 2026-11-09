import Foundation
import AVFoundation

/// Copies the audio of one I/O cycle into a freshly allocated buffer in the canonical writer format.
///
/// The layout is read from the `AudioBufferList` itself (number of buffers, channels per buffer, byte size),
/// so a list that disagrees with the reported stream format is still copied correctly instead of being
/// misread. The copy is needed anyway: the I/O buffers are only valid during the callback, and the
/// writer runs later on its own queue.
enum CaptureBufferCopier {
    struct Result {
        var buffer: AVAudioPCMBuffer
        /// `true` when the buffer list's channel layout did not match the declared format.
        var layoutMismatch: Bool
    }

    static func copy(_ list: UnsafePointer<AudioBufferList>, maxFrames: UInt32? = nil, format: CaptureFormat, writerFormat: AVAudioFormat) -> Result? {
        let allBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let first = min(format.firstBufferIndex, allBuffers.count)
        let last = format.bufferCount.map { min(first + $0, allBuffers.count) } ?? allBuffers.count
        let buffers = Array(allBuffers[first..<last])
        let bytesPerSample = format.sampleType.bytesPerSample
        let outChannels = Int(writerFormat.channelCount)

        var sourceChannels = 0
        var frames = Int(maxFrames ?? UInt32.max)
        for buffer in buffers {
            let channelsInBuffer = max(Int(buffer.mNumberChannels), 1)
            sourceChannels += channelsInBuffer
            let available = Int(buffer.mDataByteSize) / (channelsInBuffer * bytesPerSample)
            frames = min(frames, available)
        }
        guard frames > 0, buffers.count > 0,
              let out = AVAudioPCMBuffer(pcmFormat: writerFormat, frameCapacity: AVAudioFrameCount(frames)),
              let outData = out.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(frames)

        var channel = 0
        for buffer in buffers {
            let stride = max(Int(buffer.mNumberChannels), 1)
            guard let raw = buffer.mData else {
                channel += stride
                continue
            }
            for c in 0..<stride where channel + c < outChannels {
                convert(raw, type: format.sampleType, bigEndian: format.isBigEndian, offset: c, stride: stride, frames: frames, into: outData[channel + c])
            }
            channel += stride
        }
        for c in min(channel, outChannels)..<outChannels {
            outData[c].update(repeating: 0, count: frames)
        }
        return Result(buffer: out, layoutMismatch: sourceChannels != outChannels)
    }

    private static func convert(_ raw: UnsafeMutableRawPointer, type: CaptureFormat.SampleType, bigEndian: Bool, offset: Int, stride: Int, frames: Int, into dst: UnsafeMutablePointer<Float>) {
        switch type {
        case .float32:
            let src = raw.assumingMemoryBound(to: UInt32.self)
            for i in 0..<frames {
                let bits = src[i * stride + offset]
                dst[i] = Float(bitPattern: bigEndian ? bits.byteSwapped : bits)
            }
        case .float64:
            let src = raw.assumingMemoryBound(to: UInt64.self)
            for i in 0..<frames {
                let bits = src[i * stride + offset]
                dst[i] = Float(Double(bitPattern: bigEndian ? bits.byteSwapped : bits))
            }
        case .int16:
            let src = raw.assumingMemoryBound(to: Int16.self)
            for i in 0..<frames {
                let v = src[i * stride + offset]
                dst[i] = Float(bigEndian ? v.byteSwapped : v) / 32_768
            }
        case .int32:
            let src = raw.assumingMemoryBound(to: Int32.self)
            for i in 0..<frames {
                let v = src[i * stride + offset]
                dst[i] = Float(Double(bigEndian ? v.byteSwapped : v) / 2_147_483_648)
            }
        case .int24:
            let src = raw.assumingMemoryBound(to: UInt8.self)
            for i in 0..<frames {
                let p = (i * stride + offset) * 3
                let (b0, b1, b2) = bigEndian ? (src[p + 2], src[p + 1], src[p]) : (src[p], src[p + 1], src[p + 2])
                let value = Int32(bitPattern: (UInt32(b2) << 24) | (UInt32(b1) << 16) | (UInt32(b0) << 8)) >> 8
                dst[i] = Float(value) / 8_388_608
            }
        }
    }
}
