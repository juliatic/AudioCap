import Foundation

/// Keeps the Process picker on the selected source while it is gone and follows its relaunch,
/// matching the way `ProcessTap` re-attaches: same bundle ID, or the same executable when there is none.
enum SourceSelection {
    /// Whether `candidate` is a new instance of `selected` (a different process object of the same source).
    static func isRelaunch(of selected: AudioProcess, executablePath: String?,
                           candidate: AudioProcess, candidatePath: String?) -> Bool {
        guard selected.kind != .system, candidate.kind != .system, candidate.objectID != selected.objectID else { return false }
        return ProcessTap.isRelaunch(bundleID: selected.bundleID, executablePath: executablePath,
                                     candidateBundleID: candidate.bundleID, candidatePath: candidatePath)
    }

    /// The picker row for `selected`: itself while listed, its relaunch once it is back, or `nil` while it is gone.
    static func row(for selected: AudioProcess, executablePath: String?, in processes: [AudioProcess],
                    path: (AudioProcess) -> String?) -> AudioProcess? {
        if selected.kind == .system || processes.contains(selected) { return selected }
        return processes.first { isRelaunch(of: selected, executablePath: executablePath, candidate: $0, candidatePath: path($0)) }
    }
}
