import XCTest
@testable import AudioCap

final class DigitalSilenceGuardTests: XCTestCase {
    func testAllZerosWarnsExactlyOnceAndNeverReconnects() {
        var guardian = DigitalSilenceGuard(seconds: 2)
        var warnings = 0
        var previous: String?
        for step in 0...100 {
            guardian.update(silentSeconds: Double(step) * 0.1, hasSeenSignal: false, sourceIsPlaying: true, sourceName: "afplay")
            if guardian.warning != previous, guardian.warning != nil { warnings += 1 }
            previous = guardian.warning
        }
        XCTAssertEqual(warnings, 1)
        XCTAssertEqual(guardian.state, .warned)
        XCTAssertTrue(guardian.warning?.contains("Screen & System Audio Recording") == true)
    }

    func testNoWarningBeforeTheThreshold() {
        var guardian = DigitalSilenceGuard(seconds: 2)
        guardian.update(silentSeconds: 1.9, hasSeenSignal: false, sourceIsPlaying: true, sourceName: "x")
        XCTAssertEqual(guardian.state, .armed)
        XCTAssertNil(guardian.warning)
    }

    func testZerosThenSignalThenZerosNeverWarnsAfterTheFirstSignal() {
        var guardian = DigitalSilenceGuard(seconds: 2)
        guardian.update(silentSeconds: 1, hasSeenSignal: false, sourceIsPlaying: true, sourceName: "x")
        guardian.update(silentSeconds: 0, hasSeenSignal: true, sourceIsPlaying: true, sourceName: "x")
        for step in 0...200 {
            guardian.update(silentSeconds: Double(step) * 0.1, hasSeenSignal: true, sourceIsPlaying: true, sourceName: "x")
            XCTAssertNil(guardian.warning)
        }
        XCTAssertEqual(guardian.state, .disarmed)
    }

    func testNoWarningWhileTheSourceIsNotPlaying() {
        var guardian = DigitalSilenceGuard(seconds: 2)
        guardian.update(silentSeconds: 10, hasSeenSignal: false, sourceIsPlaying: false, sourceName: "x")
        XCTAssertNil(guardian.warning)
        XCTAssertEqual(guardian.state, .armed)
    }

    func testSignalAfterTheWarningClearsIt() {
        var guardian = DigitalSilenceGuard(seconds: 2)
        guardian.update(silentSeconds: 2, hasSeenSignal: false, sourceIsPlaying: true, sourceName: "x")
        XCTAssertNotNil(guardian.warning)
        guardian.update(silentSeconds: 0, hasSeenSignal: true, sourceIsPlaying: true, sourceName: "x")
        XCTAssertNil(guardian.warning)
        XCTAssertEqual(guardian.state, .disarmed)
    }

    func testStopClearsTheWarningAndRearms() {
        var guardian = DigitalSilenceGuard(seconds: 2)
        guardian.update(silentSeconds: 3, hasSeenSignal: false, sourceIsPlaying: true, sourceName: "x")
        XCTAssertNotNil(guardian.warning)
        guardian.reset() // what ProcessTapRecorder.stop()/start() do
        XCTAssertNil(guardian.warning)
        XCTAssertEqual(guardian.state, .armed)
    }
}
