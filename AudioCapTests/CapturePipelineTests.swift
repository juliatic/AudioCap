import XCTest
import AVFoundation
@testable import AudioCap

/// The I/O → ring → writer path with synthetic buffer lists, no tap needed.
final class CapturePipelineTests: TemporaryDirectoryTestCase {
    private let format = try! CaptureFormat(validating: AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0))

    /// Encodes a frame index exactly in Float32 (indices below 2^24 are exact).
    private static func sample(_ index: Int, channel: Int) -> Float {
        Float(index) / 16_777_216 * (channel == 0 ? 1 : -1)
    }

    private final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var events: [CapturePipeline.Event] = []
        func add(_ event: CapturePipeline.Event) { lock.lock(); events.append(event); lock.unlock() }
        var closed: [RecordingTake] {
            lock.lock(); defer { lock.unlock() }
            return events.compactMap { if case .closed(let take) = $0 { take } else { nil } }
        }
    }

    private func makePipeline(_ collector: Collector, detector: SilenceDetector? = nil, bufferedSeconds: Double = 4) -> CapturePipeline {
        var counter = 0
        let options = CapturePipeline.Options(outputDirectory: directory, outputFormat: .wav, sourceName: "test",
                                              silenceDetector: detector, makeBaseName: { counter += 1; return "take-\(counter)" },
                                              drainInterval: 0.005, bufferedSeconds: bufferedSeconds)
        return CapturePipeline(format: format, options: options) { collector.add($0) }
    }

    /// Feeds `frames` interleaved stereo frames per cycle, with sample values that encode the running frame index.
    private func feed(_ pipeline: CapturePipeline, cycles: Int, sizes: [Int], start: inout Int, sampleTime: inout Double, value: ((Int, Int) -> Float)? = nil) {
        let maxFrames = sizes.max()!
        var interleaved = [Float](repeating: 0, count: maxFrames * 2)
        var time = AudioTimeStamp()
        time.mFlags = .sampleTimeValid
        for cycle in 0..<cycles {
            let frames = sizes[cycle % sizes.count]
            for i in 0..<frames {
                interleaved[i * 2] = value?(start + i, 0) ?? Self.sample(start + i, channel: 0)
                interleaved[i * 2 + 1] = value?(start + i, 1) ?? Self.sample(start + i, channel: 1)
            }
            interleaved.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: raw.baseAddress))
                time.mSampleTime = sampleTime
                pipeline.process(&list, time: &time)
            }
            start += frames
            sampleTime += Double(frames)
            if cycle % 64 == 0 { usleep(200) } // let the drain timer interleave with the producer
        }
    }

    func testLongRunNeitherDropsNorDuplicatesFrames() throws {
        let collector = Collector()
        let pipeline = makePipeline(collector)
        var next = 0
        var sampleTime = 0.0
        // 6,000 cycles of varying sizes (about 54 s of audio at 48 kHz).
        feed(pipeline, cycles: 6_000, sizes: [512, 471, 1_024, 333, 480, 512], start: &next, sampleTime: &sampleTime)
        pipeline.finish()

        let takes = collector.closed
        XCTAssertEqual(takes.count, 1)
        let take = try XCTUnwrap(takes.first)
        XCTAssertEqual(take.capturedFrames, AVAudioFramePosition(next))
        XCTAssertNil(take.warning)
        XCTAssertEqual(pipeline.ring.overflowFrames.load(ordering: .relaxed), 0)
        XCTAssertEqual(pipeline.discontinuities.load(ordering: .relaxed), 0)

        let decoded = try Synth.readAll(take.captureURL)
        XCTAssertEqual(Int(decoded.frameLength), next)
        let left = decoded.floatChannelData![0], right = decoded.floatChannelData![1]
        var mismatches = 0
        for i in 0..<next where left[i] != Self.sample(i, channel: 0) || right[i] != Self.sample(i, channel: 1) {
            mismatches += 1
        }
        XCTAssertEqual(mismatches, 0, "every frame must appear once, in order")
    }

    func testRingOverflowIsCountedAndReported() throws {
        let collector = Collector()
        // A tiny ring and no chance to drain: the producer must count what it could not store.
        let pipeline = makePipeline(collector, bufferedSeconds: 0.01)
        let capacity = pipeline.ring.capacity
        var next = 0
        var sampleTime = 0.0
        pipeline.queue.sync {
            feed(pipeline, cycles: 4, sizes: [capacity], start: &next, sampleTime: &sampleTime)
        }
        pipeline.finish()
        let take = try XCTUnwrap(collector.closed.first)
        XCTAssertEqual(take.capturedFrames, AVAudioFramePosition(capacity))
        XCTAssertNotNil(take.warning)
    }

    func testSampleTimeGapIsCounted() throws {
        let collector = Collector()
        let pipeline = makePipeline(collector)
        var next = 0
        var sampleTime = 0.0
        feed(pipeline, cycles: 10, sizes: [512], start: &next, sampleTime: &sampleTime)
        sampleTime += 256
        feed(pipeline, cycles: 10, sizes: [512], start: &next, sampleTime: &sampleTime)
        pipeline.finish()
        XCTAssertTrue(try XCTUnwrap(collector.closed.first).warning?.contains("256 frames") == true)
    }

    /// Signal, then `zeroCycles` all-zero cycles of 480 frames, then signal again; a 440 Hz-ish square keeps edges loud.
    private func feedCut(_ pipeline: CapturePipeline, zeroCycles: Int) {
        var next = 0
        var sampleTime = 0.0
        let loud: (Int, Int) -> Float = { _, _ in 0.5 }
        feed(pipeline, cycles: 20, sizes: [480], start: &next, sampleTime: &sampleTime, value: loud)
        feed(pipeline, cycles: zeroCycles, sizes: [480], start: &next, sampleTime: &sampleTime) { _, _ in 0 }
        feed(pipeline, cycles: 20, sizes: [480], start: &next, sampleTime: &sampleTime, value: loud)
    }

    func testZerosCuttingIntoSignalAreReportedAsMissingAudio() throws {
        let collector = Collector()
        let pipeline = makePipeline(collector)
        feedCut(pipeline, zeroCycles: 40) // 0.4 s
        XCTAssertEqual(pipeline.dropouts.load(ordering: .relaxed), 1)
        XCTAssertEqual(pipeline.dropoutFrames.load(ordering: .relaxed), 19_200)
        pipeline.finish()
        let warning = try XCTUnwrap(collector.closed.first?.warning)
        XCTAssertTrue(warning.contains("0.400 s"), warning)
        XCTAssertFalse(warning.contains("timeline jumped"))
    }

    func testLongSilenceOrSilentSourceIsNotADropout() throws {
        let collector = Collector()
        let pipeline = makePipeline(collector)
        feedCut(pipeline, zeroCycles: 150) // 1.5 s: a track gap, not a dropout
        XCTAssertEqual(pipeline.dropouts.load(ordering: .relaxed), 0)
        pipeline.finish()
        XCTAssertNil(collector.closed.first?.warning)

        let quiet = makePipeline(collector)
        quiet.sourceIsOutputting.store(false, ordering: .relaxed)
        feedCut(quiet, zeroCycles: 40)
        XCTAssertEqual(quiet.dropouts.load(ordering: .relaxed), 0)
        quiet.finish()
    }

    func testFadeToSilenceIsNotADropout() {
        let collector = Collector()
        let pipeline = makePipeline(collector)
        var next = 0
        var sampleTime = 0.0
        feed(pipeline, cycles: 20, sizes: [480], start: &next, sampleTime: &sampleTime) { i, _ in 0.5 * max(0, 1 - Float(i) / 9_600) }
        feed(pipeline, cycles: 40, sizes: [480], start: &next, sampleTime: &sampleTime) { _, _ in 0 }
        feed(pipeline, cycles: 20, sizes: [480], start: &next, sampleTime: &sampleTime) { _, _ in 0.5 }
        XCTAssertEqual(pipeline.dropouts.load(ordering: .relaxed), 0)
        pipeline.finish()
    }

    func testTimelineJumpIsChargedOnlyToItsOwnTake() throws {
        let collector = Collector()
        let pipeline = makePipeline(collector, detector: SilenceDetector(thresholdDb: -60, minSilenceDuration: 0.5))
        var next = 0
        var sampleTime = 0.0
        let tone: (Int, Int) -> Float = { _, _ in 0.5 }
        feed(pipeline, cycles: 50, sizes: [480], start: &next, sampleTime: &sampleTime, value: tone)
        sampleTime += 300
        feed(pipeline, cycles: 50, sizes: [480], start: &next, sampleTime: &sampleTime, value: tone)
        feed(pipeline, cycles: 200, sizes: [480], start: &next, sampleTime: &sampleTime) { _, _ in 0 }
        feed(pipeline, cycles: 50, sizes: [480], start: &next, sampleTime: &sampleTime, value: tone)
        pipeline.finish()
        let takes = collector.closed
        XCTAssertEqual(takes.count, 2)
        XCTAssertTrue(takes.first?.warning?.contains("300 frames") == true)
        XCTAssertNil(takes.last?.warning)
    }

    func testTimelineLogKeepsOrderAndPosition() {
        let log = CaptureTimelineLog()
        for i in 0..<10 { log.push(.init(kind: i.isMultiple(of: 2) ? .jump : .dropout, position: i * 100, frames: i)) }
        var seen: [Int] = []
        log.consume(before: 450) { seen.append($0.frames) }
        XCTAssertEqual(seen, [0, 1, 2, 3, 4])
        log.consume(before: .max) { seen.append($0.frames) }
        XCTAssertEqual(seen, Array(0..<10))
        for i in 0..<(CaptureTimelineLog.capacity + 3) { log.push(.init(kind: .jump, position: i, frames: 0)) }
        XCTAssertEqual(log.lostEntries.load(ordering: .relaxed), 3)
    }

    func testReconnectIsNotReportedAsATimelineJump() throws {
        let collector = Collector()
        let pipeline = makePipeline(collector)
        var next = 0
        var sampleTime = 0.0
        feed(pipeline, cycles: 10, sizes: [512], start: &next, sampleTime: &sampleTime)
        pipeline.noteReconnect()
        sampleTime = 0 // a restarted device starts a new timeline
        feed(pipeline, cycles: 10, sizes: [512], start: &next, sampleTime: &sampleTime)
        pipeline.finish()
        let warning = try XCTUnwrap(collector.closed.first?.warning)
        XCTAssertFalse(warning.contains("timeline jumped"))
        XCTAssertTrue(warning.contains("reconnected 1 time"))
        XCTAssertEqual(pipeline.discontinuities.load(ordering: .relaxed), 0)
    }

    func testSignalIsRemembered() {
        let collector = Collector()
        let pipeline = makePipeline(collector)
        var next = 0
        var sampleTime = 0.0
        feed(pipeline, cycles: 5, sizes: [480], start: &next, sampleTime: &sampleTime) { _, _ in 0 }
        XCTAssertFalse(pipeline.hasSeenSignal)
        feed(pipeline, cycles: 1, sizes: [480], start: &next, sampleTime: &sampleTime) { _, _ in 0.25 }
        feed(pipeline, cycles: 5, sizes: [480], start: &next, sampleTime: &sampleTime) { _, _ in 0 }
        XCTAssertTrue(pipeline.hasSeenSignal)
        pipeline.finish()
    }

    func testDigitalSilenceTakeIsFlagged() throws {
        let collector = Collector()
        let pipeline = makePipeline(collector)
        var next = 0
        var sampleTime = 0.0
        feed(pipeline, cycles: 100, sizes: [480], start: &next, sampleTime: &sampleTime) { _, _ in 0 }
        XCTAssertEqual(pipeline.digitalSilenceRun.load(ordering: .relaxed), 48_000)
        pipeline.finish()
        let take = try XCTUnwrap(collector.closed.first)
        XCTAssertEqual(take.capturedFrames, 48_000)
        XCTAssertTrue(take.warning?.contains("digital silence") == true)
    }

    func testSilenceSplitProducesExactTakes() throws {
        let collector = Collector()
        let pipeline = makePipeline(collector, detector: SilenceDetector(thresholdDb: -60, minSilenceDuration: 0.5))
        var next = 0
        var sampleTime = 0.0
        let tone: (Int, Int) -> Float = { i, _ in 0.5 }
        feed(pipeline, cycles: 100, sizes: [480], start: &next, sampleTime: &sampleTime, value: tone)   // 1 s sound
        feed(pipeline, cycles: 200, sizes: [480], start: &next, sampleTime: &sampleTime) { _, _ in 0 } // 2 s silence
        feed(pipeline, cycles: 50, sizes: [480], start: &next, sampleTime: &sampleTime, value: tone)    // 0.5 s sound
        pipeline.finish()

        let takes = collector.closed
        XCTAssertEqual(takes.count, 2)
        // First take: 1 s of sound plus the silence before the buffer that reached 0.5 s (49 × 480 frames);
        // that buffer and the rest of the silence are dropped.
        XCTAssertEqual(takes.first?.capturedFrames, 48_000 + 49 * 480)
        XCTAssertEqual(takes.last?.capturedFrames, 24_000)
    }
}

final class CaptureRingBufferTests: XCTestCase {
    func testWrapAroundKeepsOrder() {
        let ring = CaptureRingBuffer(channelCount: 1, minimumCapacity: 1_024)
        var written = 0
        var read = 0
        var out = [Float](repeating: 0, count: 700)
        for _ in 0..<50 {
            ring.write(frameCount: 700) { offset, count, destination in
                let d = destination(0)
                for i in 0..<count { d[i] = Float(written + offset + i) }
            }
            written += 700
            out.withUnsafeMutableBufferPointer { buffer in
                ring.read(count: 700) { _ in buffer.baseAddress! }
            }
            XCTAssertEqual(out.first, Float(read))
            XCTAssertEqual(out.last, Float(read + 699))
            read += 700
        }
        XCTAssertEqual(ring.overflowFrames.load(ordering: .relaxed), 0)
    }

    func testMarkers() {
        let ring = CaptureRingBuffer(channelCount: 1, minimumCapacity: 1_024)
        ring.write(frameCount: 10) { _, count, destination in destination(0).update(repeating: 1, count: count) }
        XCTAssertTrue(ring.pushMarker())
        XCTAssertEqual(ring.peekMarker(), 10)
        ring.popMarker()
        XCTAssertNil(ring.peekMarker())
    }
}
