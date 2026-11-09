import XCTest
@testable import AudioCap

final class AppStyleTests: XCTestCase {
    func testTextIsAtLeast16Points() {
        XCTAssertGreaterThanOrEqual(AppStyle.minimumTextSize, 16)
    }

    func testContrastFormula() {
        let black = AppStyle.RGB(0x000000), white = AppStyle.RGB(0xFFFFFF)
        XCTAssertEqual(black.contrast(with: white), 21, accuracy: 0.01)
        XCTAssertEqual(AppStyle.RGB(0x777777).contrast(with: white), 4.48, accuracy: 0.01)
    }

    func testTextColoursReachAAContrastInLightAndDarkMode() {
        for colour in [AppStyle.secondaryText, AppStyle.errorText, AppStyle.warningText] {
            for background in AppStyle.lightBackgrounds {
                XCTAssertGreaterThanOrEqual(colour.light.contrast(with: background), 4.5, "light \(colour.light) on \(background)")
            }
            for background in AppStyle.darkBackgrounds {
                XCTAssertGreaterThanOrEqual(colour.dark.contrast(with: background), 4.5, "dark \(colour.dark) on \(background)")
            }
        }
    }
}
