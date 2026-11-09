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

    func testIdleTapRefreshOnlyWhileNoTakeIsOpenAndSilent() {
        XCTAssertTrue(IdleTapRefresh.shouldRefresh(isTakeOpen: false, silentSeconds: 10, sourceIsPlaying: true, secondsSinceLastRefresh: nil))
        XCTAssertFalse(IdleTapRefresh.shouldRefresh(isTakeOpen: true, silentSeconds: 60, sourceIsPlaying: true, secondsSinceLastRefresh: nil))
        XCTAssertFalse(IdleTapRefresh.shouldRefresh(isTakeOpen: false, silentSeconds: 9.9, sourceIsPlaying: true, secondsSinceLastRefresh: nil))
        XCTAssertFalse(IdleTapRefresh.shouldRefresh(isTakeOpen: false, silentSeconds: 60, sourceIsPlaying: false, secondsSinceLastRefresh: nil))
        XCTAssertFalse(IdleTapRefresh.shouldRefresh(isTakeOpen: false, silentSeconds: 60, sourceIsPlaying: true, secondsSinceLastRefresh: 5))
        XCTAssertTrue(IdleTapRefresh.shouldRefresh(isTakeOpen: false, silentSeconds: 60, sourceIsPlaying: true, secondsSinceLastRefresh: 10))
    }

    func testChoppedTapIsRebuiltOnlyInAnOpenTakeWhileTheSourcePlays() {
        XCTAssertTrue(ChoppedCapture.shouldRebuild(isTakeOpen: true, cuts: 3, sourceIsPlaying: true, secondsSinceLastRebuild: nil))
        XCTAssertFalse(ChoppedCapture.shouldRebuild(isTakeOpen: true, cuts: 2, sourceIsPlaying: true, secondsSinceLastRebuild: nil))
        XCTAssertFalse(ChoppedCapture.shouldRebuild(isTakeOpen: false, cuts: 9, sourceIsPlaying: true, secondsSinceLastRebuild: nil))
        XCTAssertFalse(ChoppedCapture.shouldRebuild(isTakeOpen: true, cuts: 9, sourceIsPlaying: false, secondsSinceLastRebuild: nil))
        XCTAssertFalse(ChoppedCapture.shouldRebuild(isTakeOpen: true, cuts: 9, sourceIsPlaying: true, secondsSinceLastRebuild: 9))
        XCTAssertTrue(ChoppedCapture.shouldRebuild(isTakeOpen: true, cuts: 9, sourceIsPlaying: true, secondsSinceLastRebuild: 10))
    }
}
