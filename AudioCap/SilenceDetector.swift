import Foundation
import AVFoundation

/// Performs RMS-based silence detection over incoming audio buffers.
/// - Computes RMS amplitude and converts to dBFS.
/// - Accumulates continuous silence duration and reports when it crosses the configured minimum.
struct SilenceDetector {
    /// dBFS threshold under which audio is considered silent (e.g. -40 dB).
    var thresholdDb: Double
    /// Minimum continuous silence duration in seconds required to trigger a split.
    var minSilenceDuration: Double

    /// Accumulated silence (seconds) while RMS stays under threshold.
    private(set) var accumulatedSilence: Double = 0
    /// Set after a split is triggered during the current silence period, until sound resumes.
    private var splitTriggeredForCurrentSilence = false

    /// Public initializer to avoid private memberwise init due to private properties.
    init(thresholdDb: Double, minSilenceDuration: Double) {
        self.thresholdDb = thresholdDb
        self.minSilenceDuration = minSilenceDuration
        self.accumulatedSilence = 0
        self.splitTriggeredForCurrentSilence = false
    }

    /// Resets accumulated silence and the split flag, typically called when non-silent audio is observed.
    mutating func reset() {
        accumulatedSilence = 0
        splitTriggeredForCurrentSilence = false
    }

    /// Processes an incoming buffer and returns silence analysis results.
    mutating func process(buffer: AVAudioPCMBuffer) -> (isSilent: Bool, rmsDb: Double, didTriggerSplit: Bool, silentDuration: Double) {
        let rms = Self.computeRMS(buffer)
        let rmsDb = Self.dbfs(fromLinear: rms)
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate

        var didTriggerSplit = false

        if rmsDb <= thresholdDb {
            accumulatedSilence += duration
            if accumulatedSilence >= minSilenceDuration, !splitTriggeredForCurrentSilence {
                didTriggerSplit = true
                splitTriggeredForCurrentSilence = true
            }
        } else {
            // Non-silent audio resets silence accumulation and allows future splits
            reset()
        }

        return (rmsDb <= thresholdDb, rmsDb, didTriggerSplit, accumulatedSilence)
    }

    /// Computes RMS amplitude across all channels for the provided buffer.
    private static func computeRMS(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData else { return 0.0 }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        if frameCount == 0 || channelCount == 0 { return 0.0 }

        var sumSquares: Double = 0
        for ch in 0..<channelCount {
            let samples = channelData[ch]
            var channelSum: Double = 0
            // Iterate samples and sum squares
            for i in 0..<frameCount {
                let s = Double(samples[i])
                channelSum += s * s
            }
            sumSquares += channelSum
        }
        let meanSquare = sumSquares / Double(frameCount * max(channelCount, 1))
        return sqrt(meanSquare)
    }

    /// Converts linear amplitude to dBFS, clamping at a very small epsilon to avoid -inf.
    private static func dbfs(fromLinear linear: Double) -> Double {
        let epsilon = 1e-12
        return 20.0 * log10(max(linear, epsilon))
    }
}