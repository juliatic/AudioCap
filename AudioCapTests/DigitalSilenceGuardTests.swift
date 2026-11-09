import XCTest
@testable import AudioCap

final class DigitalSilenceGuardTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    func testAllZerosTriggersExactlyOnceThenWarns() {
        var guardian = DigitalSilenceGuard(seconds: 2)
        var reconnects = 0
        for step in 0...100 {
            let elapsed = Double(step) * 0.1
            if guardian.update(silentSeconds: elapsed, hasSeenSignal: false, sourceIsPlaying: true, sourceName: "afplay",
                               now: t0.addingTimeInterval(elapsed)) == .reconnect {
                reconnects += 1
            }
        }
        XCTAssertEqual(reconnects, 1)
        XCTAssertEqual(guardian.state, .gaveUp)
        XCTAssertTrue(guardian.warning?.contains("Screen & System Audio Recording") == true)
    }

    func testZerosThenSignalThenZerosNeverTriggersAfterTheFirstSignal() {
        var guardian = DigitalSilenceGuard(seconds: 2)
        XCTAssertEqual(guardian.update(silentSeconds: 1, hasSeenSignal: false, sourceIsPlaying: true, sourceName: "x", now: t0), .none)
        XCTAssertEqual(guardian.update(silentSeconds: 0, hasSeenSignal: true, sourceIsPlaying: true, sourceName: "x", now: t0), .none)
        for step in 0...200 {
            let elapsed = Double(step) * 0.1
            XCTAssertEqual(guardian.update(silentSeconds: elapsed, hasSeenSignal: true, sourceIsPlaying: true, sourceName: "x",
                                           now: t0.addingTimeInterval(elapsed)), .none)
        }
        XCTAssertEqual(guardian.state, .disarmed)
        XCTAssertNil(guardian.warning)
    }

    func testNoReconnectWhileTheSourceIsNotPlaying() {
        var guardian = DigitalSilenceGuard(seconds: 2)
        XCTAssertEqual(guardian.update(silentSeconds: 10, hasSeenSignal: false, sourceIsPlaying: false, sourceName: "x", now: t0), .none)
        XCTAssertNil(guardian.warning)
    }

    func testSignalAfterReconnectClearsTheWarning() {
        var guardian = DigitalSilenceGuard(seconds: 2)
        XCTAssertEqual(guardian.update(silentSeconds: 2, hasSeenSignal: false, sourceIsPlaying: true, sourceName: "x", now: t0), .reconnect)
        XCTAssertNotNil(guardian.warning)
        _ = guardian.update(silentSeconds: 0, hasSeenSignal: true, sourceIsPlaying: true, sourceName: "x", now: t0)
        XCTAssertNil(guardian.warning)
    }

    func testStopClearsTheWarningAndRearms() {
        var guardian = DigitalSilenceGuard(seconds: 2)
        _ = guardian.update(silentSeconds: 3, hasSeenSignal: false, sourceIsPlaying: true, sourceName: "x", now: t0)
        XCTAssertNotNil(guardian.warning)
        guardian.reset() // what ProcessTapRecorder.stop()/start() do
        XCTAssertNil(guardian.warning)
        XCTAssertEqual(guardian.state, .armed)
    }
}
