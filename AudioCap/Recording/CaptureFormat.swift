import Foundation
import AVFoundation
import CoreAudio

/// The validated layout of the audio delivered by the aggregate device's input stream.
///
/// The capture path never writes the device format directly: incoming buffers are copied into
/// `writerFormat` (Float32, deinterleaved), which every file writer and exporter accepts.
struct CaptureFormat: Equatable, Sendable, CustomStringConvertible {
    enum SampleType: String, Sendable {
        case float32 = "Float32"
        case float64 = "Float64"
        case int16 = "Int16"
        case int24 = "Int24"
        case int32 = "Int32"

        var bytesPerSample: Int {
            switch self {
            case .float32, .int32: 4
            case .float64: 8
            case .int16: 2
            case .int24: 3
            }
        }
    }

    var sampleRate: Double
    var channelCount: Int
    var sampleType: SampleType
    var isInterleaved: Bool
    var isBigEndian: Bool

    /// The ASBD this format was validated from.
    var sourceDescription: AudioStreamBasicDescription

    /// Index of the first `AudioBuffer` that belongs to the tap. The aggregate device lists the input streams of
    /// its sub-device (for example a microphone or a loopback driver's input) before the tap's streams.
    var firstBufferIndex = 0
    /// Number of buffers that belong to the tap, or `nil` for all buffers from `firstBufferIndex` on.
    var bufferCount: Int?

    var description: String {
        "\(Self.rateString(sampleRate)) · \(channelCount) ch · \(sampleType.rawValue) · \(isInterleaved ? "interleaved" : "non-interleaved")"
    }

    /// The canonical format every capture file is written in: Float32, deinterleaved, same rate and channels.
    var writerFormat: AVAudioFormat {
        Self.canonicalFormat(sampleRate: sampleRate, channelCount: channelCount)
    }

    static func canonicalFormat(sampleRate: Double, channelCount: Int) -> AVAudioFormat {
        let channels = AVAudioChannelCount(channelCount)
        if channels <= 2, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) {
            return format
        }
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
    }

    static func rateString(_ rate: Double) -> String {
        rate.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(rate / 1000)) kHz" : String(format: "%.1f kHz", rate / 1000)
    }

    enum ValidationError: LocalizedError, Equatable {
        case notLinearPCM(String)
        case invalidSampleRate(Double)
        case invalidChannelCount(UInt32)
        case unsupportedSampleType(bits: UInt32, isFloat: Bool)
        case inconsistentLayout(String)

        var errorDescription: String? {
            switch self {
            case .notLinearPCM(let id): "The capture stream is not linear PCM (format '\(id)')."
            case .invalidSampleRate(let rate): "The capture stream reports an invalid sample rate (\(rate) Hz)."
            case .invalidChannelCount(let count): "The capture stream reports \(count) channels."
            case .unsupportedSampleType(let bits, let isFloat): "Unsupported capture sample type: \(bits)-bit \(isFloat ? "float" : "integer")."
            case .inconsistentLayout(let detail): "The capture stream layout is inconsistent: \(detail)."
            }
        }
    }

    /// Validates an ASBD read from the aggregate device and normalizes it.
    ///
    /// `fallbackSampleRate` (usually the aggregate's nominal rate) replaces a missing rate.
    /// Missing byte/packet sizes are derived from the bit depth; contradictory ones are rejected.
    init(validating asbd: AudioStreamBasicDescription, fallbackSampleRate: Double? = nil) throws {
        guard asbd.mFormatID == kAudioFormatLinearPCM else {
            throw ValidationError.notLinearPCM(AudioStatus.fourCharCode(OSStatus(bitPattern: asbd.mFormatID)) ?? "\(asbd.mFormatID)")
        }
        var rate = asbd.mSampleRate
        if !(rate.isFinite && rate > 0), let fallbackSampleRate, fallbackSampleRate.isFinite, fallbackSampleRate > 0 {
            rate = fallbackSampleRate
        }
        guard rate.isFinite, rate >= 8_000, rate <= 768_000 else { throw ValidationError.invalidSampleRate(asbd.mSampleRate) }
        guard asbd.mChannelsPerFrame > 0, asbd.mChannelsPerFrame <= 64 else {
            throw ValidationError.invalidChannelCount(asbd.mChannelsPerFrame)
        }

        let flags = asbd.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isNonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        var bits = asbd.mBitsPerChannel
        let channels = asbd.mChannelsPerFrame

        if bits == 0, asbd.mBytesPerFrame > 0 {
            bits = (asbd.mBytesPerFrame * 8) / (isNonInterleaved ? 1 : channels)
        }
        let type: SampleType
        switch (isFloat, bits) {
        case (true, 32): type = .float32
        case (true, 64): type = .float64
        case (false, 16): type = .int16
        case (false, 24): type = .int24
        case (false, 32): type = .int32
        case (true, 0): type = .float32
        default: throw ValidationError.unsupportedSampleType(bits: bits, isFloat: isFloat)
        }

        if type != .float32, flags & kAudioFormatFlagIsPacked == 0, type == .int24 {
            throw ValidationError.inconsistentLayout("unpacked 24-bit samples")
        }
        let expectedBytesPerFrame = UInt32(type.bytesPerSample) * (isNonInterleaved ? 1 : channels)
        if asbd.mBytesPerFrame != 0, asbd.mBytesPerFrame != expectedBytesPerFrame {
            throw ValidationError.inconsistentLayout("\(asbd.mBytesPerFrame) bytes per frame, expected \(expectedBytesPerFrame)")
        }
        if asbd.mFramesPerPacket > 1 {
            throw ValidationError.inconsistentLayout("\(asbd.mFramesPerPacket) frames per packet")
        }

        self.sampleRate = rate
        self.channelCount = Int(channels)
        self.sampleType = type
        self.isInterleaved = !isNonInterleaved || channels == 1
        self.isBigEndian = flags & kAudioFormatFlagIsBigEndian != 0
        self.sourceDescription = asbd
    }

    static func == (lhs: CaptureFormat, rhs: CaptureFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate && lhs.channelCount == rhs.channelCount && lhs.sampleType == rhs.sampleType
            && lhs.isInterleaved == rhs.isInterleaved && lhs.isBigEndian == rhs.isBigEndian
            && lhs.firstBufferIndex == rhs.firstBufferIndex && lhs.bufferCount == rhs.bufferCount
    }
}

extension AudioStreamBasicDescription {
    /// A compact dump for diagnostics, with the format id and flags decoded.
    var diagnosticDescription: String {
        let id = AudioStatus.fourCharCode(OSStatus(bitPattern: mFormatID)) ?? "\(mFormatID)"
        var flagNames: [String] = []
        if mFormatFlags & kAudioFormatFlagIsFloat != 0 { flagNames.append("float") }
        if mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 { flagNames.append("signed") }
        if mFormatFlags & kAudioFormatFlagIsPacked != 0 { flagNames.append("packed") }
        if mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 { flagNames.append("non-interleaved") }
        if mFormatFlags & kAudioFormatFlagIsBigEndian != 0 { flagNames.append("big-endian") }
        return "rate=\(mSampleRate) id='\(id)' flags=0x\(String(mFormatFlags, radix: 16))[\(flagNames.joined(separator: ","))] bytesPerPacket=\(mBytesPerPacket) framesPerPacket=\(mFramesPerPacket) bytesPerFrame=\(mBytesPerFrame) channels=\(mChannelsPerFrame) bits=\(mBitsPerChannel)"
    }
}
