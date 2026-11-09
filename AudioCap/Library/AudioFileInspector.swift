import Foundation
import AVFoundation

/// What an audio file says about its length versus what it actually holds.
struct FileAnalysis: Codable, Equatable, Sendable {
    var sampleRate: Double
    var channelCount: Int
    /// Frames the container declares (WAV `data` size, FLAC STREAMINFO, CAF packet table). Players trust this.
    var headerFrames: Int64
    /// Frames that decode when the file is read from start to end.
    var decodedFrames: Int64
    /// For uncompressed WAV/CAF: the frames actually stored in the data chunk, whatever the header says.
    var payloadFrames: Int64?
    /// Largest absolute sample value (linear, 1.0 = 0 dBFS).
    var peak: Float

    var actualFrames: Int64 { max(decodedFrames, payloadFrames ?? 0) }
    var headerDuration: TimeInterval { Double(headerFrames) / sampleRate }
    var decodedDuration: TimeInterval { Double(actualFrames) / sampleRate }
    var lengthMatches: Bool { headerFrames == decodedFrames && (payloadFrames.map { $0 == headerFrames } ?? true) }
    var peakDb: Double { peak > 0 ? max(-240, 20 * log10(Double(peak))) : -240 }
}

/// Reads a file back to measure its real length, peak level and waveform.
enum AudioFileInspector {
    /// - Parameter waveformBins: number of peak values to return for drawing (0 for none).
    static func analyze(_ url: URL, waveformBins: Int = 0) throws -> (analysis: FileAnalysis, waveform: [Float]) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let header = file.length
        let channels = Int(format.channelCount)
        let chunk: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw CocoaError(.fileReadUnknown) }

        var bins = [Float](repeating: 0, count: max(waveformBins, 0))
        var decoded: Int64 = 0
        var peak: Float = 0
        // AVAudioFile throws when asked to read at the end, so never read past the declared length.
        while file.framePosition < header {
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            for frame in 0..<frames {
                var value: Float = 0
                for channel in 0..<channels { value = max(value, abs(data[channel][frame])) }
                peak = max(peak, value)
                if !bins.isEmpty, header > 0 {
                    let index = min(bins.count - 1, Int((decoded + Int64(frame)) * Int64(bins.count) / header))
                    bins[index] = max(bins[index], value)
                }
            }
            decoded += Int64(frames)
        }
        let analysis = FileAnalysis(sampleRate: format.sampleRate, channelCount: channels, headerFrames: header,
                                    decodedFrames: decoded, payloadFrames: pcmPayloadFrames(of: url), peak: peak)
        return (analysis, bins)
    }

    /// Frames stored in the data chunk of an uncompressed WAV or CAF file, read from the bytes on disk rather than
    /// from the header's length field. `nil` for compressed or unknown files.
    static func pcmPayloadFrames(of url: URL) -> Int64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), (try? handle.seek(toOffset: 0)) != nil,
              let head = try? handle.read(upToCount: 12), head.count == 12 else { return nil }
        let reader = ChunkReader(handle: handle, fileSize: Int64(fileSize))
        switch String(decoding: head.prefix(4), as: UTF8.self) {
        case "RIFF" where String(decoding: head[8..<12], as: UTF8.self) == "WAVE": return reader.wavPayloadFrames()
        case "caff": return reader.cafPayloadFrames()
        default: return nil
        }
    }

    private struct ChunkReader {
        let handle: FileHandle
        let fileSize: Int64

        func bytes(at offset: Int64, count: Int) -> Data? {
            guard offset >= 0, offset + Int64(count) <= fileSize, (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let data = try? handle.read(upToCount: count), data.count == count else { return nil }
            return data
        }

        func wavPayloadFrames() -> Int64? {
            var offset: Int64 = 12
            var blockAlign: Int64?
            while let header = bytes(at: offset, count: 8) {
                let id = String(decoding: header.prefix(4), as: UTF8.self)
                let size = Int64(header.littleEndianUInt32(at: 4))
                let start = offset + 8
                if id == "fmt ", let fmt = bytes(at: start, count: 16) {
                    let format = fmt.littleEndianUInt16(at: 0)
                    // 1 = integer PCM, 3 = IEEE float, 0xFFFE = extensible (PCM or float subformat).
                    guard format == 1 || format == 3 || format == 0xFFFE else { return nil }
                    blockAlign = Int64(fmt.littleEndianUInt16(at: 12))
                } else if id == "data" {
                    guard let blockAlign, blockAlign > 0 else { return nil }
                    let onDisk = fileSize - start
                    var bytes = onDisk
                    // A shorter declared size is only legitimate when another chunk follows the audio.
                    if size <= onDisk, isChunkHeader(at: start + size + (size & 1)) || start + size == fileSize {
                        bytes = size
                    }
                    return bytes / blockAlign
                }
                offset = start + size + (size & 1)
            }
            return nil
        }

        func cafPayloadFrames() -> Int64? {
            var offset: Int64 = 8
            var bytesPerFrame: Int64?
            while let header = bytes(at: offset, count: 12) {
                let id = String(decoding: header.prefix(4), as: UTF8.self)
                let size = Int64(bitPattern: header.bigEndianUInt64(at: 4))
                let start = offset + 12
                if id == "desc", let desc = bytes(at: start, count: 32) {
                    guard String(decoding: desc[8..<12], as: UTF8.self) == "lpcm" else { return nil }
                    bytesPerFrame = Int64(desc.bigEndianUInt32(at: 16))
                } else if id == "data" {
                    guard let bytesPerFrame, bytesPerFrame > 0 else { return nil }
                    // The data chunk starts with a 4-byte edit count; size -1 means "until the end of the file".
                    let available = fileSize - start
                    let bytes = (size < 0 || size > available ? available : size) - 4
                    return max(0, bytes) / bytesPerFrame
                }
                guard size >= 0 else { return nil }
                offset = start + size
            }
            return nil
        }

        private func isChunkHeader(at offset: Int64) -> Bool {
            guard let header = bytes(at: offset, count: 8) else { return false }
            let printable = header.prefix(4).allSatisfy { $0 >= 0x20 && $0 < 0x7F }
            return printable && offset + 8 + Int64(header.littleEndianUInt32(at: 4)) <= fileSize
        }
    }
}

private extension Data {
    func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }
    func littleEndianUInt32(at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * UInt32($1)) }
    }
    func bigEndianUInt32(at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 << 8 | UInt32(self[startIndex + offset + $1]) }
    }
    func bigEndianUInt64(at offset: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 << 8 | UInt64(self[startIndex + offset + $1]) }
    }
}
