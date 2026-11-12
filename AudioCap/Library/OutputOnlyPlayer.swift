import AVFoundation
import AudioToolbox

/// Plays a file on the default output device without opening the device's input side.
///
/// Uses an `AVAudioEngine` whose output unit has input I/O switched off and never touches `inputNode`. On its own
/// this does not stop the microphone prompt: opening any HAL output unit on a device that also has inputs
/// (BlackHole, for example) asks for the microphone when the app holds `com.apple.security.device.audio-input`,
/// so the app doesn't hold that entitlement. The engine (and with it the HAL unit) is only created on the first Play.
@MainActor
final class OutputOnlyPlayer {
    private var engine: AVAudioEngine?
    private let node = AVAudioPlayerNode()
    private let file: AVAudioFile
    private let sampleRate: Double
    private let length: AVAudioFramePosition
    /// File frame the current schedule starts at.
    private var startFrame: AVAudioFramePosition = 0
    /// Bumped on every schedule so the completion of a stopped schedule is ignored.
    private var generation = 0

    let duration: TimeInterval
    private(set) var isPlaying = false

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        sampleRate = file.processingFormat.sampleRate
        length = file.length
        duration = Double(length) / sampleRate
    }

    /// Whether the output device has been opened; only after the first Play.
    var hasEngine: Bool { engine != nil }

    private func runningEngine() throws -> AVAudioEngine {
        let engine: AVAudioEngine
        if let existing = self.engine {
            engine = existing
        } else {
            engine = AVAudioEngine()
            try Self.disableInput(on: engine.outputNode)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            self.engine = engine
        }
        if !engine.isRunning { try engine.start() }
        return engine
    }

    var currentTime: TimeInterval {
        get {
            guard isPlaying,
                  let renderTime = node.lastRenderTime,
                  let playerTime = node.playerTime(forNodeTime: renderTime) else {
                return Double(startFrame) / sampleRate
            }
            let frame = min(length, startFrame + max(0, playerTime.sampleTime))
            return Double(frame) / sampleRate
        }
        set {
            let wasPlaying = isPlaying
            if wasPlaying { stopNode() }
            startFrame = min(length, max(0, AVAudioFramePosition(newValue * sampleRate)))
            if wasPlaying { try? play() }
        }
    }

    func play() throws {
        guard !isPlaying else { return }
        if startFrame >= length - AVAudioFramePosition(sampleRate / 100) { startFrame = 0 }
        _ = try runningEngine()
        generation += 1
        let scheduled = generation
        node.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(length - startFrame),
                             at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.finished(scheduled) }
        }
        node.play()
        isPlaying = true
    }

    func pause() {
        guard isPlaying else { return }
        startFrame = AVAudioFramePosition(currentTime * sampleRate)
        stopNode()
        engine?.pause()
    }

    func stop() {
        stopNode()
        engine?.stop()
    }

    /// Called by the refresh timer; the engine stops on its own when the output device changes.
    func checkEngine() {
        if isPlaying && engine?.isRunning != true { pause() }
    }

    private func stopNode() {
        generation += 1
        node.stop()
        isPlaying = false
    }

    private func finished(_ scheduled: Int) {
        guard scheduled == generation else { return }
        isPlaying = false
        startFrame = length
        engine?.pause()
    }

    private static func disableInput(on output: AVAudioOutputNode) throws {
        guard let unit = output.audioUnit else { return }
        var off: UInt32 = 0
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                          &off, UInt32(MemoryLayout<UInt32>.size))
        try checkStatus(status, "Disabling the output unit's input")
    }
}
