import XCTest
import AVFoundation
@testable import AudioCap

final class CaptureWriterTests: TemporaryDirectoryTestCase {
    func testWritesEveryFrameAndVerifiesOnClose() throws {
        let source = Synth.buffer(frames: 220_500)
        let writer = try CaptureWriter(url: url("take.caf"), format: source.format)
        var offset = 0
        // Odd chunk sizes, like real I/O cycles.
        for size in [512, 471, 1_024, 333].cycled(while: { offset < 220_500 }) {
            let n = min(size, 220_500 - offset)
            writer.write(Synth.slice(source, from: offset, count: n))
            offset += n
        }
        XCTAssertEqual(try writer.finish(), 220_500)

        let file = try AVAudioFile(forReading: url("take.caf"))
        XCTAssertEqual(file.length, 220_500)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(Synth.maxDifference(try Synth.readAll(url("take.caf")), source), 0)
    }

    func testCaptureIsReadableBeforeClose() throws {
        let source = Synth.buffer(frames: 48_000, sampleRate: 48_000)
        let writer = try CaptureWriter(url: url("open.caf"), format: source.format)
        writer.write(source)
        // A crash at this point leaves a CAF that still opens with the audio written so far.
        let length = try AVAudioFile(forReading: url("open.caf")).length
        XCTAssertGreaterThan(length, 0)
        XCTAssertEqual(try writer.finish(), 48_000)
    }

    func testFinishTwiceThrows() throws {
        let source = Synth.buffer(frames: 100)
        let writer = try CaptureWriter(url: url("twice.caf"), format: source.format)
        writer.write(source)
        XCTAssertEqual(try writer.finish(), 100)
        XCTAssertThrowsError(try writer.finish()) { error in
            XCTAssertEqual(error as? CaptureWriter.WriterError, .alreadyFinished)
        }
    }

    func testRejectsBufferInAnotherFormat() throws {
        let writer = try CaptureWriter(url: url("mismatch.caf"), format: Synth.buffer(frames: 1).format)
        writer.write(Synth.buffer(frames: 100, sampleRate: 96_000))
        XCTAssertThrowsError(try writer.finish())
    }
}

private extension Array {
    /// Repeats the array's elements while `condition` holds.
    func cycled(while condition: @escaping () -> Bool) -> AnySequence<Element> {
        AnySequence { () -> AnyIterator<Element> in
            var index = 0
            return AnyIterator {
                guard condition() else { return nil }
                defer { index = (index + 1) % self.count }
                return self[index]
            }
        }
    }
}
