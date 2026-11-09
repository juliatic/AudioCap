import XCTest
import AudioToolbox
@testable import AudioCap

final class AudioProcessListMonitorTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testBurstOfChangesIsCoalescedIntoOneCallback() {
        let counter = Counter()
        let fired = expectation(description: "onChange")
        fired.assertForOverFulfill = false
        let monitor = AudioProcessListMonitor(coalescingInterval: .milliseconds(100), watchesCoreAudio: false) {
            counter.increment()
            fired.fulfill()
        }
        monitor.start()
        for _ in 0..<20 { monitor.noteChange() }

        wait(for: [fired], timeout: 2)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(counter.count, 1)

        monitor.noteChange()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(counter.count, 2)
    }

    func testStoppedMonitorDoesNotFire() {
        let counter = Counter()
        let monitor = AudioProcessListMonitor(coalescingInterval: .milliseconds(50), watchesCoreAudio: false) { counter.increment() }
        monitor.start()
        monitor.stop()
        monitor.noteChange()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(counter.count, 0)
    }

    func testStartWatchesOutputOfEveryCoreAudioProcess() throws {
        let processes = try AudioObjectID.readProcessList()
        let monitor = AudioProcessListMonitor { }
        monitor.start()
        XCTAssertEqual(monitor.outputListenerCount(), processes.count)
        monitor.stop()
        XCTAssertEqual(monitor.outputListenerCount(), 0)
    }
}
