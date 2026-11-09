import Foundation
import AVFoundation

/// Exports a capture file to the user's chosen format through one conversion path.
///
/// Every export reads the source in chunks, lets `AVAudioFile` encode, closes the destination explicitly
/// (which flushes the encoder's final partial block) and then checks the duration of the result
/// against the frames that were captured.
enum AudioExporter {
    struct Result: Equatable, Sendable {
        var url: URL
        var format: RecordingSettings.OutputFormat
        /// Frames in the exported file, at `sampleRate`.
        var frameCount: AVAudioFramePosition
        var sampleRate: Double
        var duration: TimeInterval { Double(frameCount) / sampleRate }
    }

    enum ExportError: LocalizedError, Equatable {
        case emptySource
        case tooShort(format: RecordingSettings.OutputFormat, frames: AVAudioFramePosition, minimumFrames: AVAudioFramePosition)
        case durationMismatch(url: URL, expectedFrames: AVAudioFramePosition, actualFrames: AVAudioFramePosition, sampleRate: Double)

        var errorDescription: String? {
            switch self {
            case .emptySource:
                "The recording has no audio."
            case .tooShort(let format, let frames, let minimum):
                "The take has \(frames) frames; \(format.displayName) needs at least \(minimum). Keep it as WAV instead."
            case .durationMismatch(let url, let expected, let actual, let rate):
                String(format: "%@ has %lld frames (%.3f s), expected %lld frames (%.3f s).",
                       url.lastPathComponent, actual, Double(actual) / rate, expected, Double(expected) / rate)
            }
        }
    }

    /// AAC in Apple's encoder supports at most 48 kHz; higher capture rates are resampled for AAC only.
    static let maxAACSampleRate: Double = 48_000

    /// Apple's FLAC encoder writes an unreadable file when the whole input is shorter than one 4,608-frame block.
    static let minimumFLACFrames: AVAudioFramePosition = 4_608

    /// The file settings for `format` at the capture's rate and channel count.
    static func fileSettings(for format: RecordingSettings.OutputFormat, sampleRate: Double, channelCount: AVAudioChannelCount) -> [String: Any] {
        var settings: [String: Any] = [
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
        ]
        switch format {
        case .wav:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = true
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
            settings[AVEncoderBitDepthHintKey] = 24
        case .alac:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = 24
        case .aac:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVSampleRateKey] = min(sampleRate, maxAACSampleRate)
            settings[AVEncoderBitRateKey] = 256_000
            settings[AVEncoderAudioQualityKey] = AVAudioQuality.max.rawValue
        }
        return settings
    }

    /// Exports `sourceURL` to `destinationURL`.
    ///
    /// - Parameters:
    ///   - expectedFrames: frames captured; defaults to the source length. The result must match it exactly
    ///     (or within one frame per resampled second boundary when AAC resamples).
    ///   - progress: called with values from 0 to 1 on the calling thread.
    /// - Throws: `ExportError`, or the underlying AVFAudio error (decode it with `audioCapDescription`).
    ///   A failed export removes the partial destination file.
    @discardableResult
    static func export(from sourceURL: URL,
                       to destinationURL: URL,
                       format: RecordingSettings.OutputFormat,
                       expectedFrames: AVAudioFramePosition? = nil,
                       chunkSize: AVAudioFrameCount = 32_768,
                       progress: ((Double) -> Void)? = nil) throws -> Result {
        do {
            return try performExport(from: sourceURL, to: destinationURL, format: format, expectedFrames: expectedFrames, chunkSize: chunkSize, progress: progress)
        } catch {
            if sourceURL.standardizedFileURL != destinationURL.standardizedFileURL {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            throw error
        }
    }

    private static func performExport(from sourceURL: URL,
                                      to destinationURL: URL,
                                      format: RecordingSettings.OutputFormat,
                                      expectedFrames: AVAudioFramePosition?,
                                      chunkSize: AVAudioFrameCount,
                                      progress: ((Double) -> Void)?) throws -> Result {
        let source = try AVAudioFile(forReading: sourceURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = source.length
        let expected = expectedFrames ?? total
        guard total > 0 else { throw ExportError.emptySource }
        if format == .flac, total < minimumFLACFrames {
            throw ExportError.tooShort(format: format, frames: total, minimumFrames: minimumFLACFrames)
        }

        let processingFormat = source.processingFormat
        let settings = fileSettings(for: format, sampleRate: processingFormat.sampleRate, channelCount: processingFormat.channelCount)
        try? FileManager.default.removeItem(at: destinationURL)
        let destination = try AVAudioFile(forWriting: destinationURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)

        let outputRate = settings[AVSampleRateKey] as? Double ?? processingFormat.sampleRate
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: chunkSize) else {
            throw CocoaError(.fileWriteUnknown)
        }
        progress?(0)
        if outputRate == processingFormat.sampleRate {
            while source.framePosition < total {
                try source.read(into: buffer, frameCount: chunkSize)
                guard buffer.frameLength > 0 else { break }
                try destination.write(from: buffer)
                progress?(Double(source.framePosition) / Double(total))
            }
        } else {
            // AVAudioFile does not resample on write, so convert the rate explicitly.
            try resample(source, total: total, through: buffer, into: destination, progress: progress)
        }
        destination.close()

        let frames = try verifyDuration(of: destinationURL, expectedFrames: expected, captureSampleRate: processingFormat.sampleRate)
        progress?(1)
        return Result(url: destinationURL, format: format, frameCount: frames, sampleRate: outputRate)
    }

    private static func resample(_ source: AVAudioFile, total: AVAudioFramePosition, through input: AVAudioPCMBuffer,
                                 into destination: AVAudioFile, progress: ((Double) -> Void)?) throws {
        let outputFormat = destination.processingFormat
        guard let converter = AVAudioConverter(from: source.processingFormat, to: outputFormat),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: input.frameCapacity) else {
            throw CocoaError(.fileWriteUnknown)
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        var readError: Error?
        while true {
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                // Never read past the end: AVAudioFile throws when asked to read at EOF.
                guard readError == nil, source.framePosition < total else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try source.read(into: input, frameCount: input.frameCapacity)
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = input.frameLength > 0 ? .haveData : .endOfStream
                return input.frameLength > 0 ? input : nil
            }
            if let readError { throw readError }
            if status == .error { throw conversionError ?? CocoaError(.fileWriteUnknown) }
            if output.frameLength > 0 { try destination.write(from: output) }
            progress?(Double(source.framePosition) / Double(total))
            if status == .endOfStream { break }
        }
    }

    /// Checks that the file at `url` holds exactly the captured audio.
    ///
    /// At the capture rate the frame count must match exactly. When the file was resampled (AAC above 48 kHz),
    /// it must match the rescaled count within two frames.
    /// - Returns: the frame count of the file.
    @discardableResult
    static func verifyDuration(of url: URL, expectedFrames: AVAudioFramePosition, captureSampleRate: Double) throws -> AVAudioFramePosition {
        let file = try AVAudioFile(forReading: url)
        let actual = file.length
        let rate = file.fileFormat.sampleRate
        if rate == captureSampleRate {
            guard actual == expectedFrames else {
                throw ExportError.durationMismatch(url: url, expectedFrames: expectedFrames, actualFrames: actual, sampleRate: rate)
            }
        } else {
            let scaled = AVAudioFramePosition((Double(expectedFrames) * rate / captureSampleRate).rounded())
            guard abs(actual - scaled) <= 2 else {
                throw ExportError.durationMismatch(url: url, expectedFrames: scaled, actualFrames: actual, sampleRate: rate)
            }
        }
        return actual
    }
}
