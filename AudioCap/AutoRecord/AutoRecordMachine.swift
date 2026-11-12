import Foundation
import AVFoundation

/// Receives the takes decided by `AutoRecordMachine`.
protocol TakeSink {
    /// Opens a new take. Return `false` when it could not be created; nothing is written then.
    mutating func openTake() -> Bool
    /// Appends audio to the open take. The buffer is not touched by the machine afterwards.
    mutating func write(_ buffer: AVAudioPCMBuffer)
    /// Closes the open take.
    mutating func closeTake()
}

/// Decides when takes open and close: the "Wait for sound" mode (auto-record) and the manual mode.
///
/// Wait for sound: while **armed**, nothing is written and the last `preRoll` seconds are kept in a ring.
/// The first buffer whose RMS level is above `thresholdDb` opens a take, which starts with that pre-roll, so the
/// first note is not cut. Once **recording**, a buffer at or below the threshold starts a silent run
/// (**closing**): its first `tail` seconds are written, the rest is held back. Sound before `minSilence`
/// seconds of silence writes the held frames and goes back to recording; `minSilence` seconds of silence
/// close the take (the held frames are dropped, so the take ends with a `tail` of silence) and re-arm.
///
/// Manual: the take opens on the first buffer and everything is written until `stop`.
///
/// Pure logic, no CoreAudio: the rings are allocated in `init`, and `process` only allocates a buffer when it
/// hands the pre-roll or the held silence to the sink. It may shorten the `frameLength` of the buffer it
/// receives (when only its start belongs to the tail). Not thread-safe: call it from one queue.
final class AutoRecordMachine {
    enum Mode: String, CaseIterable, Sendable {
        case waitForSound
        case manual
    }

    enum Phase: Equatable, Sendable {
        case idle
        /// Waiting for sound; nothing is written.
        case armed
        /// A take is open (or, in manual mode, opens with the next buffer).
        case recording
        /// Silence after sound: the take closes unless sound comes back in time.
        case closing
    }

    struct Configuration: Equatable, Sendable {
        /// A buffer is sound when its RMS level is above this (dBFS); at or below it is silence.
        var thresholdDb: Double = -60
        /// Seconds of silence that close a take.
        var minSilence: Double = 2
        /// Seconds kept before the buffer that opens a take.
        var preRoll: Double = 0.5
        /// Seconds of silence kept at the end of a take.
        var tail: Double = 0.5
    }

    let configuration: Configuration
    let format: AVAudioFormat
    private(set) var mode: Mode
    private(set) var phase: Phase = .idle
    private(set) var isTakeOpen = false

    let preRollFrames: Int
    let tailFrames: Int
    let minSilenceFrames: Int

    private let preRollRing: AudioRingBuffer
    private let holdRing: AudioRingBuffer
    /// Frames in the current silent run (closing phase).
    private var silentFrames = 0

    /// - Parameter format: deinterleaved Float32, the format of every buffer passed to `process`.
    init(configuration: Configuration, format: AVAudioFormat, mode: Mode) {
        precondition(format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved)
        self.configuration = configuration
        self.format = format
        self.mode = mode
        let rate = format.sampleRate
        let channels = Int(format.channelCount)
        minSilenceFrames = max(1, Int((configuration.minSilence * rate).rounded()))
        tailFrames = min(max(0, Int((configuration.tail * rate).rounded())), minSilenceFrames)
        preRollFrames = max(0, Int((configuration.preRoll * rate).rounded()))
        preRollRing = AudioRingBuffer(capacity: max(preRollFrames, 1), channelCount: channels)
        // A silent run shorter than `minSilenceFrames` holds at most `minSilenceFrames - tailFrames - 1` frames.
        holdRing = AudioRingBuffer(capacity: max(minSilenceFrames - tailFrames, 1), channelCount: channels)
    }

    /// Frames waiting in the pre-roll ring (armed phase).
    var preRollCount: Int { preRollRing.count }
    /// Silent frames held back in the closing phase.
    var heldCount: Int { holdRing.count }

    /// Arms (wait for sound) or starts recording (manual).
    func start() {
        resetBuffers()
        isTakeOpen = false
        phase = mode == .waitForSound ? .armed : .recording
    }

    /// Closes the open take, dropping held silence, and goes idle.
    func stop<S: TakeSink>(sink: inout S) {
        endTake(sink: &sink)
        phase = .idle
        resetBuffers()
    }

    /// Ends the open take now (format change, source quit, split on silence). Held silence is dropped.
    /// Then re-arms (wait for sound) or opens a new take with the next buffer (manual).
    func endTake<S: TakeSink>(sink: inout S) {
        guard phase != .idle else { return }
        if isTakeOpen {
            sink.closeTake()
            isTakeOpen = false
        }
        resetBuffers()
        phase = mode == .waitForSound ? .armed : .recording
    }

    /// Switches mode while running. Nothing already captured is lost:
    /// - to manual: an armed machine opens a take with the next buffer (the pre-roll is dropped); a closing one
    ///   writes its held silence and keeps recording.
    /// - to wait for sound: an open take continues and closes on silence; without a take the machine arms.
    func setMode<S: TakeSink>(_ newMode: Mode, sink: inout S) {
        guard newMode != mode else { return }
        mode = newMode
        switch (newMode, phase) {
        case (_, .idle):
            break
        case (.manual, .armed):
            resetBuffers()
            phase = .recording
        case (.manual, .closing):
            flushHeld(sink: &sink)
            phase = .recording
        case (.manual, .recording):
            break
        case (.waitForSound, .recording):
            silentFrames = 0
            if !isTakeOpen {
                resetBuffers()
                phase = .armed
            }
        case (.waitForSound, _):
            break
        }
    }

    /// Feeds one buffer with its measured level.
    func process<S: TakeSink>(_ buffer: AVAudioPCMBuffer, level: AudioLevel, sink: inout S) {
        let frames = Int(buffer.frameLength)
        guard phase != .idle, frames > 0 else { return }

        if mode == .manual {
            if !isTakeOpen {
                guard sink.openTake() else { return }
                isTakeOpen = true
            }
            sink.write(buffer)
            return
        }

        let isSound = level.rmsDb > configuration.thresholdDb
        switch phase {
        case .idle:
            return
        case .armed:
            guard isSound else {
                if preRollFrames > 0 { preRollRing.append(buffer) }
                return
            }
            guard sink.openTake() else {
                if preRollFrames > 0 { preRollRing.append(buffer) }
                return
            }
            isTakeOpen = true
            if let preRoll = preRollRing.makeBuffer(format: format) { sink.write(preRoll) }
            preRollRing.removeAll()
            silentFrames = 0
            phase = .recording
            sink.write(buffer)
        case .recording:
            if isSound {
                sink.write(buffer)
            } else {
                silentFrames = 0
                phase = .closing
                handleSilence(buffer, frames: frames, sink: &sink)
            }
        case .closing:
            if isSound {
                flushHeld(sink: &sink)
                phase = .recording
                sink.write(buffer)
            } else {
                handleSilence(buffer, frames: frames, sink: &sink)
            }
        }
    }

    // MARK: - Private

    private func handleSilence<S: TakeSink>(_ buffer: AVAudioPCMBuffer, frames: Int, sink: inout S) {
        let before = silentFrames
        silentFrames += frames
        let toTail = min(frames, max(0, tailFrames - before))

        if silentFrames >= minSilenceFrames {
            writePrefix(of: buffer, frames: toTail, total: frames, sink: &sink)
            sink.closeTake()
            isTakeOpen = false
            resetBuffers()
            phase = .armed
            return
        }
        if toTail < frames { holdRing.append(buffer, from: toTail, count: frames - toTail) }
        writePrefix(of: buffer, frames: toTail, total: frames, sink: &sink)
    }

    private func writePrefix<S: TakeSink>(of buffer: AVAudioPCMBuffer, frames: Int, total: Int, sink: inout S) {
        guard frames > 0 else { return }
        if frames < total { buffer.frameLength = AVAudioFrameCount(frames) }
        sink.write(buffer)
    }

    private func flushHeld<S: TakeSink>(sink: inout S) {
        if let held = holdRing.makeBuffer(format: format) { sink.write(held) }
        holdRing.removeAll()
        silentFrames = 0
    }

    private func resetBuffers() {
        preRollRing.removeAll()
        holdRing.removeAll()
        silentFrames = 0
    }
}
