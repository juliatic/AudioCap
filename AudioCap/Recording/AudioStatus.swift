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

    /// Meanings are localised; the four-char code and number stay as they are, so reports stay searchable.
    private static let knownCodeList: [(OSStatus, String)] = [
        (kAudioHardwareNotRunningError, String(localized: "the audio hardware is not running")),
        (kAudioHardwareUnspecifiedError, String(localized: "unspecified audio hardware error")),
        (kAudioHardwareUnknownPropertyError, String(localized: "unknown property")),
        (kAudioHardwareBadPropertySizeError, String(localized: "bad property size")),
        (kAudioHardwareIllegalOperationError, String(localized: "illegal operation")),
        (kAudioHardwareBadObjectError, String(localized: "the audio object no longer exists")),
        (kAudioHardwareBadDeviceError, String(localized: "the audio device no longer exists")),
        (kAudioHardwareBadStreamError, String(localized: "the audio stream no longer exists")),
        (kAudioHardwareUnsupportedOperationError, String(localized: "unsupported operation")),
        (kAudioHardwareNotReadyError, String(localized: "the audio device is not ready")),
        (kAudioDeviceUnsupportedFormatError, String(localized: "the device does not support this format")),
        (kAudioDevicePermissionsError, String(localized: "permission denied (check the audio recording permission)")),
        (kAudioFormatUnsupportedDataFormatError, String(localized: "unsupported data format")),
        (kAudioFormatUnsupportedPropertyError, String(localized: "unsupported format property")),
        (kAudioFormatBadPropertySizeError, String(localized: "bad format property size")),
        (kAudioFormatUnknownFormatError, String(localized: "unknown audio format")),
        (kAudioFileUnsupportedDataFormatError, String(localized: "the file type does not support this data format")),
        (kAudioFileUnsupportedFileTypeError, String(localized: "unsupported file type")),
        (kAudioFileInvalidFileError, String(localized: "the file is malformed or damaged")),
        (kAudioFilePermissionsError, String(localized: "no permission to write the file")),
        (kAudioFileNotOptimizedError, String(localized: "the file is not optimized")),
        (kAudioConverterErr_FormatNotSupported, String(localized: "the converter does not support this format")),
        (kAudioConverterErr_InvalidInputSize, String(localized: "invalid converter input size")),
        (kAudioConverterErr_InvalidOutputSize, String(localized: "invalid converter output size")),
        (kAudioConverterErr_RequiresPacketDescriptionsError, String(localized: "packet descriptions required")),
        (kAudioConverterErr_InputSampleRateOutOfRange, String(localized: "input sample rate out of range")),
        (kAudioConverterErr_OutputSampleRateOutOfRange, String(localized: "output sample rate out of range")),
        (kExtAudioFileError_InvalidDataFormat, String(localized: "invalid data format for this file")),
        (kExtAudioFileError_NonPCMClientFormat, String(localized: "the client format must be PCM")),
        (OSStatus(-50), String(localized: "invalid parameter")),
        (OSStatus(-43), String(localized: "file not found")),
        (OSStatus(-54), String(localized: "file permission denied (sandbox?)")),
    ]
}

/// A failed CoreAudio call, with the operation that failed and its decoded status.
struct CoreAudioError: LocalizedError, Equatable {
    var operation: String
    var status: OSStatus

    var errorDescription: String? { String(localized: "\(operation) failed with \(AudioStatus.describe(status)).") }
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
            return String(localized: "\(nsError.domain) error \(AudioStatus.describe(OSStatus(truncatingIfNeeded: nsError.code))).")
        }
        if let error = self as? LocalizedError, let description = error.errorDescription { return description }
        return nsError.localizedDescription
    }
}

/// Throws a `CoreAudioError` when `status` is not `noErr`.
///
/// `operation` is localised, so pass a literal such as `"Creating the process tap"` (interpolate `.description` for
/// CoreAudio structs).
func checkStatus(_ status: OSStatus, _ operation: @autoclosure () -> String.LocalizationValue) throws {
    guard status == noErr else { throw CoreAudioError(operation: String(localized: operation()), status: status) }
}
