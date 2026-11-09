import Foundation
import AVFoundation
import os

/// Owns one capture file and serializes every write to it.
///
/// Capture goes to a CAF file in the canonical Float32 format. CAF keeps the audio readable up to the
/// last written packet even if the app crashes or is force-quit before `finish()`, unlike WAV, whose
/// header only gets the final length on close.
///
/// `append(_:)` can be called from any thread; buffers are written in order on the writer's serial queue.
/// `finish()` drains that queue, closes the file explicitly and checks the frame count on disk.
final class CaptureWriter: @unchecked Sendable {
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

    private let queue: DispatchQueue
    private let logger = Logger(subsystem: kAppSubsystem, category: "CaptureWriter")
    /// Only touched on `queue`.
    private var file: AVAudioFile?
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var framesWritten: AVAudioFramePosition = 0
        var error: Error?
        var finished = false
    }

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
        self.queue = DispatchQueue(label: "CaptureWriter(\(url.lastPathComponent))", qos: .userInitiated)
        self.file = try AVAudioFile(forWriting: url, settings: Self.fileSettings(for: format), commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Frames written to disk so far.
    var framesWritten: AVAudioFramePosition { state.withLock { $0.framesWritten } }

    /// The first write error, if any. Once set, further buffers are dropped and `finish()` throws it.
    var error: Error? { state.withLock { $0.error } }

    /// Queues `buffer` for writing. The buffer must not be modified afterwards.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        queue.async { [self] in
            guard let file, state.withLock({ $0.error == nil }) else { return }
            do {
                guard buffer.format.isEqual(format) else {
                    throw WriterError.formatMismatch(expected: "\(format)", received: "\(buffer.format)")
                }
                try file.write(from: buffer)
                state.withLock { $0.framesWritten += AVAudioFramePosition(buffer.frameLength) }
            } catch {
                logger.error("Write failed: \(error.audioCapDescription, privacy: .public)")
                state.withLock { $0.error = error }
            }
        }
    }

    /// Waits until every queued buffer has been written.
    func drain() {
        queue.sync {}
    }

    /// Drains pending writes, closes the file and checks that the file on disk has every frame written.
    /// - Returns: the number of frames in the file.
    @discardableResult
    func finish() throws -> AVAudioFramePosition {
        let alreadyFinished = state.withLock { state in
            defer { state.finished = true }
            return state.finished
        }
        guard !alreadyFinished else { throw WriterError.alreadyFinished }

        queue.sync {
            file?.close()
            file = nil
        }
        let (written, error) = state.withLock { ($0.framesWritten, $0.error) }
        if let error { throw error }

        let onDisk = try AVAudioFile(forReading: url).length
        guard onDisk == written else { throw WriterError.frameCountMismatch(expected: written, onDisk: onDisk) }
        return onDisk
    }

    deinit {
        if file != nil {
            file?.close()
        }
    }
}
