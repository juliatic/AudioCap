import Foundation
import AudioToolbox
import AVFoundation

/// Decodes `OSStatus` values (CoreAudio, AudioToolbox, AVFAudio) into readable text.
///
/// Most CoreAudio errors are four-char codes packed into an `Int32`, e.g. `1718449215` is `'fmt?'`.
enum AudioStatus {
    /// The four-char code of `status` (for example `fmt?`), or `nil` when the bytes are not printable ASCII.
    static func fourCharCode(_ status: OSStatus) -> String? {
        let value = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }

    /// The known meaning of a CoreAudio/AudioToolbox status code, if any.
    static func meaning(_ status: OSStatus) -> String? {
        knownCodes[status]
    }

    /// Several AudioToolbox constants share a code (for example three `'fmt?'`s); the first entry wins.
    private static let knownCodes: [OSStatus: String] = Dictionary(knownCodeList, uniquingKeysWith: { first, _ in first })

    /// `"'fmt?' (1718449215): unsupported data format"`, or just the number for plain codes.
    static func describe(_ status: OSStatus) -> String {
        var text = fourCharCode(status).map { "'\($0)' (\(status))" } ?? "\(status)"
        if let meaning = meaning(status) { text += ": \(meaning)" }
        return text
    }

    private static let knownCodeList: [(OSStatus, String)] = [
        (kAudioHardwareNotRunningError, "the audio hardware is not running"),
        (kAudioHardwareUnspecifiedError, "unspecified audio hardware error"),
        (kAudioHardwareUnknownPropertyError, "unknown property"),
        (kAudioHardwareBadPropertySizeError, "bad property size"),
        (kAudioHardwareIllegalOperationError, "illegal operation"),
        (kAudioHardwareBadObjectError, "the audio object no longer exists"),
        (kAudioHardwareBadDeviceError, "the audio device no longer exists"),
        (kAudioHardwareBadStreamError, "the audio stream no longer exists"),
        (kAudioHardwareUnsupportedOperationError, "unsupported operation"),
        (kAudioHardwareNotReadyError, "the audio device is not ready"),
        (kAudioDeviceUnsupportedFormatError, "the device does not support this format"),
        (kAudioDevicePermissionsError, "permission denied (check the audio recording permission)"),
        (kAudioFormatUnsupportedDataFormatError, "unsupported data format"),
        (kAudioFormatUnsupportedPropertyError, "unsupported format property"),
        (kAudioFormatBadPropertySizeError, "bad format property size"),
        (kAudioFormatUnknownFormatError, "unknown audio format"),
        (kAudioFileUnsupportedDataFormatError, "the file type does not support this data format"),
        (kAudioFileUnsupportedFileTypeError, "unsupported file type"),
        (kAudioFileInvalidFileError, "the file is malformed or damaged"),
        (kAudioFilePermissionsError, "no permission to write the file"),
        (kAudioFileNotOptimizedError, "the file is not optimized"),
        (kAudioConverterErr_FormatNotSupported, "the converter does not support this format"),
        (kAudioConverterErr_InvalidInputSize, "invalid converter input size"),
        (kAudioConverterErr_InvalidOutputSize, "invalid converter output size"),
        (kAudioConverterErr_RequiresPacketDescriptionsError, "packet descriptions required"),
        (kAudioConverterErr_InputSampleRateOutOfRange, "input sample rate out of range"),
        (kAudioConverterErr_OutputSampleRateOutOfRange, "output sample rate out of range"),
        (kExtAudioFileError_InvalidDataFormat, "invalid data format for this file"),
        (kExtAudioFileError_NonPCMClientFormat, "the client format must be PCM"),
        (OSStatus(-50), "invalid parameter"),
        (OSStatus(-43), "file not found"),
        (OSStatus(-54), "file permission denied (sandbox?)"),
    ]
}

/// A failed CoreAudio call, with the operation that failed and its decoded status.
struct CoreAudioError: LocalizedError, Equatable {
    var operation: String
    var status: OSStatus

    var errorDescription: String? { "\(operation) failed with \(AudioStatus.describe(status))." }
}

extension Error {
    /// A user-facing message that always includes the decoded four-char code when the error carries an `OSStatus`.
    ///
    /// AVFAudio wraps CoreAudio failures in `NSError`s such as
    /// `com.apple.coreaudio.avfaudio error 1718449215`; this turns that into `'fmt?' (1718449215): unsupported data format`.
    var audioCapDescription: String {
        if let error = self as? CoreAudioError { return error.errorDescription ?? "\(error)" }
        let nsError = self as NSError
        if nsError.domain == NSOSStatusErrorDomain || nsError.domain.hasPrefix("com.apple.coreaudio") {
            return "\(nsError.domain) error \(AudioStatus.describe(OSStatus(truncatingIfNeeded: nsError.code)))."
        }
        if let error = self as? LocalizedError, let description = error.errorDescription { return description }
        return nsError.localizedDescription
    }
}

/// Throws a `CoreAudioError` when `status` is not `noErr`.
func checkStatus(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(operation: operation(), status: status) }
}
