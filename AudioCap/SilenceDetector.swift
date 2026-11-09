import Foundation
import AVFoundation

/// Level of one buffer, measured across all channels.
struct AudioLevel: Equatable, Sendable {
    /// RMS level in dBFS (`-infinity`-safe: clamped at -240 dB).
    var rmsDb: Double
    /// Peak sample level in dBFS.
    var peakDb: Double

    static let silence = AudioLevel(rmsDb: -240, peakDb: -240)

    /// Measures a Float32 buffer, interleaved or not.
    ///
    /// Interleaved buffers keep every channel in `floatChannelData[0]` with a stride of `channelCount`;
    /// only deinterleaved buffers have one pointer per channel.
    init(measuring buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, let data = buffer.floatChannelData else {
            self = .silence
            return
        }
        var sumSquares: Double = 0
        var peak: Float = 0
        let sampleCount = frames * channels
        if buffer.format.isInterleaved {
            let samples = data[0]
            for i in 0..<sampleCount {
                let s = samples[i]
                sumSquares += Double(s) * Double(s)
                peak = max(peak, abs(s))
            }
        } else {
            for c in 0..<channels {
                let samples = data[c]
                for i in 0..<frames {
                    let s = samples[i]
                    sumSquares += Double(s) * Double(s)
                    peak = max(peak, abs(s))
                }
            }
        }
        self.rmsDb = Self.dbfs(sqrt(sumSquares / Double(sampleCount)))
        self.peakDb = Self.dbfs(Double(peak))
    }

    init(rmsDb: Double, peakDb: Double) {
        self.rmsDb = rmsDb
        self.peakDb = peakDb
    }

    static func dbfs(_ linear: Double) -> Double {
        20.0 * log10(max(linear, 1e-12))
    }
}

/// Performs RMS-based silence detection over incoming audio buffers.
/// - Computes the RMS level across all channels and converts it to dBFS.
/// - Accumulates continuous silence and reports a split once it crosses `minSilenceDuration`.
/// - After a split, `isInSplitSilence` stays `true` until sound resumes, so callers can drop the rest of
///   the silence instead of writing it into the next file.
struct SilenceDetector {
    /// dBFS threshold at or under which audio is considered silent (e.g. -60 dB).
    var thresholdDb: Double
    /// Minimum continuous silence duration in seconds required to trigger a split.
    var minSilenceDuration: Double

    /// Accumulated silence (seconds) while RMS stays under threshold.
    private(set) var accumulatedSilence: Double = 0
    /// `true` after a split was triggered, until sound resumes.
    private(set) var isInSplitSilence = false

    struct Analysis: Equatable {
        var isSilent: Bool
        var rmsDb: Double
        /// `true` exactly once per silence period, on the buffer that reached `minSilenceDuration`.
        var didTriggerSplit: Bool
        /// `true` when the buffer is silence following an already triggered split: don't write it.
        var shouldDrop: Bool
        var silentDuration: Double
    }

    init(thresholdDb: Double, minSilenceDuration: Double) {
        self.thresholdDb = thresholdDb
        self.minSilenceDuration = minSilenceDuration
    }

    mutating func reset() {
        accumulatedSilence = 0
        isInSplitSilence = false
    }

    mutating func process(buffer: AVAudioPCMBuffer) -> Analysis {
        process(level: AudioLevel(measuring: buffer), duration: Double(buffer.frameLength) / buffer.format.sampleRate)
    }

    mutating func process(level: AudioLevel, duration: Double) -> Analysis {
        let isSilent = level.rmsDb <= thresholdDb
        guard isSilent else {
            reset()
            return Analysis(isSilent: false, rmsDb: level.rmsDb, didTriggerSplit: false, shouldDrop: false, silentDuration: 0)
        }
        if isInSplitSilence {
            accumulatedSilence += duration
            return Analysis(isSilent: true, rmsDb: level.rmsDb, didTriggerSplit: false, shouldDrop: true, silentDuration: accumulatedSilence)
        }
        accumulatedSilence += duration
        // Small tolerance: buffer durations summed as Doubles fall just short of round values.
        let trigger = accumulatedSilence >= minSilenceDuration - 1e-9
        if trigger { isInSplitSilence = true }
        return Analysis(isSilent: true, rmsDb: level.rmsDb, didTriggerSplit: trigger, shouldDrop: trigger, silentDuration: accumulatedSilence)
    }
}
