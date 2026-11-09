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
            return String(localized: "The audio device's timeline jumped \(count) time(s) (\(skippedFrames) frames not delivered by CoreAudio).", bundle: bundle)
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
