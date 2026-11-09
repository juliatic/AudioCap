import XCTest
@testable import AudioCap

/// Edge shapes measured from a process tap (afplay, 48 kHz): a hard cut keeps full level up to its last loud sample,
/// then rings for ~1 ms below 5 % of it before exact zeros, and the same ringing leads into a hard onset.
final class EdgeShapeTests: XCTestCase {
    private static let rate = 48_000.0

    private static func tone(_ i: Int, phase: Double = 0) -> Float {
        0.5 * Float(sin(phase + 2 * Double.pi * 1_000 * Double(i) / rate))
    }

    /// 48 frames of alternating ringing decaying from 0.025, as the tap delivered after a 0.5 cut.
    private static func ringing(_ i: Int) -> Float {
        (i % 2 == 0 ? 1 : -1) * 0.025 * Float(exp(-Double(i) / 12))
    }

    private static func cutWithRinging(soundFrames: Int, zeros: Int) -> [Float] {
        (0..<soundFrames).map { tone($0, phase: .pi / 2) } + (0..<48).map(ringing) + [Float](repeating: 0, count: zeros)
    }

    private func feed<M>(_ meter: inout M, _ samples: [Float], chunk: Int = 512, playing: Bool = true,
                         _ add: (inout M, UnsafePointer<UnsafeMutablePointer<Float>>, Int, Bool) -> Void) {
        var start = 0
        while start < samples.count {
            let n = min(chunk, samples.count - start)
            var left = Array(samples[start..<start + n])
            var right = left
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    let channels = [l.baseAddress!, r.baseAddress!]
                    channels.withUnsafeBufferPointer { add(&meter, $0.baseAddress!, n, playing) }
                }
            }
            start += n
        }
    }

    private func edges(_ samples: [Float], zerosBefore: Int = 0) -> PassageEdges {
        var edges = PassageEdges(sampleRate: Self.rate, zerosBefore: zerosBefore)
        feed(&edges, samples) { $0.add($1, channels: 2, frames: $2, sourceIsPlaying: $3) }
        return edges
    }

    func testHardCutWithTapRingingIsAbrupt() {
        let samples = Self.cutWithRinging(soundFrames: 24_000, zeros: 24_000)
        XCTAssertEqual(edges(samples).abruptEndFrame, 24_048)
    }

    func testFastFadeToZeroIsNotAbrupt() {
        let fade = 960 // 20 ms
        let samples = (0..<24_000).map { i in Self.tone(i) * min(1, Float(24_000 - i) / Float(fade)) } + [Float](repeating: 0, count: 24_000)
        XCTAssertNil(edges(samples).abruptEndFrame)
    }

    func testHardOnsetAfterRingingIsAbruptAndZeroCrossingOnsetIsNot() {
        let ring = (0..<30).map { Self.ringing(29 - $0) }
        let zeros = [Float](repeating: 0, count: 4_800)
        let midWaveform = zeros + ring + (0..<4_800).map { Self.tone($0, phase: .pi / 2) }
        XCTAssertEqual(edges(midWaveform).abruptOnsetFrame, 4_800)
        let fromZero = zeros + ring.map { $0 / 15 } + (0..<4_800).map { Self.tone($0) }
        XCTAssertNil(edges(fromZero).abruptOnsetFrame)
    }

    func testHoleWithRingingOnBothSidesIsCounted() {
        let ringIn = (0..<30).map { Self.ringing(29 - $0) }
        let samples = Self.cutWithRinging(soundFrames: 4_800, zeros: 78) + ringIn + (0..<4_800).map { Self.tone($0, phase: .pi / 2) }
        var meter = ZeroSpanMeter(maxHoleFrames: 48_000, sampleRate: Self.rate)
        feed(&meter, samples) { $0.add($1, channels: 2, frames: $2, sourceIsPlaying: $3) }
        XCTAssertEqual(meter.holes, 1)
        XCTAssertEqual(meter.holeFrames, 78)
    }

    /// Auto-record keeps a 0.5 s tail and trims the rest of the 2 s of silence that closes the take.
    func testShortBurstThenTrimmedZerosIsFlaggedAndANormalEndingIsNot() {
        func meter(soundFrames: Int, playing: Bool = true) -> ZeroSpanMeter {
            var meter = ZeroSpanMeter(maxHoleFrames: 48_000, sampleRate: Self.rate)
            feed(&meter, Self.cutWithRinging(soundFrames: soundFrames, zeros: 24_000)) { $0.add($1, channels: 2, frames: $2, sourceIsPlaying: $3) }
            meter.addTrimmedZeros(72_000, sourceIsPlaying: playing)
            return meter
        }
        let burst = meter(soundFrames: 2_400)
        XCTAssertFalse(burst.isMostlyZero(sampleRate: Self.rate))
        XCTAssertTrue(burst.isShortSoundThenTrimmedZeros(sampleRate: Self.rate))
        XCTAssertEqual(burst.soundFrames, 2_448)
        XCTAssertEqual(burst.trailingZeroFrames, 96_000)
        XCTAssertFalse(meter(soundFrames: 48_000).isShortSoundThenTrimmedZeros(sampleRate: Self.rate))
        XCTAssertFalse(meter(soundFrames: 2_400, playing: false).isShortSoundThenTrimmedZeros(sampleRate: Self.rate))
    }

    func testCutRightAtTheTakeEndIsFoundFromTrimmedZeros() {
        var cut = edges((0..<2_400).map { Self.tone($0, phase: .pi / 2) })
        XCTAssertNil(cut.abruptEndFrame)
        cut.addTrimmedZeros(96_000, sourceIsPlaying: true)
        XCTAssertEqual(cut.abruptEndFrame, 2_400)
        XCTAssertEqual(cut.trailingZeros, 96_000)
        var stopped = edges((0..<2_400).map { Self.tone($0, phase: .pi / 2) })
        stopped.addTrimmedZeros(96_000, sourceIsPlaying: false)
        XCTAssertNil(stopped.abruptEndFrame)
    }
}
