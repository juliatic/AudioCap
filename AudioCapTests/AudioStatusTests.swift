import XCTest
import AudioToolbox
@testable import AudioCap

final class AudioStatusTests: XCTestCase {
    func testDecodesFmtCode() {
        XCTAssertEqual(AudioStatus.fourCharCode(1718449215), "fmt?")
        XCTAssertEqual(AudioStatus.describe(1718449215), "'fmt?' (1718449215): unsupported data format")
    }

    func testPlainNumericCodesAreNotDecodedAsText() {
        XCTAssertNil(AudioStatus.fourCharCode(-50))
        XCTAssertEqual(AudioStatus.describe(-50), "-50: invalid parameter")
    }

    func testAVFAudioErrorIncludesFourCharCode() {
        let error = NSError(domain: "com.apple.coreaudio.avfaudio", code: 1718449215)
        XCTAssertEqual(error.audioCapDescription, "com.apple.coreaudio.avfaudio error 'fmt?' (1718449215): unsupported data format.")
    }

    func testCoreAudioErrorIncludesOperation() {
        let error = CoreAudioError(operation: "Starting the aggregate device", status: kAudioHardwareNotRunningError)
        XCTAssertEqual(error.audioCapDescription, "Starting the aggregate device failed with 'stop' (\(kAudioHardwareNotRunningError)): the audio hardware is not running.")
    }

    func testCheckStatus() {
        XCTAssertNoThrow(try checkStatus(noErr, "ok"))
        XCTAssertThrowsError(try checkStatus(kAudioHardwareBadDeviceError, "x")) { error in
            XCTAssertEqual(error as? CoreAudioError, CoreAudioError(operation: "x", status: kAudioHardwareBadDeviceError))
        }
    }
}
