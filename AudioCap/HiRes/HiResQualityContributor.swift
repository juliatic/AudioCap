import Foundation

/// Tells the Quality panel when the capture is clocked by the AudioCap Hi-Res device and where the monitor plays.
final class HiResQualityContributor: QualityPathContributor {
    static let shared = HiResQualityContributor()

    func contribute(to path: inout QualityPath) {
        let current = path
        path = MainActor.assumeIsolated { HiResController.shared.qualityPath(from: current) }
    }
}

extension HiResController {
    func qualityPath(from path: QualityPath) -> QualityPath {
        guard isRouted else { return nextTakePath(from: path) }
        var path = path
        path.clock?.isVirtualHiRes = true
        if let device = monitorDevice {
            path.monitor = .init(deviceName: device.name, sampleRate: monitorOutputRate)
        }
        return path
    }

    /// While idle (before the first take or after Stop) the physical output is the default device again, but the next
    /// take will be routed to the Hi-Res device and the source will render at its rate: predict that path instead.
    func nextTakePath(from path: QualityPath) -> QualityPath {
        guard path.capture == nil, let next = nextTake(sourceBundleID: path.sourceBundleID) else { return path }
        return Self.predictedHiResPath(from: path, rate: next.rate, monitorName: next.monitor.name)
    }

    nonisolated static func predictedHiResPath(from path: QualityPath, rate: Double, monitorName: String) -> QualityPath {
        var path = path
        path.clock = .init(name: HiResDevice.name, uid: HiResDevice.uid, nominalSampleRate: rate, outputChannelCount: 2,
                           isVirtualHiRes: true)
        path.tap?.sampleRate = rate
        if let format = path.file?.format {
            path.file?.sampleRate = format == .aac ? min(rate, AudioExporter.maxAACSampleRate) : rate
        }
        path.monitor = .init(deviceName: monitorName, sampleRate: nil)
        return path
    }
}
