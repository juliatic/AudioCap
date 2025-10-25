@preconcurrency import AVFoundation
import SwiftUI
import AudioToolbox
import OSLog
import UniformTypeIdentifiers

@Observable
final class ProcessTap {

    typealias InvalidationHandler = (ProcessTap) -> Void

    let process: AudioProcess
    let muteWhenRunning: Bool
    private let logger: Logger

    private(set) var errorMessage: String? = nil

    init(process: AudioProcess, muteWhenRunning: Bool = false) {
        self.process = process
        self.muteWhenRunning = muteWhenRunning
        self.logger = Logger(subsystem: kAppSubsystem, category: "\(String(describing: ProcessTap.self))(\(process.name))")
    }

    @ObservationIgnored
    private var processTapID: AudioObjectID = .unknown
    @ObservationIgnored
    private var aggregateDeviceID = AudioObjectID.unknown
    @ObservationIgnored
    private var deviceProcID: AudioDeviceIOProcID?
    @ObservationIgnored
    private(set) var tapStreamDescription: AudioStreamBasicDescription?
    @ObservationIgnored
    private var invalidationHandler: InvalidationHandler?

    @ObservationIgnored
    private(set) var activated = false

    @MainActor
    func activate() {
        guard !activated else { return }
        activated = true

        logger.debug(#function)

        self.errorMessage = nil

        do {
            try prepare(for: process.objectID)
        } catch {
            logger.error("\(error, privacy: .public)")
            self.errorMessage = error.localizedDescription
        }
    }

    func invalidate() {
        guard activated else { return }
        defer { activated = false }

        logger.debug(#function)

        invalidationHandler?(self)
        self.invalidationHandler = nil

        if aggregateDeviceID.isValid {
            var err = AudioDeviceStop(aggregateDeviceID, deviceProcID)
            if err != noErr { logger.warning("Failed to stop aggregate device: \(err, privacy: .public)") }

            if let deviceProcID {
                err = AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
                if err != noErr { logger.warning("Failed to destroy device I/O proc: \(err, privacy: .public)") }
                self.deviceProcID = nil
            }

            err = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if err != noErr {
                logger.warning("Failed to destroy aggregate device: \(err, privacy: .public)")
            }
            aggregateDeviceID = .unknown
        }

        if processTapID.isValid {
            let err = AudioHardwareDestroyProcessTap(processTapID)
            if err != noErr {
                logger.warning("Failed to destroy audio tap: \(err, privacy: .public)")
            }
            self.processTapID = .unknown
        }
    }

    private func prepare(for objectID: AudioObjectID) throws {
        errorMessage = nil

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [objectID])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = muteWhenRunning ? .mutedWhenTapped : .unmuted
        var tapID: AUAudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)

        guard err == noErr else {
            errorMessage = "Process tap creation failed with error \(err)"
            return
        }

        logger.debug("Created process tap #\(tapID, privacy: .public)")

        self.processTapID = tapID

        let systemOutputID = try AudioDeviceID.readDefaultSystemOutputDevice()

        let outputUID = try systemOutputID.readDeviceUID()

        let aggregateUID = UUID().uuidString

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tap-\(process.id)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                ]
            ]
        ]

        self.tapStreamDescription = try tapID.readAudioTapStreamBasicDescription()

        aggregateDeviceID = AudioObjectID.unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)
        guard err == noErr else {
            throw "Failed to create aggregate device: \(err)"
        }

        logger.debug("Created aggregate device #\(self.aggregateDeviceID, privacy: .public)")
    }

    func run(on queue: DispatchQueue, ioBlock: @escaping AudioDeviceIOBlock, invalidationHandler: @escaping InvalidationHandler) throws {
        assert(activated, "\(#function) called with inactive tap!")
        assert(self.invalidationHandler == nil, "\(#function) called with tap already active!")

        errorMessage = nil

        logger.debug("Run tap!")

        self.invalidationHandler = invalidationHandler

        var err = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, queue, ioBlock)
        guard err == noErr else { throw "Failed to create device I/O proc: \(err)" }

        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard err == noErr else { throw "Failed to start audio device: \(err)" }
    }

    deinit { invalidate() }

}

@Observable
final class ProcessTapRecorder {

    let fileURL: URL
    let process: AudioProcess
    private let queue = DispatchQueue(label: "ProcessTapRecorder", qos: .userInitiated)
    private let logger: Logger

    @ObservationIgnored
    private weak var _tap: ProcessTap?

    private(set) var isRecording = false
    var isConverting = false
    var lastConvertedURL: URL?
    @ObservationIgnored
    private var recordedWavURLs: [URL] = []

    init(fileURL: URL, tap: ProcessTap) {
        self.process = tap.process
        self.fileURL = fileURL
        self._tap = tap
        self.logger = Logger(subsystem: kAppSubsystem, category: "\(String(describing: ProcessTapRecorder.self))(\(fileURL.lastPathComponent))")
    }

    private var tap: ProcessTap {
        get throws {
            guard let _tap else { throw "Process tab unavailable" }
            return _tap
        }
    }

    @ObservationIgnored
    private var currentFile: AVAudioFile?
    @ObservationIgnored
    private var recordingFormat: AVAudioFormat?
    @ObservationIgnored
    private var silenceDetector = SilenceDetector(thresholdDb: RecordingSettings.shared.silenceThresholdDb, minSilenceDuration: RecordingSettings.shared.minSilenceDuration)
    @ObservationIgnored
    private let settings = RecordingSettings.shared
    @ObservationIgnored
    private var activeOutputFormat: RecordingSettings.OutputFormat = RecordingSettings.shared.outputFormat

    @MainActor
    func start() throws {
        logger.debug(#function)
        
        guard !isRecording else {
            logger.warning("\(#function, privacy: .public) while already recording")
            return
        }

        let tap = try tap

        if !tap.activated { tap.activate() }

        guard var streamDescription = tap.tapStreamDescription else {
            throw "Tap stream description not available."
        }

        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw "Failed to create AVAudioFormat."
        }

        logger.info("Using audio format: \(format, privacy: .public)")

        // Freeze output format and silence detector configuration at recording start
        self.activeOutputFormat = settings.outputFormat
        self.silenceDetector = SilenceDetector(thresholdDb: settings.silenceThresholdDb, minSilenceDuration: settings.minSilenceDuration)

        // Always record to WAV. If target is not WAV, we'll convert on stop.
        let wavURL: URL = {
            if activeOutputFormat == .wav { return fileURL }
            let base = fileURL.deletingPathExtension()
            return base.appendingPathExtension("wav")
        }()

        let settingsDict = wavFileSettings(for: format)
        let file = try AVAudioFile(forWriting: wavURL, settings: settingsDict, commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)

        self.currentFile = file
        self.recordingFormat = format
        self.recordedWavURLs = [wavURL]

        try tap.run(on: queue) { [weak self] inNumberFrames, inInputData, inInputTime, outOutputData, inOutputTime in
            guard let self else { return }
            guard let format = self.recordingFormat else { return }

            do {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else {
                    throw "Failed to create PCM buffer"
                }

                // If enabled, analyze buffer for silence and possibly rotate file
                if self.settings.autoSplitOnSilence {
                    let analysis = self.silenceDetector.process(buffer: buffer)
                    #if DEBUG
                    self.logger.debug("[Silence] rms=\(String(format: "%.1f", analysis.rmsDb)) dB, silent=\(analysis.isSilent), accum=\(String(format: "%.2f", analysis.silentDuration))s")
                    #endif

                    if analysis.didTriggerSplit {
                        self.currentFile = nil
                        do {
                            try self.rotateFile(using: format)
                            #if DEBUG
                            self.logger.info("Silence \(String(format: "%.2f", analysis.silentDuration))s reached. Split to new file.")
                            #endif
                        } catch {
                            self.logger.error("File rotation error: \(String(describing: error), privacy: .public)")
                        }
                        // Skip writing this silent buffer
                        return
                    }
                } else {
                    // Reset detector if disabled during recording
                    self.silenceDetector.reset()
                }

                guard let currentFile = self.currentFile else { return }
                try currentFile.write(from: buffer)
            } catch {
                logger.error("\(error, privacy: .public)")
            }
        } invalidationHandler: { [weak self] tap in
            guard let self else { return }
            handleInvalidation()
        }

        isRecording = true
    }

    func stop() {
        do {
            logger.debug(#function)

            guard isRecording else { return }

            currentFile = nil
            // Cancel any pending split and silence accumulation
            silenceDetector.reset()

            isRecording = false

            try tap.invalidate()

            // Offline conversion if needed
            if activeOutputFormat != .wav {
                isConverting = true
                let targetExt = activeOutputFormat == .m4a ? "m4a" : "flac"
                queue.async { [weak self] in
                    guard let self else { return }
                    var lastOut: URL?
                    for wav in self.recordedWavURLs {
                        let outURL = wav.deletingPathExtension().appendingPathExtension(targetExt)
                        do {
                            try self.convertWav(wavURL: wav, toURL: outURL, target: self.activeOutputFormat)
                            // Delete original wav after successful conversion
                            try? FileManager.default.removeItem(at: wav)
                            lastOut = outURL
                        } catch {
                            self.logger.error("Conversion failed: \(String(describing: error), privacy: .public)")
                        }
                    }
                    DispatchQueue.main.async {
                        self.lastConvertedURL = lastOut
                        self.isConverting = false
                    }
                }
            }
        } catch {
            logger.error("Stop failed: \(error, privacy: .public)")
        }
    }

    private func handleInvalidation() {
        guard isRecording else { return }

        logger.debug(#function)
    }

    private func rotateFile(using format: AVAudioFormat) throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let baseName = "\(process.name)-\(timestamp)"
        let newWavURL = URL.applicationSupport.appendingPathComponent(baseName, conformingTo: .wav)

        let settingsDict = wavFileSettings(for: format)
        let newFile = try AVAudioFile(forWriting: newWavURL, settings: settingsDict, commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
        self.currentFile = newFile
        self.recordedWavURLs.append(newWavURL)
    }

    private func wavFileSettings(for format: AVAudioFormat) -> [String: Any] {
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false
        ]
    }

    private func conversionSettings(for target: RecordingSettings.OutputFormat, sourceFormat: AVAudioFormat) -> [String: Any] {
        switch target {
        case .wav:
            return wavFileSettings(for: sourceFormat)
        case .m4a:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sourceFormat.sampleRate,
                AVNumberOfChannelsKey: min(2, sourceFormat.channelCount),
                AVEncoderBitRateKey: 192_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
        case .flac:
            return [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: sourceFormat.sampleRate,
                AVNumberOfChannelsKey: min(2, sourceFormat.channelCount)
            ]
        }
    }

    private func convertWav(wavURL: URL, toURL outURL: URL, target: RecordingSettings.OutputFormat) throws {
        let srcFile = try AVAudioFile(forReading: wavURL)
        let srcFormat = srcFile.processingFormat
        let settings = conversionSettings(for: target, sourceFormat: srcFormat)
        let dstFile = try AVAudioFile(forWriting: outURL, settings: settings)
        guard let converter = AVAudioConverter(from: srcFormat, to: dstFile.processingFormat) else {
            throw "Failed to initialize audio converter"
        }

        while true {
            let chunk: AVAudioFrameCount = 2048
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: chunk) else { break }
            try srcFile.read(into: inBuf)
            if inBuf.frameLength == 0 { break }

            guard let outBuf = AVAudioPCMBuffer(pcmFormat: dstFile.processingFormat, frameCapacity: inBuf.frameLength) else { throw "Alloc out buffer failed" }
            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
                outStatus.pointee = AVAudioConverterInputStatus.haveData
                return inBuf
            }
            if status == .error { throw error ?? "Audio conversion failed" }
            try dstFile.write(from: outBuf)
        }
    }
}
