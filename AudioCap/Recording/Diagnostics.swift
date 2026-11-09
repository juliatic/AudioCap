import Foundation
import AVFoundation
import AppKit

/// Builds the plain-text report behind the "Copy diagnostics" button.
enum Diagnostics {
    static var osDescription: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion) (build \(osBuild ?? "?"))"
    }

    static var osBuild: String? { sysctlString("kern.osversion") }
    static var hardwareModel: String? { sysctlString("hw.model") }

    static var appDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(Bundle.main.bundleIdentifier ?? "?") \(version) (\(build))"
    }

    static func describe(settings: [String: Any]) -> String {
        settings.keys.sorted().map { key in
            var value = settings[key].map { "\($0)" } ?? "nil"
            if key == AVFormatIDKey, let id = settings[key] as? AudioFormatID, let code = AudioStatus.fourCharCode(OSStatus(bitPattern: id)) {
                value = "'\(code)'"
            }
            if settings[key] is Data { value = "<\((settings[key] as! Data).count) bytes>" }
            return "\(key)=\(value)"
        }.joined(separator: ", ")
    }

    static func copyToPasteboard(_ report: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
