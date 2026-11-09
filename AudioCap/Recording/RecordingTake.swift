import Foundation
import AVFoundation

/// One continuous capture: a CAF intermediate and the file it is exported to.
///
/// A recording session produces several takes when it splits on silence, when the capture format changes
/// (for example after switching output devices) or when the source app quits and comes back.
struct RecordingTake: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        /// Audio is being written to `captureURL`.
        case recording
        /// Capture closed, export to `outputURL` in progress.
        case exporting(progress: Double)
        /// `outputURL` exists and its duration matches `capturedFrames`.
        case completed
        /// Capture or export failed. The CAF intermediate is kept when it exists.
        case failed(message: String)

        var isFinal: Bool {
            switch self {
            case .completed, .failed: true
            case .recording, .exporting: false
            }
        }
    }

    let id: UUID
    let sourceName: String
    let startedAt: Date
    /// The crash-safe CAF intermediate. Deleted after a successful export.
    let captureURL: URL
    /// Where the export goes.
    let outputURL: URL
    let outputFormat: RecordingSettings.OutputFormat
    /// The validated device format the take was captured from.
    let captureFormat: CaptureFormat

    var status: Status = .recording
    /// Frames in the closed capture file (or frames queued so far while recording).
    var capturedFrames: AVAudioFramePosition = 0
    /// Frames in the exported file once completed (at the export's rate).
    var exportedFrames: AVAudioFramePosition?
    /// A problem worth showing even though the take was saved (digital silence, dropped frames).
    var warning: String?

    /// For example "96 kHz · 2 ch · Float32 · interleaved".
    var captureFormatDescription: String { captureFormat.description }
    var duration: TimeInterval { Double(capturedFrames) / captureFormat.sampleRate }
}

/// Changes to the take list, in order. See `ProcessTapRecorder.takeEvents()`.
enum TakeEvent: Equatable, Sendable {
    case added(RecordingTake)
    case updated(RecordingTake)
    /// A take with no audio was discarded.
    case removed(RecordingTake.ID)
}
