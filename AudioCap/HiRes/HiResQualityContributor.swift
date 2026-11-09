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
        guard isRouted else { return path }
        var path = path
        path.clock?.isVirtualHiRes = true
        if let device = monitorDevice {
            path.monitor = .init(deviceName: device.name, sampleRate: monitorOutputRate)
        }
        return path
    }
}
