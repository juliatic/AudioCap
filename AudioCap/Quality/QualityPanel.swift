import SwiftUI
import AudioToolbox

enum QualityPathBuilder {
    /// Reads the current path of `tap` and lets registered contributors add their part.
    @MainActor
    static func build(tap: ProcessTap, recorder: ProcessTapRecorder, format: RecordingSettings.OutputFormat) -> QualityPath {
        var path = QualityPath(sourceName: tap.process.name)
        if let asbd = tap.tapStreamDescription, asbd.mSampleRate > 0 {
            path.tap = .init(sampleRate: asbd.mSampleRate, channelCount: Int(asbd.mChannelsPerFrame))
        }
        let deviceID = tap.aggregateOutputDevice?.id ?? (try? AudioDeviceID.readDefaultOutputDevice())
        if let deviceID, deviceID != .unknown {
            path.clock = .init(name: deviceID.readName() ?? "?",
                               uid: (try? deviceID.readDeviceUID()) ?? "",
                               nominalSampleRate: try? deviceID.readNominalSampleRate(),
                               outputChannelCount: deviceID.readOutputChannelCount())
        }
        if recorder.status != .idle, let capture = recorder.captureFormat ?? tap.captureFormat {
            path.capture = .init(sampleRate: capture.sampleRate, channelCount: capture.channelCount)
        }
        if let rate = path.captureRate, let channels = path.captureChannels {
            path.file = .init(format: format, sampleRate: format == .aac ? min(rate, AudioExporter.maxAACSampleRate) : rate,
                              channelCount: channels)
        }
        QualityPathContributors.apply(to: &path)
        return path
    }
}

/// Shows the tap, device and file formats with a bit-perfect badge or the reasons it isn't.
struct QualityPanel: View {
    let tap: ProcessTap
    let recorder: ProcessTapRecorder
    private let matcher = DeviceRateMatcher.shared
    private let settings = RecordingSettings.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let path = QualityPathBuilder.build(tap: tap, recorder: recorder, format: settings.outputFormat)
            content(path: path, assessment: QualityAssessment.assess(path))
        }
        .onChange(of: recorder.status) { old, new in
            if old != .idle, new == .idle { matcher.restore() }
        }
    }

    @ViewBuilder
    private func content(path: QualityPath, assessment: QualityAssessment) -> some View {
        Section {
            if assessment.isBitPerfect {
                Label("Bit-perfect path", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(AppStyle.headline)
            } else {
                ForEach(assessment.issues, id: \.self) { issue in
                    Label(Self.text(for: issue), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
            }

            LabeledContent("Tap") { Text(Self.streamText(path.tap)) }
            LabeledContent("Output device") {
                Text(path.clock.map { device in
                    [device.name, device.nominalSampleRate.map(CaptureFormat.rateString),
                     device.outputChannelCount.map { String(localized: "\(String($0)) ch") }]
                        .compactMap { $0 }.joined(separator: " · ")
                } ?? "—")
            }
            if let capture = path.capture {
                LabeledContent("Capture") { Text(Self.streamText(capture)) }
            }
            LabeledContent("File") {
                Text(path.file.map { file in
                    "\(Self.formatName(file.format)) · \(Self.streamText(.init(sampleRate: file.sampleRate, channelCount: file.channelCount))) · \(Self.bitDepth(file.format))"
                } ?? "—")
            }

            ForEach(assessment.notes, id: \.self) { note in
                Text(Self.text(for: note)).secondaryTextStyle()
            }

            rateMatchControls(path: path)
        } header: {
            Text("Quality")
        }
    }

    @ViewBuilder
    private func rateMatchControls(path: QualityPath) -> some View {
        if let device = path.clock, let id = AudioDeviceID.device(withUID: device.uid) {
            let rates = id.readAvailableNominalSampleRates()
            let isRecording = recorder.status != .idle
            HStack {
                Menu("Match output device rate") {
                    ForEach(rates, id: \.self) { rate in
                        Button(CaptureFormat.rateString(rate)) {
                            matcher.match(deviceUID: device.uid, deviceName: device.name,
                                          currentRate: device.nominalSampleRate ?? rate, to: rate)
                        }
                        .disabled(rate == device.nominalSampleRate)
                    }
                }
                .fixedSize()
                .disabled(isRecording || rates.count < 2)
                .help(Text("Set the output device to the source's rate before recording, so nothing is resampled. The previous rate comes back when recording stops."))

                if let change = matcher.activeChange {
                    Button("Restore \(CaptureFormat.rateString(change.originalRate))") { matcher.restore() }
                        .disabled(isRecording)
                }
            }
            if let change = matcher.activeChange {
                Text("\(change.deviceName) is set to \(CaptureFormat.rateString(change.newRate)). It goes back to \(CaptureFormat.rateString(change.originalRate)) when recording stops.")
                    .secondaryTextStyle()
            }
            if let error = matcher.lastError {
                Text(error).errorTextStyle()
            }
        }
    }

    static func streamText(_ stream: QualityPath.Stream?) -> String {
        guard let stream else { return "—" }
        return "\(CaptureFormat.rateString(stream.sampleRate)) · \(String(localized: "\(String(stream.channelCount)) ch"))"
    }

    static func formatName(_ format: RecordingSettings.OutputFormat) -> String {
        switch format {
        case .wav: "WAV"
        case .flac: "FLAC"
        case .alac: "ALAC"
        case .aac: "AAC"
        }
    }

    static func bitDepth(_ format: RecordingSettings.OutputFormat) -> String {
        switch format {
        case .wav: String(localized: "32-bit float")
        case .flac, .alac: String(localized: "24-bit")
        case .aac: String(localized: "256 kbps")
        }
    }

    static func text(for issue: QualityIssue) -> String {
        switch issue {
        case .resampled(let from?, let to):
            String(localized: "Resampled from \(CaptureFormat.rateString(from)) to \(CaptureFormat.rateString(to))")
        case .resampled(nil, let to):
            String(localized: "Resampled to \(CaptureFormat.rateString(to))")
        case .downmixed(let from, let to):
            to == 2 ? String(localized: "Downmixed from \(String(from)) channels to stereo")
                    : String(localized: "Downmixed from \(String(from)) to \(String(to)) channels")
        case .possibleDownmix(let device, _):
            String(localized: "The output device has \(String(device)) channels: multichannel audio may be downmixed to stereo")
        case .exportResampled(let to):
            String(localized: "The file is resampled to \(CaptureFormat.rateString(to)) (AAC limit)")
        case .lossyFile:
            String(localized: "AAC is lossy: choose WAV, FLAC or ALAC to keep every sample")
        }
    }

    static func text(for note: QualityNote) -> String {
        switch note {
        case .predicted:
            String(localized: "Expected formats; they are confirmed when recording starts.")
        case .sourceRateUnknown(let rate):
            String(localized: "The source doesn't report its own rate. If the track isn't \(CaptureFormat.rateString(rate)), it is resampled before the tap: use Match output device rate.")
        case .appProcessing:
            String(localized: "The source app's volume, EQ, Sound Check and Spatial Audio change the samples before AudioCap gets them.")
        case .integerFile(let bits):
            String(localized: "Lossless at \(String(bits)) bits; choose WAV to keep the 32-bit float capture unchanged.")
        case .hiResDevice:
            String(localized: "Recording through the AudioCap Hi-Res device, so the output hardware doesn't limit the rate.")
        case .monitor(let name, let rate?):
            String(localized: "Monitoring on \(name) at \(CaptureFormat.rateString(rate)); this only affects what you hear, not the file.")
        case .monitor(let name, nil):
            String(localized: "Monitoring on \(name); this only affects what you hear, not the file.")
        case .custom(let text):
            text
        }
    }
}
