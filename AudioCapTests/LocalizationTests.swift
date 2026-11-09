import XCTest
@testable import AudioCap

/// Checks the String Catalog in the source tree and the compiled Spanish strings in the app bundle.
final class LocalizationTests: XCTestCase {
    private static let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func catalog(_ name: String) throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: Self.sourceRoot.appending(path: "AudioCap/\(name)"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["sourceLanguage"] as? String, "en")
        return try XCTUnwrap(json["strings"] as? [String: [String: Any]])
    }

    /// Format specifiers with positions stripped, in argument order (`%2$@ %1$lld` → `["lld", "@"]`).
    private func specifiers(_ string: String) -> [String] {
        let regex = /%(?:(\d+)\$)?(#@\w+@|l{0,2}[dfu@]|lf)/
        var positional: [(Int, String)] = []
        for (index, match) in string.matches(of: regex).enumerated() {
            let position = match.1.flatMap { Int($0) } ?? index + 1
            positional.append((position, String(match.2)))
        }
        return positional.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func spanishValues(_ entry: [String: Any]) -> [String] {
        guard let es = (entry["localizations"] as? [String: Any])?["es"] as? [String: Any] else { return [] }
        if let unit = es["stringUnit"] as? [String: String] { return [unit["value"] ?? ""] }
        let plural = (es["variations"] as? [String: Any])?["plural"] as? [String: [String: [String: String]]]
        return plural?.values.compactMap { $0["stringUnit"]?["value"] } ?? []
    }

    func testEveryStringHasASpanishTranslationWithMatchingArguments() throws {
        let strings = try catalog("Localizable.xcstrings")
        XCTAssertFalse(strings.isEmpty)
        for (key, entry) in strings {
            let values = spanishValues(entry)
            XCTAssertFalse(values.isEmpty, "No Spanish translation for \"\(key)\"")
            let hasSubstitutions = (((entry["localizations"] as? [String: Any])?["es"] as? [String: Any])?["substitutions"]) != nil
            for value in values where !hasSubstitutions {
                XCTAssertEqual(specifiers(value), specifiers(key), "Arguments differ in \"\(key)\" → \"\(value)\"")
            }
        }
    }

    func testInfoPlistStringsAreTranslated() throws {
        let strings = try catalog("InfoPlist.xcstrings")
        for key in ["NSAudioCaptureUsageDescription", "NSMicrophoneUsageDescription"] {
            XCTAssertFalse(spanishValues(try XCTUnwrap(strings[key], key)).isEmpty, key)
        }
    }

    private var spanish: Bundle {
        get throws { try XCTUnwrap(Bundle.main.path(forResource: "es", ofType: "lproj").flatMap(Bundle.init(path:))) }
    }

    func testCompiledSpanishStrings() throws {
        let es = try spanish
        XCTAssertEqual(String(localized: "Start", bundle: es), "Grabar")
        XCTAssertEqual(String(localized: "Recording from \("Música")", bundle: es), "Grabando desde Música")
        XCTAssertEqual(es.localizedString(forKey: "NSAudioCaptureUsageDescription", value: nil, table: "InfoPlist"),
                       "Permite el acceso para grabar el audio de otras apps.")
    }

    func testSpanishPluralsAndReorderedArguments() throws {
        let es = try spanish
        XCTAssertEqual(String(localized: "The capture stream reports \(1) channels.", bundle: es), "El flujo de captura indica 1 canal.")
        XCTAssertEqual(String(localized: "The capture stream reports \(6) channels.", bundle: es), "El flujo de captura indica 6 canales.")
        XCTAssertEqual(String(localized: "\("48 kHz") · \(2) ch · \("Float32") · interleaved", bundle: es), "48 kHz · 2 canales · Float32 · entrelazado")
        XCTAssertEqual(String(localized: "\("96 kHz") · \(1) ch · \("Float32") · non-interleaved", bundle: es), "96 kHz · 1 canal · Float32 · no entrelazado")
        XCTAssertEqual(String(localized: "\("Creating the process tap") failed with \("'fmt?' (1718449215)").", bundle: es),
                       "Error al Creating the process tap: 'fmt?' (1718449215).")
    }

    func testEnglishPlural() {
        XCTAssertEqual(String(localized: "The capture stream reports \(1) channels.", bundle: .main, locale: Locale(identifier: "en")),
                       "The capture stream reports 1 channel.")
    }
}
