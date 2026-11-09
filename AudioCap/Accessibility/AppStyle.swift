import SwiftUI
import AppKit

/// Shared text sizes and colours. Text is at least 16 pt and every text colour reaches a WCAG contrast of
/// 4.5:1 or more on the window and grouped-form backgrounds, in light and dark mode (see `AppStyleTests`).
enum AppStyle {
    static let minimumTextSize: CGFloat = 16

    /// Body text.
    static let body = Font.system(size: 16)
    /// Secondary lines (formats, durations, hints). Same size as body; only the colour differs.
    static let detail = Font.system(size: 16)
    /// Section and status titles.
    static let headline = Font.system(size: 18, weight: .semibold)

    /// An sRGB colour with an exact value, so contrast can be checked in tests.
    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        init(_ hex: UInt32) {
            red = Double((hex >> 16) & 0xFF) / 255
            green = Double((hex >> 8) & 0xFF) / 255
            blue = Double(hex & 0xFF) / 255
        }

        var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

        /// WCAG 2.x relative luminance.
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        /// WCAG 2.x contrast ratio between two colours (1...21).
        func contrast(with other: RGB) -> Double {
            let (a, b) = (luminance, other.luminance)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
    }

    /// A colour with one value for light mode and one for dark mode.
    struct AdaptiveColor {
        var light: RGB
        var dark: RGB

        var color: Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark.nsColor : light.nsColor
            })
        }
    }

    /// Replaces `.secondary`, whose 50 % grey falls below 4.5:1 on the grouped-form background.
    static let secondaryText = AdaptiveColor(light: RGB(0x595959), dark: RGB(0xB8B8B8))
    /// Errors and the "Recording" state. System red is about 3.5:1 on white, too low for text.
    static let errorText = AdaptiveColor(light: RGB(0xB3261E), dark: RGB(0xFF8A80))
    /// Warnings (silent capture, dropped frames). System orange is about 2.2:1 on white.
    static let warningText = AdaptiveColor(light: RGB(0x8A4B00), dark: RGB(0xFFB454))

    /// Backgrounds text sits on: window, grouped-form section and its darkest/lightest neighbours.
    static let lightBackgrounds = [RGB(0xFFFFFF), RGB(0xF5F5F5), RGB(0xECECEC), RGB(0xE5E5E5)]
    static let darkBackgrounds = [RGB(0x1E1E1E), RGB(0x262626), RGB(0x2D2D2D), RGB(0x363636)]
}

extension Button where Label == Text {
    /// A button whose title is body-sized. macOS bordered buttons ignore `.font` on the button itself and only honour
    /// it on the label text.
    init(readable title: LocalizedStringKey, action: @escaping () -> Void) {
        self.init(action: action) { Text(title).font(AppStyle.body) }
    }
}

extension View {
    /// Secondary text in a colour that keeps 4.5:1 contrast.
    func secondaryTextStyle() -> some View {
        font(AppStyle.detail).foregroundStyle(AppStyle.secondaryText.color)
    }

    /// Warning text in a colour that keeps 4.5:1 contrast.
    func warningTextStyle() -> some View {
        font(AppStyle.detail).foregroundStyle(AppStyle.warningText.color)
    }

    /// Error text in a colour that keeps 4.5:1 contrast.
    func errorTextStyle() -> some View {
        font(AppStyle.body).foregroundStyle(AppStyle.errorText.color)
    }
}
