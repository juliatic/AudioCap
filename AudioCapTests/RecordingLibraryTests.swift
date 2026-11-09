import XCTest
import AVFoundation
@testable import AudioCap

@MainActor
final class RecordingLibraryTests: TemporaryDirectoryTestCase {
    private var indexURL: URL { url("Index/library.json") }

    private func captureFormat(rate: Double = 48_000, channels: UInt32 = 2) throws -> CaptureFormat {
        let asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                               mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        return try CaptureFormat(validating: asbd)
    }

    private func take(_ name: String = "Take", format: RecordingSettings.OutputFormat = .wav,
                      status: RecordingTake.Status = .recording, frames: Int64 = 0) throws -> RecordingTake {
        var take = RecordingTake(id: UUID(), source: .app(name: "Music"), startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                 captureURL: url("\(name).caf"), outputURL: url("\(name).\(format.fileExtension)"),
                                 outputFormat: format, captureFormat: try captureFormat())
        take.status = status
        take.capturedFrames = frames
        return take
    }

    func testIndexPersistsAndReloads() async throws {
        let library = RecordingLibrary(indexURL: indexURL)
        var recorded = try take(frames: 0)
        library.apply(.added(recorded))
        recorded.status = .failed(message: "Disk full")
        recorded.capturedFrames = 96_000
        recorded.warnings = [.allZero]
        library.apply(.updated(recorded))

        let reloaded = RecordingLibrary(indexURL: indexURL)
        XCTAssertEqual(reloaded.entries.count, 1)
        let entry = try XCTUnwrap(reloaded.entries.first)
        XCTAssertEqual(entry.id, recorded.id)
        XCTAssertEqual(entry.sourceName, "Music")
        XCTAssertEqual(entry.startedAt, recorded.startedAt)
        XCTAssertEqual(entry.sampleRate, 48_000)
        XCTAssertEqual(entry.channelCount, 2)
        XCTAssertEqual(entry.capturedFrames, 96_000)
        XCTAssertEqual(entry.duration, 2, accuracy: 1e-9)
        XCTAssertEqual(entry.status, .failed(reason: "Disk full"))
        XCTAssertEqual(entry.warnings, [.allZero])
    }

    func testTakesStillBusyWhenTheAppQuitReloadAsFailed() throws {
        let library = RecordingLibrary(indexURL: indexURL)
        library.apply(.added(try take("A")))
        library.apply(.added(try take("B", status: .exporting(progress: 0.4))))

        let reloaded = RecordingLibrary(indexURL: indexURL)
        XCTAssertEqual(reloaded.entries.count, 2)
        for entry in reloaded.entries {
            guard case .failed = entry.status else { return XCTFail("\(entry.status)") }
        }
    }

    func testUnreadableIndexStartsEmptyAndKeepsTheFile() throws {
        try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: indexURL)
        let library = RecordingLibrary(indexURL: indexURL)
        XCTAssertTrue(library.entries.isEmpty)
        XCTAssertNotNil(library.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.appendingPathExtension("unreadable").path))
    }

    func testStatusTransitions() {
        typealias S = LibraryEntry.Status
        XCTAssertTrue(S.canTransition(from: .recording, to: .converting(progress: 0)))
        XCTAssertTrue(S.canTransition(from: .recording, to: .failed(reason: "x")))
        XCTAssertTrue(S.canTransition(from: .converting(progress: 0.2), to: .converting(progress: 0.5)))
        XCTAssertTrue(S.canTransition(from: .converting(progress: 1), to: .done))
        XCTAssertTrue(S.canTransition(from: .converting(progress: 0.5), to: .failed(reason: "x")))
        XCTAssertTrue(S.canTransition(from: .failed(reason: "x"), to: .converting(progress: 0)))
        XCTAssertFalse(S.canTransition(from: .done, to: .converting(progress: 0.9)))
        XCTAssertFalse(S.canTransition(from: .done, to: .recording))
        XCTAssertFalse(S.canTransition(from: .failed(reason: "x"), to: .done))
        XCTAssertFalse(S.canTransition(from: .converting(progress: 0.5), to: .recording))
    }

    func testReconnectNoteFromTheRecorderIsKeptOnTheEntry() throws {
        let library = RecordingLibrary(indexURL: indexURL)
        var recorded = try take()
        library.apply(.added(recorded))
        XCTAssertEqual(library.entries.first?.warnings, [])

        recorded.warnings = [.reconnected(count: 2)]
        recorded.status = .exporting(progress: 0)
        library.apply(.updated(recorded))
        recorded.status = .completed
        library.apply(.updated(recorded))

        let entry = try XCTUnwrap(RecordingLibrary(indexURL: indexURL).entries.first)
        XCTAssertEqual(entry.status, .done)
        XCTAssertEqual(entry.warnings, [.reconnected(count: 2)])
    }

    func testRecorderEventsDriveStatusAndLateProgressIsIgnored() async throws {
        let library = RecordingLibrary(indexURL: indexURL)
        var recorded = try take()
        library.apply(.added(recorded))
        XCTAssertEqual(library.entries.first?.status, .recording)

        recorded.status = .exporting(progress: 0.5)
        library.apply(.updated(recorded))
        XCTAssertEqual(library.entries.first?.status, .converting(progress: 0.5))

        recorded.status = .completed
        library.apply(.updated(recorded))
        XCTAssertEqual(library.entries.first?.status, .done)

        recorded.status = .exporting(progress: 0.9)
        library.apply(.updated(recorded))
        XCTAssertEqual(library.entries.first?.status, .done)

        library.apply(.removed(recorded.id))
        XCTAssertTrue(library.entries.isEmpty)
        await library.settle()
    }

    func testDoneTakeIsAnalysedFromTheFileOnDisk() async throws {
        let buffer = Synth.buffer(frames: 48_000, sampleRate: 48_000, amplitude: 0.5)
        var recorded = try take(frames: 48_000)
        try Synth.writeCAF(buffer, to: recorded.captureURL)
        try AudioExporter.export(from: recorded.captureURL, to: recorded.outputURL, format: .wav)

        let library = RecordingLibrary(indexURL: indexURL)
        recorded.status = .completed
        recorded.exportedFrames = 48_000
        library.apply(.added(recorded))
        await library.settle()

        let analysis = try XCTUnwrap(library.entries.first?.analysis)
        XCTAssertEqual(analysis.headerFrames, 48_000)
        XCTAssertEqual(analysis.decodedFrames, 48_000)
        XCTAssertEqual(analysis.payloadFrames, 48_000)
        XCTAssertTrue(analysis.lengthMatches)
        XCTAssertEqual(library.entries.first?.lengthIsConsistent, true)
        XCTAssertLessThanOrEqual(analysis.peak, 0.5 + 1e-6)
        XCTAssertGreaterThan(analysis.peak, 0.3)
        XCTAssertNotNil(RecordingLibrary(indexURL: indexURL).entries.first?.analysis)
    }

    func testRetryConversionExportsTheCaptureAgain() async throws {
        var recorded = try take(format: .flac, frames: 44_100)
        try Synth.writeCAF(Synth.buffer(frames: 44_100, sampleRate: 48_000), to: recorded.captureURL)
        let library = RecordingLibrary(indexURL: indexURL)
        recorded.status = .failed(message: "Converter error")
        library.apply(.added(recorded))

        library.retryConversion(recorded.id)
        guard case .converting = library.entries.first?.status else { return XCTFail("not converting") }
        await library.settle()

        XCTAssertEqual(library.entries.first?.status, .done)
        XCTAssertEqual(library.entries.first?.exportedFrames, 44_100)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recorded.outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorded.captureURL.path))
        XCTAssertEqual(library.entries.first?.analysis?.decodedFrames, 44_100)
    }

    func testRetryWithoutCaptureStaysFailed() throws {
        let library = RecordingLibrary(indexURL: indexURL)
        library.apply(.added(try take(status: .failed(message: "x"))))
        library.retryConversion(library.entries[0].id)
        XCTAssertEqual(library.entries.first?.status, .failed(reason: LibraryError.captureMissing.localizedDescription))
    }

    func testRenameMovesTheFileAndPersists() throws {
        let recorded = try take("Old", status: .completed)
        try Data("x".utf8).write(to: recorded.outputURL)
        let library = RecordingLibrary(indexURL: indexURL)
        library.apply(.added(recorded))

        try library.rename(recorded.id, to: "  New name ")
        XCTAssertEqual(library.entries.first?.displayName, "New name")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url("New name.wav").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorded.outputURL.path))
        XCTAssertEqual(RecordingLibrary(indexURL: indexURL).entries.first?.fileURL.lastPathComponent, "New name.wav")

        XCTAssertThrowsError(try library.rename(recorded.id, to: "a/b")) { XCTAssertEqual($0 as? LibraryError, .invalidName) }
        try Data("y".utf8).write(to: url("Taken.wav"))
        XCTAssertThrowsError(try library.rename(recorded.id, to: "Taken")) { XCTAssertEqual($0 as? LibraryError, .nameTaken("Taken.wav")) }
    }

    func testBusyTakesCanNotBeRenamedOrTrashed() throws {
        let library = RecordingLibrary(indexURL: indexURL)
        let recorded = try take()
        library.apply(.added(recorded))
        XCTAssertThrowsError(try library.rename(recorded.id, to: "X")) { XCTAssertEqual($0 as? LibraryError, .busy) }
        XCTAssertThrowsError(try library.moveToTrash(recorded.id)) { XCTAssertEqual($0 as? LibraryError, .busy) }
    }

    func testMoveToTrashRemovesFileAndEntry() throws {
        let recorded = try take("Trash me", status: .completed)
        try Data("x".utf8).write(to: recorded.outputURL)
        let library = RecordingLibrary(indexURL: indexURL)
        library.apply(.added(recorded))

        try library.moveToTrash(recorded.id)
        XCTAssertTrue(library.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorded.outputURL.path))
        XCTAssertTrue(RecordingLibrary(indexURL: indexURL).entries.isEmpty)
    }
}
