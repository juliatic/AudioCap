import XCTest
import AVFoundation
@testable import AudioCap

final class TakeWarningTests: XCTestCase {
    private var spanish: Bundle {
        get throws { try XCTUnwrap(Bundle.main.path(forResource: "es", ofType: "lproj").flatMap(Bundle.init(path:))) }
    }

    func testLegacyJoinedEnglishWarningsMapToCodes() {
        let legacy = [
            "Every sample in this take is 0 (digital silence). If afplay was playing, check that AudioCap is allowed in System Settings › Privacy & Security › Screen & System Audio Recording.",
            "4,554 frames were dropped because the writer fell behind.",
            "The capture was reconnected 2 time(s) (output device change, wake or silence recovery); audio played during a reconnect is not in the take.",
            "The audio device's timeline jumped 3 time(s) (2,107 frames not delivered by CoreAudio).",
        ].joined(separator: " ")
        XCTAssertEqual(TakeWarning.parseLegacy(legacy),
                       [.allZero, .droppedFrames(frames: 4554), .reconnected(count: 2), .timelineJumps(count: 3, skippedFrames: 2107)])
    }

    func testShortLegacySilenceWarningMaps() {
        XCTAssertEqual(TakeWarning.parseLegacy("Every sample in this take is 0 (digital silence)."), [.allZero])
    }

    func testUnknownLegacyTextIsKeptAsIs() {
        XCTAssertEqual(TakeWarning.parseLegacy("Something unexpected happened."), [.legacyText(text: "Something unexpected happened.")])
        XCTAssertEqual(TakeWarning.parseLegacy("256 frames were dropped because the writer fell behind. Odd note."),
                       [.droppedFrames(frames: 256), .legacyText(text: "Odd note.")])
        XCTAssertEqual(TakeWarning.parseLegacy(""), [])
        XCTAssertEqual(TakeWarning.legacyText(text: "Nota antigua.").text(source: .app(name: "x"), bundle: try spanish), "Nota antigua.")
    }

    func testLegacySourceNames() {
        XCTAssertEqual(TakeSource(legacyName: "All system audio"), .allSystemAudio)
        XCTAssertEqual(TakeSource(legacyName: "Todo el audio del sistema"), .allSystemAudio)
        XCTAssertEqual(TakeSource(legacyName: "Music"), .app(name: "Music"))
    }

    func testEnglishRendering() {
        XCTAssertEqual(TakeSource.allSystemAudio.displayName(), "All system audio")
        XCTAssertEqual(TakeWarning.droppedFrames(frames: 256).text(source: .app(name: "afplay")),
                       "256 frames were dropped because the writer fell behind.")
        XCTAssertEqual(TakeWarning.timelineJumps(count: 3, skippedFrames: 512).text(source: .app(name: "afplay")),
                       "The audio device's timeline jumped 3 time(s) (512 frames not delivered by CoreAudio).")
        XCTAssertTrue(TakeWarning.allZero.text(source: .allSystemAudio).contains("If All system audio was playing"))
        XCTAssertTrue(TakeWarning.dropouts(count: 1, frames: 480, seconds: 0.01).text(source: .app(name: "afplay"))
            .hasPrefix("CoreAudio delivered digital zeros instead of afplay's audio 1 time(s)"))
    }

    func testSpanishRendering() throws {
        let es = try spanish
        XCTAssertEqual(TakeSource.allSystemAudio.displayName(bundle: es), "Todo el audio del sistema")
        XCTAssertEqual(TakeSource.app(name: "Música").displayName(bundle: es), "Música")
        XCTAssertEqual(TakeWarning.droppedFrames(frames: 256).text(source: .app(name: "afplay"), bundle: es),
                       "Se perdieron 256 tramas porque la escritura del archivo se quedó atrás.")
        XCTAssertEqual(TakeWarning.timelineJumps(count: 3, skippedFrames: 512).text(source: .app(name: "afplay"), bundle: es),
                       "Saltos en la línea de tiempo del dispositivo de audio: 3 (CoreAudio no entregó 512 tramas).")
        XCTAssertEqual(TakeWarning.reconnected(count: 2).text(source: .app(name: "afplay"), bundle: es),
                       "Reconexiones de la captura: 2 (cambio de dispositivo de salida, reinicio del origen o reactivación); el audio que sonó durante una reconexión no está en la toma.")
        XCTAssertTrue(TakeWarning.allZero.text(source: .allSystemAudio, bundle: es).contains("Si Todo el audio del sistema estaba sonando"))
        XCTAssertEqual(TakeWarning.dropouts(count: 2, frames: 480, seconds: 0.01).text(source: .app(name: "afplay"), bundle: es),
                       "Cortes en el audio de afplay: 2 (CoreAudio entregó ceros digitales mientras sonaba; 480 tramas, \(0.01.formatted(.number.precision(.fractionLength(3)))) s). Ese audio falta en la toma.")
    }

    func testStartMayBeLateRendering() throws {
        let shown = 0.022.formatted(.number.precision(.fractionLength(3)))
        XCTAssertEqual(TakeWarning.startMayBeLate(seconds: 0.022).text(source: .app(name: "afplay")),
                       "The take may start up to \(shown) s late: its first sound arrived during or right after an idle tap refresh, and audio played during the refresh is not in the take.")
        XCTAssertTrue(TakeWarning.startMayBeLate(seconds: 0.022).text(source: .app(name: "afplay"), bundle: try spanish)
            .hasPrefix("Puede que la toma empiece hasta \(shown) s tarde"))
    }

    func testMostlyZeroRendering() throws {
        let (zeros, span) = (2.7.formatted(.number.precision(.fractionLength(3))), 2.71.formatted(.number.precision(.fractionLength(3))))
        XCTAssertEqual(TakeWarning.mostlyZero(zeroSeconds: 2.7, spanSeconds: 2.71).text(source: .app(name: "afplay")),
                       "Most of this take after its first sound is digital zero (\(zeros) s of \(span) s) while afplay was playing. Unless that passage was really silent, CoreAudio delivered zeros instead of its audio and that audio is missing from the take.")
        XCTAssertEqual(TakeWarning.mostlyZero(zeroSeconds: 2.7, spanSeconds: 2.71).text(source: .app(name: "afplay"), bundle: try spanish),
                       "La mayor parte de esta toma tras su primer sonido son ceros digitales (\(zeros) s de \(span) s) mientras afplay sonaba. Salvo que ese pasaje fuera realmente silencioso, CoreAudio entregó ceros en lugar de su audio y ese audio falta en la toma.")
    }

    func testLegacyLibraryEntryMigratesAndIsRewrittenAsCodes() throws {
        let asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        let dir = FileManager.default.temporaryDirectory
        let take = RecordingTake(id: UUID(), source: .app(name: "x"), startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                 captureURL: dir.appendingPathComponent("a.caf"), outputURL: dir.appendingPathComponent("a.wav"),
                                 outputFormat: .wav, captureFormat: try CaptureFormat(validating: asbd))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LibraryEntry(take: take))) as? [String: Any])
        json["source"] = nil
        json["warnings"] = nil
        json["sourceName"] = "All system audio"
        json["warning"] = "The audio device's timeline jumped 1 time(s) (2,107 frames not delivered by CoreAudio). A note from an old build."

        let migrated = try JSONDecoder().decode(LibraryEntry.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated.source, .allSystemAudio)
        XCTAssertEqual(migrated.warnings, [.timelineJumps(count: 1, skippedFrames: 2107), .legacyText(text: "A note from an old build.")])
        XCTAssertEqual(migrated.id, take.id)

        let rewritten = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as? [String: Any])
        XCTAssertNil(rewritten["warning"])
        XCTAssertNil(rewritten["sourceName"])
        XCTAssertEqual(try JSONDecoder().decode(LibraryEntry.self, from: JSONEncoder().encode(migrated)), migrated)
    }
}
