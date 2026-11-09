import AVFoundation
import OSLog
import Synchronization

/// Single-producer/single-consumer ring of deinterleaved Float32 frames between the capture queue and the monitor's
/// render thread. The writer never blocks; when the reader falls too far behind (clock drift between the Hi-Res device
/// and the real output) it skips ahead, and when it runs dry it plays silence until it has refilled.
final class MonitorRingBuffer: @unchecked Sendable {
    let channelCount: Int
    let capacity: Int
    let targetLatency: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    /// Only touched by the reader.
    private var primed = false

    init(channelCount: Int, sampleRate: Double, latency: TimeInterval = 0.1) {
        self.channelCount = max(channelCount, 1)
        self.targetLatency = max(Int(sampleRate * latency), 256)
        self.capacity = targetLatency * 8
        storage = .allocate(capacity: self.channelCount * capacity)
        storage.initialize(repeating: 0, count: self.channelCount * capacity)
    }

    deinit { storage.deallocate() }

    var availableFrames: Int { writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring) }

    /// Producer side. `channels[c]` points to `frames` samples; missing channels repeat the last one.
    func write(channels: [UnsafePointer<Float>], frames: Int) {
        guard !channels.isEmpty, frames > 0 else { return }
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        guard capacity - (w - r) >= frames else { return }
        for c in 0..<channelCount {
            let src = channels[min(c, channels.count - 1)]
            let dst = storage + c * capacity
            for i in 0..<frames { dst[(w + i) % capacity] = src[i] }
        }
        writeIndex.store(w + frames, ordering: .releasing)
    }

    /// Consumer side (render thread): fills `frames` frames of every buffer in `output`.
    func read(into output: UnsafeMutableAudioBufferListPointer, frames: Int) {
        var r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        var available = w - r
        if available > targetLatency * 4 {
            r = w - targetLatency
            available = targetLatency
        }
        if !primed, available >= targetLatency { primed = true }
        let count = primed ? min(available, frames) : 0
        if primed, available < frames { primed = false }
        for (c, buffer) in output.enumerated() {
            guard let dst = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let src = storage + min(c, channelCount - 1) * capacity
            for i in 0..<count { dst[i] = src[(r + i) % capacity] }
            if count < frames { (dst + count).update(repeating: 0, count: frames - count) }
        }
        readIndex.store(r + count, ordering: .releasing)
    }
}

/// Plays the tapped audio on a real output device (Bluetooth, display or built-in speakers) while the Hi-Res device is
/// the system output. Only this copy is resampled, by AVAudioEngine, to the device's rate; the recording is untouched.
final class AudioMonitor {
    private let logger = Logger(subsystem: kAppSubsystem, category: "AudioMonitor")
    private var engine: AVAudioEngine?
    private let ring = Mutex<MonitorRingBuffer?>(nil)
    private(set) var format: CaptureFormat?
    private(set) var device: AudioOutputDevice?

    var volume: Float = 1 { didSet { applyVolume() } }
    var isMuted = false { didSet { applyVolume() } }

    var isRunning: Bool { engine?.isRunning == true }

    /// (Re)starts the monitor for `format` on `device`.
    func start(format: CaptureFormat, device: AudioOutputDevice, deviceID: AudioDeviceID) throws {
        stop()
        let buffer = MonitorRingBuffer(channelCount: format.channelCount, sampleRate: format.sampleRate)
        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: AVAudioChannelCount(buffer.channelCount), interleaved: false) else {
            throw "The monitor cannot use \(format.description)."
        }
        let engine = AVAudioEngine()
        try engine.outputNode.auAudioUnit.setDeviceID(deviceID)
        let source = AVAudioSourceNode(format: sourceFormat) { _, _, frameCount, audioBufferList in
            buffer.read(into: UnsafeMutableAudioBufferListPointer(audioBufferList), frames: Int(frameCount))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: sourceFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.format = format
        self.device = device
        ring.withLock { $0 = buffer }
        applyVolume()
        logger.info("Monitoring \(format.description, privacy: .public) on \(device.name, privacy: .public)")
    }

    func stop() {
        ring.withLock { $0 = nil }
        engine?.stop()
        engine = nil
        format = nil
        device = nil
    }

    /// Output rate of the monitor device, for the quality line.
    var outputSampleRate: Double? {
        guard let engine else { return nil }
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        return rate > 0 ? rate : nil
    }

    /// Capture queue: copies a deinterleaved Float32 buffer into the ring.
    func push(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let channels = (0..<Int(buffer.format.channelCount)).map { UnsafePointer(data[$0]) }
        ring.withLock { $0?.write(channels: channels, frames: Int(buffer.frameLength)) }
    }

    private func applyVolume() {
        engine?.mainMixerNode.outputVolume = isMuted ? 0 : volume
    }
}
