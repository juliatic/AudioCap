import XCTest
import AVFoundation
@testable import AudioCap

final class SilenceDetectorTests: XCTestCase {
    func testLevelIsTheSameForInterleavedAndNonInterleaved() {
        let interleaved = AudioLevel(measuring: Synth.constant(0.5, frames: 480, interleaved: true))
        let deinterleaved = AudioLevel(measuring: Synth.constant(0.5, frames: 480, interleaved: false))
        XCTAssertEqual(interleaved.rmsDb, AudioLevel.dbfs(0.5), accuracy: 1e-6)
        XCTAssertEqual(deinterleaved.rmsDb, interleaved.rmsDb, accuracy: 1e-9)
        XCTAssertEqual(interleaved.peakDb, AudioLevel.dbfs(0.5), accuracy: 1e-6)
    }

    func testInterleavedBufferWithSoundOnlyInTheRightChannel() {
        // Interleaved stereo has one data pointer; the old code read floatChannelData[1].
        let buffer = Synth.constant(0, frames: 480, channels: 2, interleaved: true)
        let samples = buffer.floatChannelData![0]
        for i in 0..<480 { samples[i * 2 + 1] = 1 }
        let level = AudioLevel(measuring: buffer)
        XCTAssertEqual(level.rmsDb, AudioLevel.dbfs(sqrt(0.5)), accuracy: 1e-6)
        XCTAssertEqual(level.peakDb, 0, accuracy: 1e-9)
    }

    func testEmptyBufferIsSilence() {
        let buffer = Synth.constant(1, frames: 0, interleaved: false)
        XCTAssertEqual(AudioLevel(measuring: buffer), .silence)
    }

    func testSplitTriggersOnceAndDropsTheRestOfTheSilence() {
        var detector = SilenceDetector(thresholdDb: -60, minSilenceDuration: 1.0)
        let silence = Synth.constant(0, frames: 4_800, interleaved: true)   // 0.1 s
        let sound = Synth.constant(0.5, frames: 4_800, interleaved: true)

        XCTAssertFalse(detector.process(buffer: sound).isSilent)
        var results: [SilenceDetector.Analysis] = []
        for _ in 0..<15 { results.append(detector.process(buffer: silence)) }

        XCTAssertEqual(results.filter(\.didTriggerSplit).count, 1)
        let triggerIndex = results.firstIndex(where: \.didTriggerSplit)!
        XCTAssertEqual(triggerIndex, 9) // 10 × 0.1 s = 1.0 s
        XCTAssertTrue(results[..<triggerIndex].allSatisfy { !$0.shouldDrop }, "silence before the split belongs to the ending file")
        XCTAssertTrue(results[triggerIndex...].allSatisfy(\.shouldDrop), "silence after the split must not leak into the next file")

        let resumed = detector.process(buffer: sound)
        XCTAssertFalse(resumed.shouldDrop)
        XCTAssertFalse(detector.isInSplitSilence)
    }

    func testShortSilenceDoesNotSplit() {
        var detector = SilenceDetector(thresholdDb: -60, minSilenceDuration: 1.0)
        let silence = Synth.constant(0, frames: 4_800, interleaved: false)
        let sound = Synth.constant(0.5, frames: 4_800, interleaved: false)
        for _ in 0..<5 { XCTAssertFalse(detector.process(buffer: silence).didTriggerSplit) }
        _ = detector.process(buffer: sound)
        for _ in 0..<5 { XCTAssertFalse(detector.process(buffer: silence).didTriggerSplit) }
        XCTAssertEqual(detector.accumulatedSilence, 0.5, accuracy: 1e-9)
    }
}
