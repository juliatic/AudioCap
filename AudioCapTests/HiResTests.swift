import XCTest
import CoreAudio
@testable import AudioCap

/// In-memory CoreAudio stand-in for the Hi-Res router.
final class FakeOutputSystem: AudioOutputSystem {
    var devices: [AudioOutputDevice]
    var defaultUID: String?
    var rates: [String: Double] = [:]
    var failSetDefault = false
    private(set) var setDefaultCalls: [String] = []

    init(devices: [AudioOutputDevice], defaultUID: String?) {
        self.devices = devices
        self.defaultUID = defaultUID
    }

    func defaultOutputUID() -> String? { defaultUID }
    func setDefaultOutput(uid: String) throws {
        guard !failSetDefault, device(uid: uid) != nil else { throw "cannot set \(uid)" }
        setDefaultCalls.append(uid)
        defaultUID = uid
    }
    func device(uid: String) -> AudioOutputDevice? { devices.first { $0.uid == uid } }
    func outputDevices(excluding excludedUID: String) -> [AudioOutputDevice] { devices.filter { $0.uid != excludedUID } }
    func setNominalSampleRate(_ rate: Double, uid: String) throws {
        guard HiResDevice.isSupported(rate) else { throw "unsupported" }
        rates[uid] = rate
    }
    func deviceID(uid: String) throws -> AudioDeviceID { throw "No HAL device for \(uid) in tests." }

    func remove(_ uid: String) {
        devices.removeAll { $0.uid == uid }
        if defaultUID == uid { defaultUID = devices.first?.uid }
    }
}

final class HiResRatePolicyTests: XCTestCase {
    func testMusicUsesTrackRate() {
        for rate in HiResDevice.supportedRates {
            XCTAssertEqual(HiResRatePolicy.decide(sourceBundleID: "com.apple.Music", musicTrackRate: rate, fixedRate: 96_000),
                           .init(rate: rate, source: .musicTrack))
        }
    }

    func testMusicWithUnknownOrUnsupportedRateUsesFixedRate() {
        XCTAssertEqual(HiResRatePolicy.decide(sourceBundleID: "com.apple.Music", musicTrackRate: nil, fixedRate: 192_000), .init(rate: 192_000, source: .fixed))
        XCTAssertEqual(HiResRatePolicy.decide(sourceBundleID: "com.apple.Music", musicTrackRate: 32_000, fixedRate: 96_000), .init(rate: 96_000, source: .fixed))
        XCTAssertEqual(HiResRatePolicy.decide(sourceBundleID: "com.apple.Music", musicTrackRate: 384_000, fixedRate: 176_400), .init(rate: 176_400, source: .fixed))
    }

    func testOtherAppsUseFixedRateEvenWithATrackRate() {
        XCTAssertEqual(HiResRatePolicy.decide(sourceBundleID: "com.spotify.client", musicTrackRate: 44_100, fixedRate: 96_000), .init(rate: 96_000, source: .fixed))
        XCTAssertEqual(HiResRatePolicy.decide(sourceBundleID: nil, musicTrackRate: nil, fixedRate: 88_200), .init(rate: 88_200, source: .fixed))
    }

    func testUnsupportedFixedRateFallsBackTo96k() {
        XCTAssertEqual(HiResRatePolicy.sanitizedFixedRate(384_000), 96_000)
        XCTAssertEqual(HiResRatePolicy.sanitizedFixedRate(0), 96_000)
        XCTAssertEqual(HiResRatePolicy.sanitizedFixedRate(192_000), 192_000)
    }

    func testSettingsDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "HiResSettingsTests-\(UUID())"))
        let settings = HiResSettings(defaults: defaults)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.fixedRate, 96_000)
        settings.isEnabled = false
        settings.fixedRate = 192_000
        let reloaded = HiResSettings(defaults: defaults)
        XCTAssertFalse(reloaded.isEnabled)
        XCTAssertEqual(reloaded.fixedRate, 192_000)
    }
}

final class HiResRestoreStoreTests: XCTestCase {
    func testSaveLoadClear() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "HiResRestoreStoreTests-\(UUID())"))
        let store = HiResRestoreStore(defaults: defaults)
        XCTAssertNil(store.load())
        let record = HiResRestoreRecord(previousOutput: .init(uid: "bt", name: "Headphones", nominalSampleRate: 48_000), routedAt: Date(timeIntervalSince1970: 1_000))
        store.save(record)
        XCTAssertEqual(HiResRestoreStore(defaults: defaults).load(), record, "survives a new store instance (next launch)")
        store.clear()
        XCTAssertNil(store.load())
    }

    func testCorruptRecordIsIgnored() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "HiResRestoreStoreTests-\(UUID())"))
        defaults.set(Data("not json".utf8), forKey: "HiResRestoreRecord")
        XCTAssertNil(HiResRestoreStore(defaults: defaults).load())
    }
}

final class HiResRouterTests: XCTestCase {
    private let speakers = AudioOutputDevice(uid: "builtin", name: "MacBook Speakers", nominalSampleRate: 48_000)
    private let headphones = AudioOutputDevice(uid: "bt", name: "Headphones", nominalSampleRate: 48_000)
    private let virtual = AudioOutputDevice(uid: HiResDevice.uid, name: HiResDevice.name, nominalSampleRate: 44_100)
    private var system: FakeOutputSystem!
    private var store: HiResRestoreStore!
    private var router: HiResRouter!

    override func setUpWithError() throws {
        system = FakeOutputSystem(devices: [speakers, headphones, virtual], defaultUID: "bt")
        store = HiResRestoreStore(defaults: try XCTUnwrap(UserDefaults(suiteName: "HiResRouterTests-\(UUID())")))
        router = HiResRouter(system: system, store: store)
    }

    func testRouteRemembersOutputSetsRateAndRestores() throws {
        let monitor = try router.route(rate: 96_000)
        XCTAssertEqual(monitor, headphones)
        XCTAssertEqual(system.defaultUID, HiResDevice.uid)
        XCTAssertEqual(system.rates[HiResDevice.uid], 96_000)
        XCTAssertEqual(router.state, .routed(monitor: headphones, rate: 96_000))
        XCTAssertEqual(store.load()?.previousOutput, headphones, "persisted before switching, for crash recovery")

        XCTAssertEqual(router.restore(), headphones)
        XCTAssertEqual(system.defaultUID, "bt")
        XCTAssertEqual(router.state, .idle)
        XCTAssertNil(store.load())
    }

    func testAfterStopTheNextRouteIsHiResAgain() throws {
        XCTAssertEqual(router.nextRoute(rate: 96_000), .routed(monitor: headphones, rate: 96_000))
        try router.route(rate: 96_000)
        XCTAssertNil(router.nextRoute(rate: 96_000), "no prediction while a take is routed")
        router.restore()
        XCTAssertEqual(system.defaultUID, "bt")
        XCTAssertEqual(router.nextRoute(rate: 96_000), .routed(monitor: headphones, rate: 96_000),
                       "after Stop the next take is Hi-Res again, not the restored device's rate")
        system.remove(HiResDevice.uid)
        XCTAssertNil(router.nextRoute(rate: 96_000))
    }

    func testRouteTwiceThrows() throws {
        try router.route(rate: 96_000)
        XCTAssertThrowsError(try router.route(rate: 96_000))
    }

    func testRouteWithoutDriverThrowsAndChangesNothing() {
        system.remove(HiResDevice.uid)
        XCTAssertThrowsError(try router.route(rate: 96_000))
        XCTAssertEqual(system.defaultUID, "bt")
        XCTAssertNil(store.load())
        XCTAssertEqual(router.state, .idle)
    }

    func testFailedSwitchRollsBack() {
        system.failSetDefault = true
        XCTAssertThrowsError(try router.route(rate: 96_000))
        XCTAssertEqual(system.defaultUID, "bt")
        XCTAssertNil(store.load())
        XCTAssertEqual(router.state, .idle)
    }

    func testUnsupportedRateThrowsAndChangesNothing() {
        XCTAssertThrowsError(try router.route(rate: 22_050))
        XCTAssertEqual(system.defaultUID, "bt")
        XCTAssertNil(store.load())
    }

    func testUserPicksAnotherOutputWhileRouted() throws {
        try router.route(rate: 96_000)
        system.defaultUID = "builtin"
        XCTAssertEqual(router.defaultOutputChanged(), .monitorTargetChanged(speakers))
        XCTAssertEqual(system.defaultUID, HiResDevice.uid, "the Hi-Res device is the system output again")
        XCTAssertEqual(router.monitorTarget, speakers)
        XCTAssertEqual(store.load()?.previousOutput, speakers)
        router.restore()
        XCTAssertEqual(system.defaultUID, "builtin")
    }

    func testOwnSwitchIsNotAnEvent() throws {
        try router.route(rate: 96_000)
        XCTAssertNil(router.defaultOutputChanged())
    }

    func testVirtualDeviceVanishes() throws {
        try router.route(rate: 192_000)
        system.remove(HiResDevice.uid)
        system.defaultUID = nil
        XCTAssertEqual(router.deviceListChanged(), .virtualDeviceLost(restored: headphones))
        XCTAssertEqual(system.defaultUID, "bt")
        XCTAssertEqual(router.state, .idle)
        XCTAssertNil(store.load())
    }

    func testOtherDeviceListChangesAreIgnored() throws {
        try router.route(rate: 96_000)
        system.devices.append(.init(uid: "display", name: "Display", nominalSampleRate: 48_000))
        XCTAssertNil(router.deviceListChanged())
        XCTAssertTrue(router.isRouted)
    }

    func testRestoreFallsBackWhenRememberedDeviceIsGone() throws {
        try router.route(rate: 96_000)
        system.remove("bt")
        XCTAssertEqual(router.restore(), speakers)
        XCTAssertEqual(system.defaultUID, "builtin")
    }

    func testRestoreLeavesAnOutputTheUserPickedAlone() throws {
        try router.route(rate: 96_000)
        system.defaultUID = "builtin"
        XCTAssertEqual(router.restore(), speakers)
        XCTAssertFalse(system.setDefaultCalls.contains("bt") && system.setDefaultCalls.last == "bt")
        XCTAssertEqual(system.defaultUID, "builtin")
    }

    func testRecoverAfterCrash() throws {
        try router.route(rate: 96_000)
        // Simulate a crash: a fresh router (next launch) with the same store; the Hi-Res device is still the output.
        let relaunched = HiResRouter(system: system, store: store)
        XCTAssertEqual(relaunched.recoverAfterCrash(), headphones)
        XCTAssertEqual(system.defaultUID, "bt")
        XCTAssertNil(store.load())
        XCTAssertNil(relaunched.recoverAfterCrash(), "nothing left to recover")
    }

    func testRecoverWithoutRecordDoesNothing() {
        system.defaultUID = HiResDevice.uid
        XCTAssertNil(router.recoverAfterCrash())
        XCTAssertEqual(system.defaultUID, HiResDevice.uid, "a Hi-Res output chosen by hand is not touched without a record")
    }

    func testRouteWhenHiResIsAlreadyTheOutputUsesARealDevice() throws {
        system.defaultUID = HiResDevice.uid
        XCTAssertEqual(try router.route(rate: 96_000), speakers)
    }

    func testSetRateWhileRouted() throws {
        try router.route(rate: 96_000)
        try router.setRate(44_100)
        XCTAssertEqual(system.rates[HiResDevice.uid], 44_100)
        XCTAssertEqual(router.rate, 44_100)
    }
}

final class MonitorRingBufferTests: XCTestCase {
    func testPassesSamplesAfterPriming() {
        let ring = MonitorRingBuffer(channelCount: 2, sampleRate: 10_000, latency: 0.1) // target 1,000 frames
        let left = (0..<1_000).map { Float($0) }, right = left.map { -$0 }
        left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in
            ring.write(channels: [l.baseAddress!, r.baseAddress!], frames: 1_000)
        } }
        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(abl.unsafeMutablePointer) }
        let out = [UnsafeMutablePointer<Float>.allocate(capacity: 256), UnsafeMutablePointer<Float>.allocate(capacity: 256)]
        defer { out.forEach { $0.deallocate() } }
        for c in 0..<2 { abl[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 1024, mData: out[c]) }
        ring.read(into: abl, frames: 256)
        XCTAssertEqual(out[0][10], 10)
        XCTAssertEqual(out[1][10], -10)
        XCTAssertEqual(ring.availableFrames, 744)
    }

    /// Interleaved tap buffers are deinterleaved into the ring, also across its wrap point.
    func testWritesInterleavedBufferListAcrossWrap() throws {
        let format = try CaptureFormat(validating: AudioStreamBasicDescription(
            mSampleRate: 10_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0))
        let ring = MonitorRingBuffer(channelCount: 2, sampleRate: 10_000, latency: 0.1) // capacity 8,000 frames
        let frames = 3_000
        var interleaved = [Float](repeating: 0, count: frames * 2)
        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(abl.unsafeMutablePointer) }
        let out = [UnsafeMutablePointer<Float>.allocate(capacity: frames), UnsafeMutablePointer<Float>.allocate(capacity: frames)]
        defer { out.forEach { $0.deallocate() } }
        for c in 0..<2 { abl[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: out[c]) }
        for block in 0..<3 {
            for i in 0..<frames {
                interleaved[2 * i] = Float(block * frames + i)
                interleaved[2 * i + 1] = -Float(block * frames + i)
            }
            interleaved.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: raw.baseAddress))
                ring.write(&list, format: format)
            }
            ring.read(into: abl, frames: frames)
        }
        // Block 2 covers ring indices 6,000..<9,000, so it wraps at 8,000.
        XCTAssertEqual(out[0][0], Float(2 * frames))
        XCTAssertEqual(out[0][frames - 1], Float(3 * frames - 1))
        XCTAssertEqual(out[1][frames - 1], -Float(3 * frames - 1))
        XCTAssertEqual(ring.availableFrames, 0)
    }

    func testSilenceBeforePriming() {
        let ring = MonitorRingBuffer(channelCount: 1, sampleRate: 10_000, latency: 0.1)
        let samples = [Float](repeating: 1, count: 100)
        samples.withUnsafeBufferPointer { ring.write(channels: [$0.baseAddress!], frames: 100) }
        let abl = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(abl.unsafeMutablePointer) }
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        defer { out.deallocate() }
        abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 256, mData: out)
        ring.read(into: abl, frames: 64)
        XCTAssertEqual(out[0], 0)
        XCTAssertEqual(ring.availableFrames, 100)
    }
}

@MainActor
final class HiResControllerTests: XCTestCase {
    private let headphones = AudioOutputDevice(uid: "bt", name: "Headphones", nominalSampleRate: 48_000)
    private let virtual = AudioOutputDevice(uid: HiResDevice.uid, name: HiResDevice.name, nominalSampleRate: 44_100)

    private func makeController() throws -> (HiResController, FakeOutputSystem, HiResSettings) {
        let system = FakeOutputSystem(devices: [headphones, virtual], defaultUID: "bt")
        let suite = "HiResControllerTests-\(UUID())"
        let settings = HiResSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        settings.isEnabled = true
        let store = HiResRestoreStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite + "-store")))
        return (HiResController(settings: settings, system: system, store: store), system, settings)
    }

    private func stereoFloat(_ rate: Double) throws -> CaptureFormat {
        try CaptureFormat(validating: AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0))
    }

    func testArmedToggleOffThenStopUnlocksSettingsAndRestoresTheOutput() throws {
        let (controller, system, settings) = try makeController()
        XCTAssertTrue(controller.beginRoute(sourceBundleID: nil))
        XCTAssertTrue(controller.isRouted, "Settings are disabled while routed")
        XCTAssertEqual(system.defaultUID, HiResDevice.uid)

        settings.isEnabled = false
        XCTAssertTrue(controller.isRouted, "turning Hi-Res off while armed takes effect at Stop")

        var refreshed = false
        withObservationTracking { _ = controller.isRouted } onChange: { refreshed = true }
        controller.end()
        XCTAssertTrue(refreshed, "views reading isRouted (the Settings section) are refreshed at Stop")
        XCTAssertFalse(controller.isRouted, "Settings are enabled again")
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(system.defaultUID, "bt", "output restored")

        XCTAssertFalse(controller.beginRoute(sourceBundleID: nil), "the next take stays off Hi-Res")
        XCTAssertEqual(system.defaultUID, "bt")
    }

    func testMonitorFailureIsRetriedOnceBeforeItIsShown() throws {
        let (controller, _, _) = try makeController()
        controller.monitorRetryDelay = .milliseconds(50)
        XCTAssertTrue(controller.beginRoute(sourceBundleID: nil))
        controller.formatChanged(try stereoFloat(96_000))
        XCTAssertNil(controller.message, "the first failure is retried, not shown")

        let deadline = Date().addingTimeInterval(2)
        while controller.message == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let message = try XCTUnwrap(controller.message)
        XCTAssertTrue(message.hasPrefix("Monitor unavailable on Headphones: "), message)
        XCTAssertTrue(message.hasSuffix(" The recording is not affected."), message)
        controller.end()
    }

    func testStopCancelsAPendingMonitorRetry() throws {
        let (controller, _, _) = try makeController()
        controller.monitorRetryDelay = .milliseconds(50)
        XCTAssertTrue(controller.beginRoute(sourceBundleID: nil))
        controller.formatChanged(try stereoFloat(96_000))
        controller.end()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(controller.message)
    }
}
