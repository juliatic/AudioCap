import Foundation
import AVFoundation

/// Owns one capture file.
///
/// Capture goes to a CAF file in the canonical Float32 format. CAF keeps the audio readable up to the
/// last written packet even if the app crashes or is force-quit before `finish()`, unlike WAV, whose
/// header only gets the final length on close.
///
/// Not thread-safe: the owner calls it from one serial queue (the recorder's writer queue).
/// `finish()` closes the file explicitly and checks the frame count on disk.
final class CaptureWriter {
    enum WriterError: LocalizedError, Equatable {
        case frameCountMismatch(expected: AVAudioFramePosition, onDisk: AVAudioFramePosition)
        case formatMismatch(expected: String, received: String)
        case alreadyFinished

        var errorDescription: String? {
            switch self {
            case .frameCountMismatch(let expected, let onDisk):
                String(localized: "The capture file has \(onDisk) frames, but \(expected) were written.")
            case .formatMismatch(let expected, let received):
                String(localized: "A buffer in format \(received) was sent to a capture file in format \(expected).")
            case .alreadyFinished:
                String(localized: "The capture file was already closed.")
            }
        }
    }

    let url: URL
    /// The canonical format of the file (Float32, deinterleaved processing format).
    let format: AVAudioFormat

    private var file: AVAudioFile?
    /// Frames written to disk so far.
    private(set) var framesWritten: AVAudioFramePosition = 0
    /// The first write error, if any. Once set, further buffers are dropped and `finish()` throws it.
    private(set) var error: Error?

    /// The settings the capture file is created with (CAF, Float32 linear PCM).
    static func fileSettings(for format: AVAudioFormat) -> [String: Any] {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        if let layout = format.channelLayout {
            settings[AVChannelLayoutKey] = Data(bytes: layout.layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        return settings
    }

    init(url: URL, format: AVAudioFormat) throws {
        precondition(format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved, "CaptureWriter needs the canonical capture format")
        self.url = url
        self.format = format
        self.file = try AVAudioFile(forWriting: url, settings: Self.fileSettings(for: format), commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Writes `buffer` now. The buffer can be reused as soon as this returns.
    func write(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let file, error == nil else { return }
        do {
            guard buffer.format.isEqual(format) else {
                throw WriterError.formatMismatch(expected: "\(format)", received: "\(buffer.format)")
            }
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
        } catch {
            self.error = error
        }
    }

    /// Closes the file and checks that the file on disk has every frame written.
    /// - Returns: the number of frames in the file.
    @discardableResult
    func finish() throws -> AVAudioFramePosition {
        guard let file else { throw WriterError.alreadyFinished }
        file.close()
        self.file = nil
        if let error { throw error }

        let onDisk = try AVAudioFile(forReading: url).length
        guard onDisk == framesWritten else { throw WriterError.frameCountMismatch(expected: framesWritten, onDisk: onDisk) }
        return onDisk
    }

    deinit {
        file?.close()
    }
}
