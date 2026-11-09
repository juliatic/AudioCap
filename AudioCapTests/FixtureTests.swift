import XCTest
import AVFoundation
@testable import AudioCap

/// Checks that the committed audio fixtures are bundled with the test target.
final class FixtureTests: XCTestCase {
    func testFixturesAreBundled() throws {
        let bundle = Bundle(for: FixtureTests.self)
        let wav = try XCTUnwrap(bundle.url(forResource: "test", withExtension: "wav"))
        let flac = try XCTUnwrap(bundle.url(forResource: "test", withExtension: "flac"))
        XCTAssertEqual(try AVAudioFile(forReading: wav).length, 220_500)
        XCTAssertEqual(try AVAudioFile(forReading: flac).length, 217_088)
    }
}
