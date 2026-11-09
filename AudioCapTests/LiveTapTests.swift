import XCTest
import AVFoundation
@testable import AudioCap

/// End-to-end capture through the real process tap. Opt-in: needs an output device, the audio recording
/// permission for the test host (AudioCap.app) and `afplay`.
/// Run with `TEST_RUNNER_AUDIOCAP_LIVE_TAP=1 xcodebuild test -only-testing:AudioCapTests/LiveTapTests ...`.
final class LiveTapTests: TemporaryDirectoryTestCase {
    @MainActor
    func testRecordsAfplayToAVerifiedWAV() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AUDIOCAP_LIVE_TAP"] == "1", "Set TEST_RUNNER_AUDIOCAP_LIVE_TAP=1 to run")
        // The committed test.wav is digital silence, so play a generated tone instead.
        let fixture = url("tone.wav")
        let tone = Synth.buffer(frames: 44_100 * 8, amplitude: 0.5)
        let toneFile = try AVAudioFile(forWriting: fixture, settings: tone.format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try toneFile.write(from: tone)
        toneFile.close()

        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [fixture.path]
        try player.run()
        defer { if player.isRunning { player.terminate() } }

        var objectID = AudioObjectID.unknown
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let id = try? AudioObjectID.translatePIDToProcessObjectID(pid: player.processIdentifier), id.isValid {
                objectID = id
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(objectID.isValid, "afplay has no audio process object")

        let settings = RecordingSettings.shared
        let savedFormat = settings.outputFormat, savedSplit = settings.autoSplitOnSilence
        settings.outputFormat = .wav
        settings.autoSplitOnSilence = false
        defer {
            settings.outputFormat = savedFormat
            settings.autoSplitOnSilence = savedSplit
        }

        let process = AudioProcess(id: player.processIdentifier, kind: .process, name: "afplay", audioActive: true, bundleID: nil, bundleURL: nil, objectID: objectID)
        let tap = ProcessTap(process: process)
        tap.activate()
        XCTAssertNil(tap.errorMessage)
        let recorder = ProcessTapRecorder(tap: tap, outputDirectory: directory)
        try recorder.start()
        let started = Date()
        print("Live capture format: \(recorder.captureFormat?.description ?? "none") after \(Date().timeIntervalSince(started)) s")
        print("Live aggregate input streams:\n" + tap.aggregateInputStreams.joined(separator: "\n"))
        print("Live output device: \(tap.aggregateOutputDevice?.description ?? "-"), tap ASBD \(tap.tapStreamDescription?.diagnosticDescription ?? "-")")

        var peak = -240.0
        let stopAt = Date().addingTimeInterval(3)
        while Date() < stopAt {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            peak = max(peak, recorder.level.peakDb)
        }
        print("Live stopping at \(Date().timeIntervalSince(started)) s, takes \(recorder.takes.count), frames \(recorder.framesWritten)")
        recorder.stop()
        print("Live stopped at \(Date().timeIntervalSince(started)) s")
        let elapsed = Date().timeIntervalSince(started)

        let exportDeadline = Date().addingTimeInterval(10)
        while Date() < exportDeadline, recorder.takes.isEmpty || recorder.takes.contains(where: { !$0.status.isFinal }) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        tap.invalidate()
        print("Live takes: \(recorder.takes.map { "\($0.status) \($0.capturedFrames)" }) lastError=\(recorder.lastError ?? "-")")

        XCTAssertEqual(recorder.takes.count, 1)
        let take = try XCTUnwrap(recorder.takes.first)
        XCTAssertEqual(take.status, .completed)
        XCTAssertGreaterThan(take.capturedFrames, 0)
        XCTAssertEqual(take.exportedFrames, take.capturedFrames)
        XCTAssertFalse(FileManager.default.fileExists(atPath: take.captureURL.path), "the CAF intermediate is removed after export")

        let file = try AVAudioFile(forReading: take.outputURL)
        XCTAssertEqual(file.length, take.capturedFrames)
        XCTAssertEqual(file.fileFormat.commonFormat, .pcmFormatFloat32)
        let duration = Double(file.length) / file.fileFormat.sampleRate
        print("Live capture: \(file.length) frames, \(duration) s over \(elapsed) s wall clock, peak \(peak) dB, \(file.fileFormat)")
        XCTAssertEqual(duration, elapsed, accuracy: 0.5, "file duration should match the time recorded")
        XCTAssertGreaterThan(peak, -60, "the capture should not be silent")
        XCTAssertGreaterThan(AudioLevel(measuring: try Synth.readAll(take.outputURL)).peakDb, -60)
    }
}
