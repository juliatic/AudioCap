import Foundation

/// Where a take came from. Stored in the library and localized when shown, so "All system audio" follows the
/// current language. App names are kept as macOS reported them.
enum TakeSource: Codable, Hashable, Sendable {
    case app(name: String)
    case allSystemAudio

    /// Reads the free-text source name of an index written before sources were stored as codes.
    init(legacyName: String) {
        self = ["All system audio", "Todo el audio del sistema"].contains(legacyName) ? .allSystemAudio : .app(name: legacyName)
    }

    func displayName(bundle: Bundle = .main) -> String {
        switch self {
        case .app(let name): name
        case .allSystemAudio: String(localized: "All system audio", bundle: bundle)
        }
    }
}

/// A problem worth showing on a saved take. Stored as a code with its numbers and localized when shown.
enum TakeWarning: Codable, Hashable, Sendable {
    /// Every sample is 0.
    case allZero
    /// The writer fell behind the capture ring.
    case droppedFrames(frames: Int)
    case reconnected(count: Int)
    case timelineJumps(count: Int, skippedFrames: Int)
    /// CoreAudio delivered digital zeros mid-signal while the source was playing.
    case dropouts(count: Int, frames: Int, seconds: Double)
    /// The first sound arrived during or right after an idle tap refresh; `seconds` bounds how late the take starts.
    case startMayBeLate(seconds: Double)
    /// More than half of the take after its first sound is digital zero while the source was playing.
    case mostlyZero(zeroSeconds: Double, spanSeconds: Double)
    /// A short sound, then digital zeros while the source was playing, most of them trimmed by auto-record.
    case shortSoundThenTrimmedZeros(soundSeconds: Double, zeroSeconds: Double)
    /// The take's first sound starts mid-waveform right after exact zeros while the source was playing.
    case abruptStart(atSeconds: Double)
    /// The take's sound stops mid-waveform into exact zeros while the source kept playing.
    case abruptEnd(atSeconds: Double)
    /// This take starts abruptly after the previous one ended abruptly, with the source playing in between.
    case splitFromPrevious(gapSeconds: Double)
    /// The next take starts abruptly after this one ended abruptly, with the source playing in between.
    case splitIntoNext(gapSeconds: Double)
    /// Free text from an index written before warnings were codes, when it matches no known warning.
    case legacyText(text: String)

    func text(source: TakeSource, bundle: Bundle = .main) -> String {
        switch self {
        case .allZero:
            let sourceName = source.displayName(bundle: bundle)
            return String(localized: "Every sample in this take is 0 (digital silence). If \(sourceName) was playing, check that AudioCap is allowed in System Settings › Privacy & Security › Screen & System Audio Recording.", bundle: bundle)
        case .droppedFrames(let frames):
            return String(localized: "\(frames) frames were dropped because the writer fell behind.", bundle: bundle)
        case .reconnected(let count):
            return String(localized: "The capture was reconnected \(count) time(s) (output device change, source relaunch or wake); audio played during a reconnect is not in the take.", bundle: bundle)
        case .timelineJumps(let count, let skippedFrames):
            let bound = CapturePipeline.jumpLossBound * skippedFrames
            return String(localized: "The audio device's timeline jumped \(count) time(s) (\(skippedFrames) frames not delivered by CoreAudio).", bundle: bundle)
                + " " + String(localized: "Around each jump the source's audio usually skips about as much again, so up to \(bound) frames may be missing.", bundle: bundle)
        case .dropouts(let count, let frames, let seconds):
            let sourceName = source.displayName(bundle: bundle)
            let secondsText = seconds.formatted(.number.precision(.fractionLength(3)))
            return String(localized: "CoreAudio delivered digital zeros instead of \(sourceName)'s audio \(count) time(s) while it was playing (\(frames) frames, \(secondsText) s); that audio is missing from the take.", bundle: bundle)
        case .startMayBeLate(let seconds):
            let secondsText = seconds.formatted(.number.precision(.fractionLength(3)))
            return String(localized: "The take may start up to \(secondsText) s late: its first sound arrived during or right after an idle tap refresh, and audio played during the refresh is not in the take.", bundle: bundle)
        case .mostlyZero(let zeroSeconds, let spanSeconds):
            let sourceName = source.displayName(bundle: bundle)
            let zeroText = zeroSeconds.formatted(.number.precision(.fractionLength(3)))
            let spanText = spanSeconds.formatted(.number.precision(.fractionLength(3)))
            return String(localized: "Most of this take after its first sound is digital zero (\(zeroText) s of \(spanText) s) while \(sourceName) was playing. Unless that passage was really silent, CoreAudio delivered zeros instead of its audio and that audio is missing from the take.", bundle: bundle)
        case .shortSoundThenTrimmedZeros(let soundSeconds, let zeroSeconds):
            let sourceName = source.displayName(bundle: bundle)
            let soundText = soundSeconds.formatted(.number.precision(.fractionLength(3)))
            let zeroText = zeroSeconds.formatted(.number.precision(.fractionLength(3)))
            return String(localized: "This take kept only \(soundText) s of sound, followed by \(zeroText) s of digital zeros while \(sourceName) was playing; auto-record ended the take and trimmed those zeros. Unless the sound really stopped there, CoreAudio delivered zeros instead of its audio and the rest is missing.", bundle: bundle)
        case .abruptStart(let atSeconds):
            let sourceName = source.displayName(bundle: bundle)
            let atText = atSeconds.formatted(.number.precision(.fractionLength(3)))
            return String(localized: "Audio started abruptly mid-waveform at \(atText) s while \(sourceName) was playing; the start may be missing.", bundle: bundle)
        case .abruptEnd(let atSeconds):
            let sourceName = source.displayName(bundle: bundle)
            let atText = atSeconds.formatted(.number.precision(.fractionLength(3)))
            return String(localized: "Audio stopped abruptly at \(atText) s while \(sourceName) was playing; the rest may be missing.", bundle: bundle)
        case .splitFromPrevious(let gapSeconds):
            let sourceName = source.displayName(bundle: bundle)
            let gapText = gapSeconds.formatted(.number.precision(.fractionLength(3)))
            return String(localized: "This take and the previous one may be one passage split by a CoreAudio dropout; \(gapText) s between them (digital zeros while \(sourceName) was playing) are not in either take.", bundle: bundle)
        case .splitIntoNext(let gapSeconds):
            let sourceName = source.displayName(bundle: bundle)
            let gapText = gapSeconds.formatted(.number.precision(.fractionLength(3)))
            return String(localized: "This take and the next one may be one passage split by a CoreAudio dropout; \(gapText) s between them (digital zeros while \(sourceName) was playing) are not in either take.", bundle: bundle)
        case .legacyText(let text):
            return text
        }
    }

    static func text(_ warnings: [TakeWarning], source: TakeSource, bundle: Bundle = .main) -> String? {
        warnings.isEmpty ? nil : warnings.map { $0.text(source: source, bundle: bundle) }.joined(separator: " ")
    }

    /// Maps the English sentences older builds stored (several joined by spaces) to codes. Text that matches
    /// none of them is kept as `legacyText`.
    static func parseLegacy(_ text: String) -> [TakeWarning] {
        let string = text as NSString
        var found: [(range: NSRange, warning: TakeWarning)] = []
        for (regex, make) in legacyPatterns {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: string.length)) {
                let numbers = (1..<match.numberOfRanges).map { Int(string.substring(with: match.range(at: $0)).filter(\.isASCII).filter(\.isNumber)) ?? 0 }
                found.append((match.range, make(numbers)))
            }
        }
        found.sort { $0.range.location < $1.range.location }
        var warnings: [TakeWarning] = []
        var rest = ""
        var cursor = 0
        for (range, warning) in found where range.location >= cursor {
            rest += string.substring(with: NSRange(location: cursor, length: range.location - cursor)) + " "
            warnings.append(warning)
            cursor = NSMaxRange(range)
        }
        rest += string.substring(from: cursor)
        let leftover = rest.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !leftover.isEmpty { warnings.append(.legacyText(text: leftover)) }
        return warnings
    }

    private static let legacyPatterns: [(NSRegularExpression, ([Int]) -> TakeWarning)] = {
        let number = #"(\d(?:[\d,.\s]*\d)?)"#
        let patterns: [(String, ([Int]) -> TakeWarning)] = [
            (#"Every sample in this take is 0 \(digital silence\)\.(?:.*?Screen & System Audio Recording\.)?"#, { _ in .allZero }),
            (number + #" frames were dropped because the writer fell behind\."#, { .droppedFrames(frames: $0[0]) }),
            (#"The capture was reconnected "# + number + #" time\(s\)(?: \([^)]*\))?; audio played during a reconnect is not in the take\."#,
             { .reconnected(count: $0[0]) }),
            (#"The audio device['’]s timeline jumped "# + number + #" time\(s\) \("# + number + #" frames not delivered by CoreAudio\)\."#,
             { .timelineJumps(count: $0[0], skippedFrames: $0[1]) }),
        ]
        return patterns.map { (try! NSRegularExpression(pattern: $0.0, options: [.dotMatchesLineSeparators]), $0.1) }
    }()
}
