import Foundation
import AudioToolbox
import CoreAudio

/// Identity of the `AudioCap Hi-Res` virtual output device (the `AudioCapHiRes` driver target).
enum HiResDevice {
    /// `kDevice_UID` in `AudioCapHiRes/AudioCapHiRes.c`.
    static let uid = "AudioCapHiRes_UID"
    static let name = "AudioCap Hi-Res"
    static let driverBundleName = "AudioCapHiRes.driver"
    static let installPath = "/Library/Audio/Plug-Ins/HAL/AudioCapHiRes.driver"
    /// Nominal rates the driver advertises, in Hz.
    static let supportedRates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]

    static func isSupported(_ rate: Double) -> Bool { supportedRates.contains(rate) }

    static func rateString(_ rate: Double) -> String {
        let kHz = rate / 1000
        return kHz.rounded() == kHz ? String(format: "%.0f kHz", kHz) : String(format: "%.1f kHz", kHz)
    }
}

/// An output device as seen by the Hi-Res router.
struct AudioOutputDevice: Equatable, Codable, Sendable {
    var uid: String
    var name: String
    var nominalSampleRate: Double?
}

/// The parts of the CoreAudio system the router uses. A protocol so the state machine is unit-testable.
protocol AudioOutputSystem: AnyObject {
    func defaultOutputUID() -> String?
    func setDefaultOutput(uid: String) throws
    func device(uid: String) -> AudioOutputDevice?
    /// Output-capable devices other than `excludedUID`, in CoreAudio order.
    func outputDevices(excluding excludedUID: String) -> [AudioOutputDevice]
    func setNominalSampleRate(_ rate: Double, uid: String) throws
}

/// `AudioOutputSystem` backed by the HAL.
final class CoreAudioOutputSystem: AudioOutputSystem {
    func defaultOutputUID() -> String? {
        guard let id = try? AudioObjectID.readDefaultOutputDevice(), id.isValid else { return nil }
        return try? id.readDeviceUID()
    }

    func setDefaultOutput(uid: String) throws {
        let id = try deviceID(uid: uid)
        var value = id
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try checkStatus(AudioObjectSetPropertyData(AudioObjectID.system, &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value), "Setting the default output to \(uid)")
    }

    func device(uid: String) -> AudioOutputDevice? {
        guard let id = try? deviceID(uid: uid) else { return nil }
        return AudioOutputDevice(uid: uid, name: id.readName() ?? uid, nominalSampleRate: try? id.readNominalSampleRate())
    }

    func outputDevices(excluding excludedUID: String) -> [AudioOutputDevice] {
        let address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let ids: [AudioDeviceID] = (try? AudioObjectID.system.readArray(address)) ?? []
        return ids.compactMap { id in
            guard let uid = try? id.readDeviceUID(), uid != excludedUID,
                  let streams = try? id.readStreams(scope: kAudioObjectPropertyScopeOutput), !streams.isEmpty,
                  id.readName()?.hasPrefix("Tap-") != true else { return nil }
            return AudioOutputDevice(uid: uid, name: id.readName() ?? uid, nominalSampleRate: try? id.readNominalSampleRate())
        }
    }

    /// Sets the nominal rate and waits (bounded, 2 s) until the device reports it: the driver applies it asynchronously.
    func setNominalSampleRate(_ rate: Double, uid: String) throws {
        let id = try deviceID(uid: uid)
        if (try? id.readNominalSampleRate()) == rate { return }
        var value = Float64(rate)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try checkStatus(AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value), "Setting \(uid) to \(rate) Hz")
        for _ in 0..<40 {
            if (try? id.readNominalSampleRate()) == rate { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw "\(HiResDevice.name) did not switch to \(HiResDevice.rateString(rate))."
    }

    func deviceID(uid: String) throws -> AudioDeviceID {
        let id = try AudioObjectID.system.read(kAudioHardwarePropertyTranslateUIDToDevice, defaultValue: AudioDeviceID.unknown, qualifier: uid as CFString)
        guard id.isValid else { throw "Audio device \(uid) is not available." }
        return id
    }
}
