import XCTest
import AVFoundation
@testable import AudioCap

/// Records what the machine asks for, copying every written buffer as it is handed over.
private final class TakeLog {
    var takes: [[[Float]]] = []   // take → channel → samples
    var opens = 0
    var closes = 0
    var isOpen = false
    var refuseOpen = false
}

private struct LogSink: TakeSink {
    let log: TakeLog

    mutating func openTake() -> Bool {
        guard !log.refuseOpen else { return false }
        XCTAssertFalse(log.isOpen, "openTake while a take is open")
        log.opens += 1
        log.isOpen = true
        log.takes.append([])
        return true
    }

    mutating func write(_ buffer: AVAudioPCMBuffer) {
        XCTAssertTrue(log.isOpen, "write without an open take")
        let channels = Int(buffer.format.channelCount)
        if log.takes[log.takes.count - 1].isEmpty { log.takes[log.takes.count - 1] = Array(repeating: [], count: channels) }
        for c in 0..<channels {
            log.takes[log.takes.count - 1][c] += UnsafeBufferPointer(start: buffer.floatChannelData![c], count: Int(buffer.frameLength))
        }
    }

    mutating func closeTake() {
        XCTAssertTrue(log.isOpen, "closeTake without an open take")
        log.closes += 1
        log.isOpen = false
    }
}

final class AutoRecordMachineTests: XCTestCase {
    private let rate = 48_000.0
    private var format: AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)! }
    private let quiet: Float = 1e-4  // −80 dBFS: silence, but every sample is distinguishable by its marker
    private let loud: Float = 0.25   // −12 dBFS

    private var sampleCounter: Float = 0

    /// A stereo buffer of `frames` samples near `level`; each sample carries a unique marker so its position can be checked.
    private func chunk(_ level: Float, frames: Int = 3_000) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            sampleCounter += 1
            let marker = sampleCounter * 1e-9
            buffer.floatChannelData![0][i] = level + marker
            buffer.floatChannelData![1][i] = -(level + marker)
        }
        return buffer
    }

    private func makeMachine(mode: AutoRecordMachine.Mode = .waitForSound) -> AutoRecordMachine {
        AutoRecordMachine(configuration: .init(), format: format, mode: mode)
    }

    /// Feeds a buffer and returns the samples of its left channel as they were before the machine saw it.
    @discardableResult
    private func feed(_ machine: AutoRecordMachine, _ buffer: AVAudioPCMBuffer, _ sink: inout LogSink) -> [Float] {
        let left = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        machine.process(buffer, level: AudioLevel(measuring: buffer), sink: &sink)
        return left
    }

    func testDefaults() {
        let machine = makeMachine()
        XCTAssertEqual(machine.configuration.thresholdDb, -60)
        XCTAssertEqual(machine.configuration.minSilence, 2)
        XCTAssertEqual(machine.preRollFrames, 24_000)
        XCTAssertEqual(machine.minSilenceFrames, 96_000)
        XCTAssertEqual(machine.phase, .idle)
    }

    func testArmedWritesNothingAndTheTakeStartsWithTheExactPreRoll() {
        let log = TakeLog()
        var sink = LogSink(log: log)
        let machine = makeMachine()
        machine.start()
        XCTAssertEqual(machine.phase, .armed)

        var input: [Float] = []
        for _ in 0..<11 { input += feed(machine, chunk(quiet), &sink) }  // 33 000 frames of silence
        XCTAssertEqual(log.opens, 0)
        XCTAssertEqual(machine.preRollCount, 24_000)

        let first = feed(machine, chunk(loud, frames: 1_000), &sink)
        XCTAssertEqual(machine.phase, .recording)
        XCTAssertEqual(log.opens, 1)
        let expected = Array(input.suffix(24_000)) + first
        XCTAssertEqual(log.takes[0][0], expected, "the take is the last 0.5 s before the sound, then the sound")
        XCTAssertEqual(log.takes[0][1], expected.map { -$0 })
    }

    func testShortPreRollWhenSoundArrivesRightAway() {
        let log = TakeLog()
        var sink = LogSink(log: log)
        let machine = makeMachine()
        machine.start()
        let silence = feed(machine, chunk(quiet, frames: 500), &sink)
        let sound = feed(machine, chunk(loud), &sink)
        XCTAssertEqual(log.takes[0][0], silence + sound)
    }

    func testTrailingSilenceIsTrimmedToTheTailAndTheMachineReArms() {
        let log = TakeLog()
        var sink = LogSink(log: log)
        let machine = makeMachine()
        machine.start()
        let sound = feed(machine, chunk(loud), &sink)

        var silence: [Float] = []
        while log.closes == 0 {
            silence += feed(machine, chunk(quiet, frames: 7_000), &sink)
            XCTAssertLessThan(silence.count, 200_000)
        }
        XCTAssertGreaterThanOrEqual(silence.count, machine.minSilenceFrames)
        XCTAssertLessThan(silence.count - 7_000, machine.minSilenceFrames, "closes on the first buffer that completes 2 s")
        XCTAssertEqual(machine.phase, .armed)
        XCTAssertEqual(log.takes[0][0], sound + silence.prefix(machine.tailFrames), "ends with exactly 0.5 s of silence")

        // Re-armed: the next sound opens a second take with a fresh pre-roll (only silence heard after the close).
        let afterClose = feed(machine, chunk(quiet, frames: 2_000), &sink)
        let again = feed(machine, chunk(loud), &sink)
        XCTAssertEqual(log.opens, 2)
        XCTAssertEqual(log.takes[1][0], afterClose + again)
    }

    func testSilenceShorterThanTheLimitIsKeptWhole() {
        let log = TakeLog()
        var sink = LogSink(log: log)
        let machine = makeMachine()
        machine.start()
        var expected = feed(machine, chunk(loud), &sink)
        for _ in 0..<31 { expected += feed(machine, chunk(quiet), &sink) }  // 93 000 frames < 96 000
        XCTAssertEqual(machine.phase, .closing)
        XCTAssertEqual(machine.heldCount, 93_000 - machine.tailFrames)
        expected += feed(machine, chunk(loud), &sink)
        XCTAssertEqual(machine.phase, .recording)
        XCTAssertEqual(log.closes, 0)
        XCTAssertEqual(log.takes[0][0], expected)
    }

    func testStopClosesTheTakeAndDisarms() {
        let log = TakeLog()
        var sink = LogSink(log: log)
        let machine = makeMachine()
        machine.start()
        let sound = feed(machine, chunk(loud), &sink)
        let silence = feed(machine, chunk(quiet, frames: 30_000), &sink)
        machine.stop(sink: &sink)
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(log.closes, 1)
        XCTAssertEqual(log.takes[0][0], sound + silence.prefix(machine.tailFrames))
        feed(machine, chunk(loud), &sink)
        XCTAssertEqual(log.opens, 1, "idle ignores input")
        machine.stop(sink: &sink)
        XCTAssertEqual(log.closes, 1)
    }

    func testManualModeWritesEverythingFromTheFirstBuffer() {
        let log = TakeLog()
        var sink = LogSink(log: log)
        let machine = makeMachine(mode: .manual)
        machine.start()
        XCTAssertEqual(machine.phase, .recording)
        var expected: [Float] = []
        for _ in 0..<40 { expected += feed(machine, chunk(quiet), &sink) }
        expected += feed(machine, chunk(loud), &sink)
        XCTAssertEqual(log.opens, 1)
        XCTAssertEqual(log.closes, 0)
        XCTAssertEqual(log.takes[0][0], expected)
    }

    func testSwitchingFromArmedToManualOpensOnTheNextBuffer() {
        let log = TakeLog()
        var sink = LogSink(log: log)
        let machine = makeMachine()
        machine.start()
        feed(machine, chunk(quiet), &sink)
        machine.setMode(.manual, sink: &sink)
        XCTAssertEqual(machine.phase, .recording)
        XCTAssertEqual(log.opens, 0)
        let next = feed(machine, chunk(quiet), &sink)
        XCTAssertEqual(log.opens, 1)
        XCTAssertEqual(log.takes[0][0], next)
    }

    func testSwitchingFromClosingToManualKeepsTheHeldSilence() {
        let log = TakeLog()
        var sink = LogSink(log: log)
        let machine = makeMachine()
        machine.start()
        var expected = feed(machine, chunk(loud), &sink)
        expected += feed(machine, chunk(quiet, frames: 60_000), &sink)
        XCTAssertEqual(machine.phase, .closing)
        machine.setMode(.manual, sink: &sink)
        expected += feed(machine, chunk(quiet, frames: 60_000), &sink)
        XCTAssertEqual(log.closes, 0)
        XCTAssertEqual(log.takes[0][0], expected)
    }

    func testSwitchingFromManualToWaitForSoundClosesTheTakeOnSilence() {
        let log = TakeLog()
        var sink = LogSink(log: log)
        let machine = makeMachine(mode: .manual)
        machine.start()
        let sound = feed(machine, chunk(loud), &sink)
        machine.setMode(.waitForSound, sink: &sink)
        XCTAssertEqual(machine.phase, .recording)
        let silence = feed(machine, chunk(quiet, frames: 100_000), &sink)
        XCTAssertEqual(log.closes, 1)
        XCTAssertEqual(machine.phase, .armed)
        XCTAssertEqual(log.takes[0][0], sound + silence.prefix(machine.tailFrames))
    }

    func testSwitchingFromManualBeforeAnyInputArms() {
        let log = TakeLog()
        var sink = LogSink(log: log)
        let machine = makeMachine(mode: .manual)
        machine.start()
        machine.setMode(.waitForSound, sink: &sink)
        XCTAssertEqual(machine.phase, .armed)
        feed(machine, chunk(quiet), &sink)
        XCTAssertEqual(log.opens, 0)
    }

    func testEndTakeReArmsAndRefusedOpenKeepsWaiting() {
        let log = TakeLog()
        var sink = LogSink(log: log)
        let machine = makeMachine()
        machine.start()
        feed(machine, chunk(loud), &sink)
        machine.endTake(sink: &sink)
        XCTAssertEqual(log.closes, 1)
        XCTAssertEqual(machine.phase, .armed)

        log.refuseOpen = true
        feed(machine, chunk(loud), &sink)
        XCTAssertEqual(machine.phase, .armed)
        XCTAssertFalse(machine.isTakeOpen)
    }
}

final class AudioRingBufferTests: XCTestCase {
    func testKeepsTheMostRecentFramesInOrderAcrossWraps() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let ring = AudioRingBuffer(capacity: 10, channelCount: 1)
        var all: [Float] = []
        var next: Float = 0
        for size in [3, 4, 5, 1, 12, 7] {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(size))!
            buffer.frameLength = AVAudioFrameCount(size)
            for i in 0..<size { next += 1; buffer.floatChannelData![0][i] = next }
            all += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: size)
            ring.append(buffer)
            let out = ring.makeBuffer(format: format)!
            XCTAssertEqual(Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))), Array(all.suffix(10)))
        }
        ring.removeAll()
        XCTAssertNil(ring.makeBuffer(format: format))
    }
}
