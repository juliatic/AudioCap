import XCTest
import AVFoundation
@testable import AudioCap

final class CaptureFormatTests: XCTestCase {
    private func asbd(rate: Double = 48_000, channels: UInt32 = 2, bits: UInt32 = 32, float: Bool = true, nonInterleaved: Bool = false, bytesPerFrame: UInt32? = nil) -> AudioStreamBasicDescription {
        var flags: AudioFormatFlags = kAudioFormatFlagIsPacked | (float ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger)
        if nonInterleaved { flags |= kAudioFormatFlagIsNonInterleaved }
        let bpf = bytesPerFrame ?? (bits / 8) * (nonInterleaved ? 1 : channels)
        return AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
                                           mBytesPerPacket: bpf, mFramesPerPacket: 1, mBytesPerFrame: bpf,
                                           mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0)
    }

    func testFloatInterleavedStereo() throws {
        let format = try CaptureFormat(validating: asbd(rate: 96_000))
        XCTAssertEqual(format.sampleRate, 96_000)
        XCTAssertEqual(format.channelCount, 2)
        XCTAssertEqual(format.sampleType, .float32)
        XCTAssertTrue(format.isInterleaved)
        XCTAssertEqual(format.description, "96 kHz · 2 ch · Float32 · interleaved")

        let writer = format.writerFormat
        XCTAssertEqual(writer.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(writer.isInterleaved)
        XCTAssertEqual(writer.sampleRate, 96_000)
        XCTAssertEqual(writer.channelCount, 2)
    }

    func testMissingRateUsesAggregateRate() throws {
        let format = try CaptureFormat(validating: asbd(rate: 0), fallbackSampleRate: 44_100)
        XCTAssertEqual(format.sampleRate, 44_100)
        XCTAssertThrowsError(try CaptureFormat(validating: asbd(rate: 0)))
    }

    func testRejectsZeroChannels() {
        XCTAssertThrowsError(try CaptureFormat(validating: asbd(channels: 0))) { error in
            XCTAssertEqual(error as? CaptureFormat.ValidationError, .invalidChannelCount(0))
        }
    }

    func testRejectsNonPCM() {
        var description = asbd()
        description.mFormatID = kAudioFormatMPEG4AAC
        XCTAssertThrowsError(try CaptureFormat(validating: description)) { error in
            XCTAssertEqual(error as? CaptureFormat.ValidationError, .notLinearPCM("aac "))
        }
    }

    func testRejectsInconsistentFrameSize() {
        XCTAssertThrowsError(try CaptureFormat(validating: asbd(bytesPerFrame: 4)))
    }

    func testIntegerFormats() throws {
        XCTAssertEqual(try CaptureFormat(validating: asbd(bits: 16, float: false)).sampleType, .int16)
        XCTAssertEqual(try CaptureFormat(validating: asbd(bits: 24, float: false)).sampleType, .int24)
        XCTAssertEqual(try CaptureFormat(validating: asbd(bits: 32, float: false, nonInterleaved: true)).isInterleaved, false)
    }

    func testDeliveredRateTrustsTheAggregateWhenRatesDisagree() {
        // 48 kHz tap format on a 96 kHz aggregate: frames arrive at 96 kHz.
        XCTAssertEqual(CaptureFormat.deliveredRate(streamRate: 48_000, aggregateRate: 96_000).rate, 96_000)
        XCTAssertTrue(CaptureFormat.deliveredRate(streamRate: 48_000, aggregateRate: 96_000).overridden)
        XCTAssertEqual(CaptureFormat.deliveredRate(streamRate: 48_000, aggregateRate: 44_100).rate, 44_100)
        XCTAssertFalse(CaptureFormat.deliveredRate(streamRate: 48_000, aggregateRate: 48_000).overridden)
        XCTAssertEqual(CaptureFormat.deliveredRate(streamRate: 48_000, aggregateRate: nil).rate, 48_000)
        XCTAssertEqual(CaptureFormat.deliveredRate(streamRate: 48_000, aggregateRate: 0).rate, 48_000)
        XCTAssertEqual(CaptureFormat.deliveredRate(streamRate: 48_000, aggregateRate: .nan).rate, 48_000)
    }

    func testDiagnosticDescriptionDecodesFormatID() {
        XCTAssertTrue(asbd().diagnosticDescription.contains("id='lpcm'"))
    }
}

final class CaptureBufferCopierTests: XCTestCase {
    private func list(buffers: [(channels: UInt32, data: UnsafeMutableRawPointer, bytes: Int)]) -> UnsafeMutableAudioBufferListPointer {
        let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        for (i, b) in buffers.enumerated() {
            list[i] = AudioBuffer(mNumberChannels: b.channels, mDataByteSize: UInt32(b.bytes), mData: b.data)
        }
        return list
    }

    func testInterleavedFloatIsDeinterleaved() throws {
        var samples: [Float] = [0.1, -0.1, 0.2, -0.2, 0.3, -0.3]
        let format = try CaptureFormat(validating: AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0))
        try samples.withUnsafeMutableBytes { raw in
            let abl = list(buffers: [(2, raw.baseAddress!, raw.count)])
            defer { free(abl.unsafeMutablePointer) }
            let result = try XCTUnwrap(CaptureBufferCopier.copy(abl.unsafePointer, format: format, writerFormat: format.writerFormat))
            XCTAssertFalse(result.layoutMismatch)
            XCTAssertEqual(result.buffer.frameLength, 3)
            let l = result.buffer.floatChannelData![0], r = result.buffer.floatChannelData![1]
            XCTAssertEqual([l[0], l[1], l[2]], [0.1, 0.2, 0.3])
            XCTAssertEqual([r[0], r[1], r[2]], [-0.1, -0.2, -0.3])
        }
    }

    func testNonInterleavedInt16() throws {
        var left: [Int16] = [16_384, -32_768]
        var right: [Int16] = [0, 8_192]
        let format = try CaptureFormat(validating: AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved, mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0))
        try left.withUnsafeMutableBytes { l in
            try right.withUnsafeMutableBytes { r in
                let abl = list(buffers: [(1, l.baseAddress!, l.count), (1, r.baseAddress!, r.count)])
                defer { free(abl.unsafeMutablePointer) }
                let result = try XCTUnwrap(CaptureBufferCopier.copy(abl.unsafePointer, format: format, writerFormat: format.writerFormat))
                let out = result.buffer.floatChannelData!
                XCTAssertEqual([out[0][0], out[0][1]], [0.5, -1.0])
                XCTAssertEqual([out[1][0], out[1][1]], [0.0, 0.25])
            }
        }
    }

    func testSkipsSubDeviceInputBuffers() throws {
        // Aggregate with a sub-device that has an input (mic/loopback) before the tap stream.
        var micInput: [Float] = [0.9, 0.9, 0.9, 0.9]
        var tapStream: [Float] = [0.1, -0.1, 0.2, -0.2]
        var format = try CaptureFormat(validating: AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0))
        format.firstBufferIndex = 1
        format.bufferCount = 1
        try micInput.withUnsafeMutableBytes { mic in
            try tapStream.withUnsafeMutableBytes { tap in
                let abl = list(buffers: [(2, mic.baseAddress!, mic.count), (2, tap.baseAddress!, tap.count)])
                defer { free(abl.unsafeMutablePointer) }
                let result = try XCTUnwrap(CaptureBufferCopier.copy(abl.unsafePointer, format: format, writerFormat: format.writerFormat))
                XCTAssertFalse(result.layoutMismatch)
                let out = result.buffer.floatChannelData!
                XCTAssertEqual([out[0][0], out[0][1]], [0.1, 0.2])
                XCTAssertEqual([out[1][0], out[1][1]], [-0.1, -0.2])
            }
        }
    }

    func testMissingChannelIsZeroFilledAndReported() throws {
        var mono: [Float] = [0.5, 0.5]
        let format = try CaptureFormat(validating: AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0))
        try mono.withUnsafeMutableBytes { raw in
            let abl = list(buffers: [(1, raw.baseAddress!, raw.count)])
            defer { free(abl.unsafeMutablePointer) }
            let result = try XCTUnwrap(CaptureBufferCopier.copy(abl.unsafePointer, format: format, writerFormat: format.writerFormat))
            XCTAssertTrue(result.layoutMismatch)
            XCTAssertEqual(result.buffer.frameLength, 2)
            XCTAssertEqual(result.buffer.floatChannelData![1][0], 0)
        }
    }
}
