import Foundation
import AVFoundation
import XCTest

/// Synthetic audio helpers. No tap, device or permission needed.
enum Synth {
    /// A deinterleaved Float32 buffer whose samples are exact 24-bit values (k / 2^23), so lossless
    /// 24-bit codecs must round-trip them bit for bit.
    static func buffer(frames: Int, sampleRate: Double = 44_100, channels: Int = 2, seed: UInt64 = 1, amplitude: Float = 0.8) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        var state = seed
        for c in 0..<channels {
            let data = buffer.floatChannelData![c]
            for i in 0..<frames {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let noise = Float(Int32(truncatingIfNeeded: state >> 33) % 1000) / 1000 * 0.1
                let tone = sin(Float(i) * 2 * .pi * Float(220 * (c + 1)) / Float(sampleRate))
                let value = (tone * 0.9 + noise) * amplitude
                data[i] = quantize24(value)
            }
        }
        return buffer
    }

    static func quantize24(_ value: Float) -> Float {
        let scaled = (max(-1, min(value, 1 - 1 / 8_388_608)) * 8_388_608).rounded()
        return scaled / 8_388_608
    }

    static func constant(_ value: Float, frames: Int, sampleRate: Double = 48_000, channels: Int = 2, interleaved: Bool) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: interleaved)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = buffer.floatChannelData!
        if interleaved {
            data[0].update(repeating: value, count: frames * channels)
        } else {
            for c in 0..<channels { data[c].update(repeating: value, count: frames) }
        }
        return buffer
    }

    /// Writes `buffer` to a CAF in the canonical capture format, in chunks of `chunk` frames.
    static func writeCAF(_ buffer: AVAudioPCMBuffer, to url: URL, chunk: Int = 4_410) throws {
        let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var offset = 0
        while offset < Int(buffer.frameLength) {
            let n = min(chunk, Int(buffer.frameLength) - offset)
            try file.write(from: slice(buffer, from: offset, count: n))
            offset += n
        }
        file.close()
    }

    static func slice(_ buffer: AVAudioPCMBuffer, from start: Int, count: Int) -> AVAudioPCMBuffer {
        let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count))!
        out.frameLength = AVAudioFrameCount(count)
        for c in 0..<Int(buffer.format.channelCount) {
            out.floatChannelData![c].update(from: buffer.floatChannelData![c] + start, count: count)
        }
        return out
    }

    static func readAll(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(file.length, 1)))!
        if file.length > 0 { try file.read(into: buffer) }
        return buffer
    }

    /// The largest absolute sample difference over the shorter of the two buffers.
    static func maxDifference(_ a: AVAudioPCMBuffer, _ b: AVAudioPCMBuffer) -> Float {
        let frames = Int(min(a.frameLength, b.frameLength))
        var maxDiff: Float = 0
        for c in 0..<Int(min(a.format.channelCount, b.format.channelCount)) {
            let x = a.floatChannelData![c], y = b.floatChannelData![c]
            for i in 0..<frames { maxDiff = max(maxDiff, abs(x[i] - y[i])) }
        }
        return maxDiff
    }
}

class TemporaryDirectoryTestCase: XCTestCase {
    private(set) var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AudioCapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
}
