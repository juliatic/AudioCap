import XCTest
import AudioToolbox
@testable import AudioCap

final class SourceSelectionTests: XCTestCase {
    private func process(_ pid: pid_t, _ name: String, bundleID: String? = nil, kind: AudioProcess.Kind = .process) -> AudioProcess {
        AudioProcess(id: pid, kind: kind, name: name, audioActive: false, bundleID: bundleID, bundleURL: nil, objectID: AudioObjectID(pid + 1000))
    }

    private let paths: [pid_t: String] = [10: "/usr/bin/afplay", 11: "/usr/bin/afplay", 12: "/usr/bin/say"]
    private func path(_ process: AudioProcess) -> String? { paths[process.id] }

    func testListedSelectionStaysSelected() {
        let afplay = process(10, "afplay")
        XCTAssertEqual(SourceSelection.row(for: afplay, executablePath: "/usr/bin/afplay", in: [afplay], path: path), afplay)
    }

    func testGoneSelectionHasNoRowUntilRelaunched() {
        let afplay = process(10, "afplay")
        let say = process(12, "say")
        XCTAssertNil(SourceSelection.row(for: afplay, executablePath: "/usr/bin/afplay", in: [say], path: path))
    }

    func testRelaunchWithoutBundleIDIsMatchedByExecutable() {
        let old = process(10, "afplay")
        let relaunched = process(11, "afplay")
        let say = process(12, "say")
        XCTAssertEqual(SourceSelection.row(for: old, executablePath: "/usr/bin/afplay", in: [say, relaunched], path: path), relaunched)
        XCTAssertTrue(SourceSelection.isRelaunch(of: old, executablePath: "/usr/bin/afplay", candidate: relaunched, candidatePath: "/usr/bin/afplay"))
    }

    func testRelaunchedAppIsMatchedByBundleID() {
        let old = process(20, "Music", bundleID: "com.apple.Music", kind: .app)
        let relaunched = process(21, "Music", bundleID: "com.apple.Music", kind: .app)
        let other = process(22, "Spotify", bundleID: "com.spotify.client", kind: .app)
        XCTAssertEqual(SourceSelection.row(for: old, executablePath: nil, in: [other, relaunched], path: { _ in nil }), relaunched)
    }

    func testSameObjectAndSystemAudioAreNotRelaunches() {
        let afplay = process(10, "afplay")
        XCTAssertFalse(SourceSelection.isRelaunch(of: afplay, executablePath: "/usr/bin/afplay", candidate: afplay, candidatePath: "/usr/bin/afplay"))
        XCTAssertFalse(SourceSelection.isRelaunch(of: .allSystemAudio, executablePath: nil, candidate: afplay, candidatePath: nil))
        XCTAssertEqual(SourceSelection.row(for: .allSystemAudio, executablePath: nil, in: [], path: path), .allSystemAudio)
    }
}
