import XCTest
@testable import AudioCap

final class ProcessRelaunchTests: XCTestCase {
    func testBundledAppMatchesByBundleID() {
        XCTAssertTrue(ProcessTap.isRelaunch(bundleID: "com.apple.Music", executablePath: "/A", candidateBundleID: "com.apple.Music", candidatePath: "/B"))
        XCTAssertFalse(ProcessTap.isRelaunch(bundleID: "com.apple.Music", executablePath: "/A", candidateBundleID: "com.spotify.client", candidatePath: "/A"))
        XCTAssertFalse(ProcessTap.isRelaunch(bundleID: "com.apple.Music", executablePath: "/A", candidateBundleID: nil, candidatePath: "/A"))
    }

    func testProcessWithoutBundleIDMatchesByExecutable() {
        XCTAssertTrue(ProcessTap.isRelaunch(bundleID: nil, executablePath: "/usr/bin/afplay", candidateBundleID: nil, candidatePath: "/usr/bin/afplay"))
        XCTAssertFalse(ProcessTap.isRelaunch(bundleID: nil, executablePath: "/usr/bin/afplay", candidateBundleID: nil, candidatePath: "/usr/bin/say"))
        XCTAssertFalse(ProcessTap.isRelaunch(bundleID: nil, executablePath: "/usr/bin/afplay", candidateBundleID: "com.example", candidatePath: "/usr/bin/afplay"))
    }

    func testUnknownExecutableNeverMatches() {
        XCTAssertFalse(ProcessTap.isRelaunch(bundleID: nil, executablePath: nil, candidateBundleID: nil, candidatePath: nil))
        XCTAssertFalse(ProcessTap.isRelaunch(bundleID: nil, executablePath: nil, candidateBundleID: nil, candidatePath: "/usr/bin/afplay"))
    }
}
