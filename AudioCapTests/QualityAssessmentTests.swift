import XCTest
import Observation
@testable import AudioCap

@MainActor
final class QualityAssessmentTests: XCTestCase {
    private func path(tapRate: Double = 96_000, deviceRate: Double = 96_000, captureRate: Double? = 96_000,
                      channels: Int = 2, deviceChannels: Int = 2, format: RecordingSettings.OutputFormat = .wav,
                      sourceRate: Double? = nil, sourceChannels: Int? = nil) -> QualityPath {
        var path = QualityPath(sourceName: "Music")
        path.sourceSampleRate = sourceRate
        path.sourceChannelCount = sourceChannels
        path.tap = .init(sampleRate: tapRate, channelCount: channels)
        path.clock = .init(name: "DAC", uid: "dac", nominalSampleRate: deviceRate, outputChannelCount: deviceChannels)
        path.capture = captureRate.map { .init(sampleRate: $0, channelCount: channels) }
        let rate = captureRate ?? deviceRate
        path.file = .init(format: format, sampleRate: format == .aac ? min(rate, 48_000) : rate, channelCount: channels)
        return path
    }

    func testMatchingRatesAndChannelsAreBitPerfect() {
        let result = QualityAssessment.assess(path())
        XCTAssertTrue(result.isBitPerfect)
        XCTAssertEqual(result.issues, [])
        XCTAssertTrue(result.notes.contains(.sourceRateUnknown(captureRate: 96_000)))
        XCTAssertTrue(result.notes.contains(.appProcessing))
    }

    func testKnownSourceRateDifferentFromDeviceIsResampled() {
        let result = QualityAssessment.assess(path(tapRate: 48_000, deviceRate: 48_000, captureRate: 48_000, sourceRate: 96_000))
        XCTAssertFalse(result.isBitPerfect)
        XCTAssertEqual(result.issues, [.resampled(from: 96_000, to: 48_000)])
    }

    func testTapRateDifferentFromCaptureIsResampled() {
        let result = QualityAssessment.assess(path(tapRate: 48_000, deviceRate: 96_000, captureRate: 96_000))
        XCTAssertEqual(result.issues, [.resampled(from: 48_000, to: 96_000)])
    }

    func testMultichannelSourceIsDownmixed() {
        let result = QualityAssessment.assess(path(sourceChannels: 6))
        XCTAssertEqual(result.issues, [.downmixed(from: 6, to: 2)])
    }

    func testMultichannelDeviceWarnsAboutPossibleDownmix() {
        let result = QualityAssessment.assess(path(deviceChannels: 8))
        XCTAssertEqual(result.issues, [.possibleDownmix(deviceChannels: 8, to: 2)])
        XCTAssertFalse(result.isBitPerfect)
    }

    func testAACIsLossyAndResampledAbove48kHz() {
        let result = QualityAssessment.assess(path(format: .aac))
        XCTAssertEqual(Set(result.issues), [.lossyFile, .exportResampled(to: 48_000)])
    }

    func testLosslessIntegerFormatsStayBitPerfectWithNote() {
        for format in [RecordingSettings.OutputFormat.flac, .alac] {
            let result = QualityAssessment.assess(path(format: format))
            XCTAssertTrue(result.isBitPerfect, "\(format)")
            XCTAssertTrue(result.notes.contains(.integerFile(bits: 24)))
        }
    }

    func testBeforeRecordingTheResultIsMarkedAsPredicted() {
        let result = QualityAssessment.assess(path(captureRate: nil))
        XCTAssertTrue(result.notes.contains(.predicted))
        XCTAssertTrue(result.isBitPerfect)
    }

    func testContributorsCanDescribeHiResDeviceAndMonitor() {
        final class HiRes: QualityPathContributor {
            func contribute(to path: inout QualityPath) {
                path.clock?.isVirtualHiRes = true
                path.monitor = .init(deviceName: "Speakers", sampleRate: 48_000)
            }
        }
        let contributor = HiRes()
        QualityPathContributors.register(contributor)
        defer { QualityPathContributors.unregister(contributor) }

        var value = path(tapRate: 192_000, deviceRate: 192_000, captureRate: 192_000)
        QualityPathContributors.apply(to: &value)
        let result = QualityAssessment.assess(value)
        XCTAssertTrue(result.isBitPerfect)
        XCTAssertTrue(result.notes.contains(.hiResDevice))
        XCTAssertTrue(result.notes.contains(.monitor(deviceName: "Speakers", sampleRate: 48_000)))
    }

    func testAfterHiResStopTheIdlePanelDoesNotClaimResampling() {
        // After Stop: the tap still reports the take's 96 kHz mix, the restored BlackHole runs at 48 kHz, no capture.
        var idle = path(tapRate: 96_000, deviceRate: 48_000, captureRate: nil)
        idle.clock?.name = "BlackHole 2ch"
        XCTAssertEqual(QualityAssessment.assess(idle).issues, [.resampled(from: 96_000, to: 48_000)], "the reported bug")

        let next = HiResController.predictedHiResPath(from: idle, rate: 96_000, monitorName: "BlackHole 2ch")
        let result = QualityAssessment.assess(next)
        XCTAssertTrue(result.isBitPerfect)
        XCTAssertEqual(next.captureRate, 96_000)
        XCTAssertEqual(next.file?.sampleRate, 96_000)
        XCTAssertTrue(result.notes.contains(.predicted))
        XCTAssertTrue(result.notes.contains(.hiResDevice))
        XCTAssertTrue(result.notes.contains(.monitor(deviceName: "BlackHole 2ch", sampleRate: nil)))
    }

    func testHiResPredictionKeepsAACAtItsMaximumRate() {
        let next = HiResController.predictedHiResPath(from: path(captureRate: nil, format: .aac), rate: 192_000, monitorName: "Speakers")
        XCTAssertEqual(next.file?.sampleRate, AudioExporter.maxAACSampleRate)
    }

    func testIdleWithoutSourceDescribesTheCurrentOutputNotTheLastTap() {
        // Hi-Res turned off after a take whose source has quit: the tap still reports the take's 96 kHz mix.
        let blackHole = QualityPath.Device(name: "BlackHole 2ch", uid: "bh", nominalSampleRate: 48_000, outputChannelCount: 2)
        let stale = QualityPath.Stream(sampleRate: 96_000, channelCount: 2)
        let idle = QualityPathBuilder.assemble(sourceName: "afplay", sourceBundleID: nil, tap: stale, clock: blackHole, capture: nil,
                                               format: .wav, isRecording: false, isSourceAvailable: false)
        XCTAssertEqual(idle.tap?.sampleRate, 48_000)
        XCTAssertEqual(idle.file?.sampleRate, 48_000)
        let result = QualityAssessment.assess(idle)
        XCTAssertTrue(result.isBitPerfect)
        XCTAssertTrue(result.notes.contains(.predicted))
        XCTAssertFalse(result.notes.contains(.hiResDevice))

        let running = QualityPathBuilder.assemble(sourceName: "afplay", sourceBundleID: nil, tap: stale, clock: blackHole, capture: nil,
                                                  format: .wav, isRecording: false, isSourceAvailable: true)
        XCTAssertEqual(QualityAssessment.assess(running).issues, [.resampled(from: 96_000, to: 48_000)],
                       "a running source keeps the rate it opened the output at")

        let recording = QualityPathBuilder.assemble(sourceName: "afplay", sourceBundleID: nil, tap: stale, clock: blackHole, capture: stale,
                                                    format: .wav, isRecording: true, isSourceAvailable: false)
        XCTAssertEqual(recording.capture, stale)
    }

    func testTurningHiResOffRefreshesTheIdlePrediction() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "QualityHiResOff-\(UUID())"))
        let controller = HiResController(settings: HiResSettings(defaults: defaults))
        var changed = false
        withObservationTracking { _ = controller.nextTake(sourceBundleID: nil) } onChange: { changed = true }
        controller.settings.isEnabled = false
        XCTAssertTrue(changed, "the panel observes the Hi-Res setting")
        XCTAssertNil(controller.nextTake(sourceBundleID: nil))
    }

    func testEveryIssueAndNoteHasText() {
        let issues: [QualityIssue] = [.resampled(from: 44_100, to: 48_000), .resampled(from: nil, to: 48_000), .downmixed(from: 6, to: 2),
                                      .downmixed(from: 6, to: 4), .possibleDownmix(deviceChannels: 8, to: 2), .exportResampled(to: 48_000), .lossyFile]
        for issue in issues { XCTAssertFalse(QualityPanel.text(for: issue).isEmpty) }
        XCTAssertTrue(QualityPanel.text(for: .resampled(from: 44_100, to: 48_000)).contains("44.1 kHz"))
    }
}

@MainActor
final class DeviceRateMatcherTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "DeviceRateMatcherTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testMatchThenRestorePutsBackTheOriginalRate() {
        var calls: [(String, Double)] = []
        let matcher = DeviceRateMatcher(defaults: defaults) { calls.append(($0, $1)) }
        matcher.match(deviceUID: "dac", deviceName: "DAC", currentRate: 48_000, to: 96_000)
        matcher.match(deviceUID: "dac", deviceName: "DAC", currentRate: 96_000, to: 192_000)
        XCTAssertEqual(matcher.activeChange?.originalRate, 48_000)
        matcher.restore()
        XCTAssertEqual(calls.map(\.1), [96_000, 192_000, 48_000])
        XCTAssertNil(matcher.activeChange)
        matcher.restore()
        XCTAssertEqual(calls.count, 3)
    }

    func testPendingChangeFromAPreviousLaunchIsRestored() {
        var calls: [Double] = []
        let first = DeviceRateMatcher(defaults: defaults) { _, rate in calls.append(rate) }
        first.match(deviceUID: "dac", deviceName: "DAC", currentRate: 44_100, to: 96_000)
        _ = DeviceRateMatcher(defaults: defaults) { _, rate in calls.append(rate) }
        XCTAssertEqual(calls, [96_000, 44_100])
        XCTAssertNil(defaults.data(forKey: DeviceRateMatcher.pendingKey))
    }

    func testFailedMatchReportsAndChangesNothing() {
        struct Failure: Error {}
        let matcher = DeviceRateMatcher(defaults: defaults) { _, _ in throw Failure() }
        matcher.match(deviceUID: "dac", deviceName: "DAC", currentRate: 48_000, to: 96_000)
        XCTAssertNil(matcher.activeChange)
        XCTAssertNotNil(matcher.lastError)
    }
}
