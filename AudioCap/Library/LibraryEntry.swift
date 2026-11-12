import Foundation
import AVFoundation

extension RecordingSettings.OutputFormat: Codable {}

/// One take in the recordings library, as stored in the JSON index.
struct LibraryEntry: Codable, Identifiable, Equatable, Sendable {
    enum Status: Codable, Equatable, Sendable {
        case recording
        case converting(progress: Double)
        case done
        case failed(reason: String)

        var isBusy: Bool {
            switch self {
            case .recording, .converting: true
            case .done, .failed: false
            }
        }

        /// The library only accepts these changes; anything else (for example a late progress update after
        /// the take is done) is ignored.
        static func canTransition(from old: Status, to new: Status) -> Bool {
            switch (old, new) {
            case (.recording, _): true
            case (.converting, .recording): false
            case (.converting, _): true
            case (.done, .done): true
            case (.done, _): false
            case (.failed, .converting), (.failed, .failed): true
            case (.failed, _): false
            }
        }

        init(_ status: RecordingTake.Status) {
            switch status {
            case .recording: self = .recording
            case .exporting(let progress): self = .converting(progress: progress)
            case .completed: self = .done
            case .failed(let message): self = .failed(reason: message)
            }
        }
    }

    let id: UUID
    var source: TakeSource
    var startedAt: Date
    /// The exported file.
    var fileURL: URL
    /// The CAF intermediate; kept on disk only while recording, converting or after a failure.
    var captureURL: URL
    var outputFormat: RecordingSettings.OutputFormat
    /// Rate and channels of the capture.
    var sampleRate: Double
    var channelCount: Int
    var capturedFrames: Int64
    var exportedFrames: Int64?
    var status: Status
    /// Filled in once the exported file has been read back.
    var analysis: FileAnalysis?
    /// The recorder's warnings for a saved take (digital silence, dropped frames, timeline gaps).
    var warnings: [TakeWarning]

    init(take: RecordingTake) {
        id = take.id
        source = take.source
        startedAt = take.startedAt
        fileURL = take.outputURL
        captureURL = take.captureURL
        outputFormat = take.outputFormat
        sampleRate = take.captureFormat.sampleRate
        channelCount = take.captureFormat.channelCount
        capturedFrames = take.capturedFrames
        exportedFrames = take.exportedFrames
        status = Status(take.status)
        warnings = take.warnings
    }

    var sourceName: String { source.displayName() }

    var displayName: String { fileURL.deletingPathExtension().lastPathComponent }

    /// The rate the exported file is written at (AAC is limited to 48 kHz).
    var fileSampleRate: Double {
        outputFormat == .aac ? min(sampleRate, AudioExporter.maxAACSampleRate) : sampleRate
    }

    var duration: TimeInterval {
        if let analysis { return analysis.decodedDuration }
        return sampleRate > 0 ? Double(capturedFrames) / sampleRate : 0
    }

    /// Captured frames rescaled to the file's rate, as the exporter verifies them.
    var expectedFileFrames: Int64 {
        fileSampleRate == sampleRate ? capturedFrames : Int64((Double(capturedFrames) * fileSampleRate / sampleRate).rounded())
    }

    /// `true` when the file's header, its decodable audio and the captured frames all agree.
    var lengthIsConsistent: Bool? {
        guard let analysis else { return nil }
        guard analysis.lengthMatches else { return false }
        guard capturedFrames > 0 else { return true }
        return abs(analysis.headerFrames - expectedFileFrames) <= 2
    }

    mutating func update(from take: RecordingTake) {
        capturedFrames = take.capturedFrames
        exportedFrames = take.exportedFrames
        sampleRate = take.captureFormat.sampleRate
        channelCount = take.captureFormat.channelCount
        warnings = take.warnings
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, startedAt, fileURL, captureURL, outputFormat, sampleRate, channelCount, capturedFrames, exportedFrames,
             status, analysis, warnings
        /// Written by builds that stored the source name and the warnings as text.
        case sourceName, warning
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        if let source = try container.decodeIfPresent(TakeSource.self, forKey: .source) {
            self.source = source
        } else {
            source = TakeSource(legacyName: try container.decode(String.self, forKey: .sourceName))
        }
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        fileURL = try container.decode(URL.self, forKey: .fileURL)
        captureURL = try container.decode(URL.self, forKey: .captureURL)
        outputFormat = try container.decode(RecordingSettings.OutputFormat.self, forKey: .outputFormat)
        sampleRate = try container.decode(Double.self, forKey: .sampleRate)
        channelCount = try container.decode(Int.self, forKey: .channelCount)
        capturedFrames = try container.decode(Int64.self, forKey: .capturedFrames)
        exportedFrames = try container.decodeIfPresent(Int64.self, forKey: .exportedFrames)
        status = try container.decode(Status.self, forKey: .status)
        analysis = try container.decodeIfPresent(FileAnalysis.self, forKey: .analysis)
        if let warnings = try container.decodeIfPresent([TakeWarning].self, forKey: .warnings) {
            self.warnings = warnings
        } else {
            warnings = try container.decodeIfPresent(String.self, forKey: .warning).map(TakeWarning.parseLegacy) ?? []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(source, forKey: .source)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(fileURL, forKey: .fileURL)
        try container.encode(captureURL, forKey: .captureURL)
        try container.encode(outputFormat, forKey: .outputFormat)
        try container.encode(sampleRate, forKey: .sampleRate)
        try container.encode(channelCount, forKey: .channelCount)
        try container.encode(capturedFrames, forKey: .capturedFrames)
        try container.encodeIfPresent(exportedFrames, forKey: .exportedFrames)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(analysis, forKey: .analysis)
        try container.encode(warnings, forKey: .warnings)
    }
}
