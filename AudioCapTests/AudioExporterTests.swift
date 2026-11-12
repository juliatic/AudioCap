import XCTest
import AVFoundation
@testable import AudioCap

final class AudioExporterTests: TemporaryDirectoryTestCase {
    /// 220,500 frames is not a multiple of any codec block size (FLAC 4,096/4,608, ALAC 4,096, AAC 1,024).
    /// 4,608 is the shortest input Apple's FLAC encoder accepts (see `testFlacRejectsTakesShorterThanOneBlock`).
    private let frameCounts = [220_500, 12_345, 4_609, 4_608, 1]

    func testExactDurationForEveryFormat() throws {
        for frames in frameCounts {
            let caf = url("src-\(frames).caf")
            try Synth.writeCAF(Synth.buffer(frames: frames), to: caf)
            for format in RecordingSettings.OutputFormat.allCases where !(format == .flac && frames < 4_608) {
                let out = url("out-\(frames)-\(format.rawValue).\(format.fileExtension)")
                let result = try AudioExporter.export(from: caf, to: out, format: format, expectedFrames: AVAudioFramePosition(frames))
                XCTAssertEqual(result.frameCount, AVAudioFramePosition(frames), "\(format) \(frames)")
                XCTAssertEqual(try AVAudioFile(forReading: out).length, AVAudioFramePosition(frames), "\(format) \(frames)")
            }
        }
    }

    func testLosslessFormatsAreBitExact() throws {
        let source = Synth.buffer(frames: 220_500)
        let caf = url("src.caf")
        try Synth.writeCAF(source, to: caf)
        for format in [RecordingSettings.OutputFormat.wav, .flac, .alac] {
            let out = url("lossless.\(format.rawValue).\(format.fileExtension)")
            try AudioExporter.export(from: caf, to: out, format: format)
            let decoded = try Synth.readAll(out)
            XCTAssertEqual(decoded.frameLength, source.frameLength, "\(format)")
            XCTAssertEqual(Synth.maxDifference(decoded, source), 0, "\(format) is not bit-exact")
        }
    }

    func testFlacIs24Bit() throws {
        let caf = url("src.caf")
        try Synth.writeCAF(Synth.buffer(frames: 10_000), to: caf)
        let out = url("depth.flac")
        try AudioExporter.export(from: caf, to: out, format: .flac)
        let file = try AVAudioFile(forReading: out)
        let asbd = file.fileFormat.streamDescription.pointee
        XCTAssertEqual(asbd.mFormatID, kAudioFormatFLAC)
        XCTAssertEqual(asbd.mFormatFlags, kAppleLosslessFormatFlag_24BitSourceData)
    }

    func testWavIsFloat32() throws {
        let caf = url("src.caf")
        try Synth.writeCAF(Synth.buffer(frames: 10_000, sampleRate: 96_000), to: caf)
        let out = url("raw.wav")
        try AudioExporter.export(from: caf, to: out, format: .wav)
        let format = try AVAudioFile(forReading: out).fileFormat
        XCTAssertEqual(format.commonFormat, .pcmFormatFloat32)
        XCTAssertEqual(format.sampleRate, 96_000)
    }

    func testHighRateAACIsResampledWithMatchingDuration() throws {
        let caf = url("src96.caf")
        try Synth.writeCAF(Synth.buffer(frames: 96_000 * 2 + 7, sampleRate: 96_000), to: caf)
        let out = url("hi.m4a")
        let result = try AudioExporter.export(from: caf, to: out, format: .aac)
        XCTAssertEqual(result.sampleRate, 48_000)
        XCTAssertEqual(Double(result.frameCount), Double(96_000 + 3.5), accuracy: 2)
        XCTAssertEqual(try AVAudioFile(forReading: out).fileFormat.sampleRate, 48_000)
    }

    func testFlacRejectsTakesShorterThanOneBlock() throws {
        let caf = url("tiny.caf")
        try Synth.writeCAF(Synth.buffer(frames: 1_000), to: caf)
        let out = url("tiny.flac")
        XCTAssertThrowsError(try AudioExporter.export(from: caf, to: out, format: .flac)) { error in
            XCTAssertEqual(error as? AudioExporter.ExportError, .tooShort(format: .flac, frames: 1_000, minimumFrames: 4_608))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testProgressReachesOne() throws {
        let caf = url("src.caf")
        try Synth.writeCAF(Synth.buffer(frames: 100_000), to: caf)
        var values: [Double] = []
        try AudioExporter.export(from: caf, to: url("p.flac"), format: .flac, chunkSize: 8_192) { values.append($0) }
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 1)
        XCTAssertEqual(values, values.sorted())
    }

    func testDurationMismatchIsReportedAndPartialOutputRemoved() throws {
        let caf = url("src.caf")
        try Synth.writeCAF(Synth.buffer(frames: 10_000), to: caf)
        let out = url("short.flac")
        XCTAssertThrowsError(try AudioExporter.export(from: caf, to: out, format: .flac, expectedFrames: 10_001)) { error in
            guard case .durationMismatch(_, 10_001, 10_000, _) = error as? AudioExporter.ExportError else {
                return XCTFail("Unexpected error \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }
}

/// Regression for the lost final FLAC block: the committed `test.flac` was produced from `test.wav`
/// by the old converter and is missing the last 3,412 frames (220,500 → 217,088).
final class LostFinalBlockRegressionTests: TemporaryDirectoryTestCase {
    private var wavURL: URL { Bundle(for: Self.self).url(forResource: "test", withExtension: "wav")! }
    private var flacURL: URL { Bundle(for: Self.self).url(forResource: "test", withExtension: "flac")! }

    func testFixtureShowsTheBug() throws {
        XCTAssertEqual(try AVAudioFile(forReading: wavURL).length, 220_500)
        XCTAssertEqual(try AVAudioFile(forReading: flacURL).length, 217_088)
    }

    func testDurationCheckCatchesTheTruncatedFile() {
        XCTAssertThrowsError(try AudioExporter.verifyDuration(of: flacURL, expectedFrames: 220_500, captureSampleRate: 44_100)) { error in
            XCTAssertEqual(error as? AudioExporter.ExportError,
                           .durationMismatch(url: flacURL, expectedFrames: 220_500, actualFrames: 217_088, sampleRate: 44_100))
        }
    }

    func testExporterKeepsTheFinalBlock() throws {
        for format in RecordingSettings.OutputFormat.allCases {
            let out = url("fixture.\(format.rawValue).\(format.fileExtension)")
            let result = try AudioExporter.export(from: wavURL, to: out, format: format, expectedFrames: 220_500)
            XCTAssertEqual(result.frameCount, 220_500, "\(format)")
        }
        let original = try Synth.readAll(wavURL)
        let flac = try Synth.readAll(url("fixture.flac.flac"))
        XCTAssertEqual(flac.frameLength, 220_500)
        // FLAC stores 24 bits; the fixture is Float32, so allow half a 24-bit step (plus clipping at full scale).
        XCTAssertLessThanOrEqual(Synth.maxDifference(original, flac), 1.0 / 8_388_608)
    }
}
