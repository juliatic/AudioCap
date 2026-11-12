import XCTest
import AVFoundation
@testable import AudioCap

@MainActor
final class OutputOnlyPlayerTests: TemporaryDirectoryTestCase {
    private func wav(frames: Int) throws -> URL {
        let caf = url("source.caf")
        try Synth.writeCAF(Synth.buffer(frames: frames, sampleRate: 48_000), to: caf)
        let wav = url("take.wav")
        try AudioExporter.export(from: caf, to: wav, format: .wav)
        return wav
    }

    /// Opening the output device's input side is what makes macOS ask for microphone access on Play.
    /// Must not open the output device: on a device with inputs that alone can raise the microphone prompt.
    func testLoadingDoesNotStartTheEngine() throws {
        let player = try OutputOnlyPlayer(url: wav(frames: 48_000))
        XCTAssertFalse(player.hasEngine)
    }

    func testDurationAndSeekWhilePaused() throws {
        let player = try OutputOnlyPlayer(url: wav(frames: 96_000))
        XCTAssertEqual(player.duration, 2, accuracy: 1e-9)
        XCTAssertFalse(player.isPlaying)
        player.currentTime = 1.5
        XCTAssertEqual(player.currentTime, 1.5, accuracy: 1e-4)
        player.currentTime = 10
        XCTAssertEqual(player.currentTime, 2, accuracy: 1e-9)
        player.currentTime = -1
        XCTAssertEqual(player.currentTime, 0)
    }
}
