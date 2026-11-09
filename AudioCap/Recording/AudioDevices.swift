import Foundation
import AudioToolbox
import CoreAudio

extension AudioObjectID {
    /// Reads `kAudioHardwarePropertyDefaultOutputDevice` (the device apps play to). System object only.
    static func readDefaultOutputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, defaultValue: AudioDeviceID.unknown)
    }

    /// `kAudioObjectPropertyName`.
    func readName() -> String? { try? readString(kAudioObjectPropertyName) }

    /// `kAudioDevicePropertyNominalSampleRate`.
    func readNominalSampleRate() throws -> Double {
        try read(kAudioDevicePropertyNominalSampleRate, defaultValue: Float64(0))
    }

    /// `kAudioProcessPropertyPID`.
    func readProcessPID() -> pid_t? {
        (try? read(kAudioProcessPropertyPID, defaultValue: pid_t(-1))).flatMap { $0 > 0 ? $0 : nil }
    }

    /// The stream objects of a device in `scope`.
    func readStreams(scope: AudioObjectPropertyScope) throws -> [AudioStreamID] {
        try readArray(AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain))
    }

    /// `kAudioStreamPropertyVirtualFormat` of a stream object: the format delivered to the IOProc.
    func readStreamVirtualFormat() throws -> AudioStreamBasicDescription {
        try read(kAudioStreamPropertyVirtualFormat, defaultValue: AudioStreamBasicDescription())
    }

    func readArray<T>(_ address: AudioObjectPropertyAddress) throws -> [T] {
        var address = address
        var size: UInt32 = 0
        try checkStatus(AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size), "Reading the data size of \(address.description)")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        try checkStatus(AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer), "Reading \(address.description)")
        let typed = pointer.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: Int(size) / MemoryLayout<T>.stride))
    }
}

/// Name, UID and nominal rate of an output device, for diagnostics.
struct OutputDeviceInfo: Equatable, Sendable, CustomStringConvertible {
    var id: AudioDeviceID
    var name: String
    var uid: String
    var nominalSampleRate: Double?

    init(id: AudioDeviceID) throws {
        self.id = id
        self.uid = try id.readDeviceUID()
        self.name = id.readName() ?? "?"
        self.nominalSampleRate = try? id.readNominalSampleRate()
    }

    static func currentDefault() throws -> OutputDeviceInfo {
        try OutputDeviceInfo(id: AudioObjectID.readDefaultOutputDevice())
    }

    var description: String {
        "\(name) (UID \(uid), nominal rate \(nominalSampleRate.map { "\($0) Hz" } ?? "unknown"))"
    }
}

/// Registers a CoreAudio property listener block on the main queue and removes it on `cancel()`/deinit.
final class AudioPropertyListener {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private var isActive = false

    init(objectID: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, handler: @escaping () -> Void) throws {
        self.objectID = objectID
        self.address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        self.block = { _, _ in handler() }
        try checkStatus(AudioObjectAddPropertyListenerBlock(objectID, &address, .main, block), "Adding a listener for \(address.description)")
        isActive = true
    }

    func cancel() {
        guard isActive else { return }
        isActive = false
        AudioObjectRemovePropertyListenerBlock(objectID, &address, .main, block)
    }

    deinit { cancel() }
}
