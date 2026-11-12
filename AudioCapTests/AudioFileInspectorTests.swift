import XCTest
import AVFoundation
@testable import AudioCap

final class AudioFileInspectorTests: TemporaryDirectoryTestCase {
    private func wav(frames: Int) throws -> URL {
        let caf = url("source.caf")
        try Synth.writeCAF(Synth.buffer(frames: frames, sampleRate: 48_000), to: caf)
        let wav = url("take.wav")
        try AudioExporter.export(from: caf, to: wav, format: .wav)
        return wav
    }

    func testConsistentWAV() throws {
        let (analysis, waveform) = try AudioFileInspector.analyze(try wav(frames: 10_000), waveformBins: 50)
        XCTAssertEqual(analysis.headerFrames, 10_000)
        XCTAssertEqual(analysis.decodedFrames, 10_000)
        XCTAssertEqual(analysis.payloadFrames, 10_000)
        XCTAssertTrue(analysis.lengthMatches)
        XCTAssertEqual(waveform.count, 50)
        XCTAssertTrue(waveform.allSatisfy { $0 > 0 })
    }

    /// The reported bug: a header that declares fewer frames than the file holds.
    func testHeaderShorterThanPayloadIsDetected() throws {
        let url = try wav(frames: 10_000)
        var data = try Data(contentsOf: url)
        let range = try XCTUnwrap(data.range(of: Data("data".utf8)))
        let declared = UInt32(4_000 * 8)  // 4,000 frames of stereo Float32
        withUnsafeBytes(of: declared.littleEndian) { data.replaceSubrange(range.upperBound..<range.upperBound + 4, with: $0) }
        try data.write(to: url)

        let analysis = try AudioFileInspector.analyze(url).analysis
        XCTAssertEqual(analysis.headerFrames, 4_000)
        XCTAssertEqual(analysis.payloadFrames, 10_000)
        XCTAssertFalse(analysis.lengthMatches)
        XCTAssertEqual(analysis.decodedDuration, 10_000 / 48_000, accuracy: 1e-9)
    }

    func testCompressedFilesHaveNoPayloadCount() throws {
        let caf = url("source.caf")
        try Synth.writeCAF(Synth.buffer(frames: 10_000, sampleRate: 48_000), to: caf)
        let flac = url("take.flac")
        try AudioExporter.export(from: caf, to: flac, format: .flac)
        let analysis = try AudioFileInspector.analyze(flac).analysis
        XCTAssertNil(analysis.payloadFrames)
        XCTAssertEqual(analysis.decodedFrames, 10_000)
        XCTAssertTrue(analysis.lengthMatches)
    }

    func testCAFPayloadIsCounted() throws {
        let caf = url("source.caf")
        try Synth.writeCAF(Synth.buffer(frames: 12_345, sampleRate: 48_000), to: caf)
        XCTAssertEqual(AudioFileInspector.pcmPayloadFrames(of: caf), 12_345)
    }
}

final class OutputFolderTests: XCTestCase {
    func testDefaultIsMusicAudioCapInTheRealHome() {
        let url = OutputFolder.defaultURL
        XCTAssertEqual(url.lastPathComponent, "AudioCap")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Music")
        XCTAssertFalse(url.path.contains("/Library/Containers/"))
    }

    func testChosenFolderPersistsAndResets() throws {
        let suite = "OutputFolderTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appending(path: "OutputFolderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let folder = OutputFolder(defaults: defaults)
        XCTAssertTrue(folder.isDefault)
        try folder.choose(dir)
        XCTAssertFalse(folder.isDefault)
        XCTAssertEqual(OutputFolder(defaults: defaults).url.standardizedFileURL.resolvingSymlinksInPath(), dir.standardizedFileURL.resolvingSymlinksInPath())
        folder.resetToDefault()
        XCTAssertTrue(OutputFolder(defaults: defaults).isDefault)
    }
}
