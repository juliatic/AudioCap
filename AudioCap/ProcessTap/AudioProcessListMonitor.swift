import Foundation
import AudioToolbox
import OSLog

/// Watches CoreAudio for changes that affect the source list: processes joining or leaving
/// `kAudioHardwarePropertyProcessObjectList`, and each process starting or stopping output
/// (`kAudioProcessPropertyIsRunningOutput`). This catches audio-only processes such as `afplay`,
/// which never show up in `NSWorkspace.runningApplications`.
///
/// Listener blocks run on a private serial queue, never on the main actor. Bursts of events are
/// coalesced into one `onChange` call per `coalescingInterval`.
final class AudioProcessListMonitor: @unchecked Sendable {
    private let logger = Logger(subsystem: kAppSubsystem, category: "AudioProcessListMonitor")
    private let queue = DispatchQueue(label: "AudioProcessListMonitor", qos: .userInitiated)
    private let coalescingInterval: DispatchTimeInterval
    private let watchesCoreAudio: Bool
    private let onChange: @Sendable () -> Void

    // Touched only on `queue`.
    private var isRunning = false
    private var changePending = false
    private var listBlock: AudioObjectPropertyListenerBlock?
    private var outputBlocks = [AudioObjectID: AudioObjectPropertyListenerBlock]()

    private static let listAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let outputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningOutput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// `watchesCoreAudio: false` only coalesces `noteChange()` calls (for tests).
    init(coalescingInterval: DispatchTimeInterval = .milliseconds(150), watchesCoreAudio: Bool = true, onChange: @escaping @Sendable () -> Void) {
        self.coalescingInterval = coalescingInterval
        self.watchesCoreAudio = watchesCoreAudio
        self.onChange = onChange
    }

    func start() {
        queue.async { [self] in
            guard !isRunning else { return }
            isRunning = true
            guard watchesCoreAudio else { return }

            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                self.updateOutputListeners()
                self.noteChange()
            }
            var address = Self.listAddress
            let status = AudioObjectAddPropertyListenerBlock(.system, &address, queue, block)
            if status == noErr {
                listBlock = block
            } else {
                logger.warning("Process list listener failed: \(status, privacy: .public)")
            }
            updateOutputListeners()
        }
    }

    func stop() {
        queue.async { [self] in removeAllListeners() }
    }

    deinit {
        // No queued block holds a strong reference, so nothing else touches the state now.
        removeAllListeners()
    }

    /// Records that something changed; `onChange` fires once after the coalescing interval.
    func noteChange() {
        queue.async { [self] in
            guard isRunning, !changePending else { return }
            changePending = true
            queue.asyncAfter(deadline: .now() + coalescingInterval) { [weak self] in
                guard let self, self.isRunning else { return }
                self.changePending = false
                self.onChange()
            }
        }
    }

    /// Number of processes with an output listener, for tests.
    func outputListenerCount() -> Int {
        queue.sync { outputBlocks.count }
    }

    private func updateOutputListeners() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isRunning else { return }

        let current = Set((try? AudioObjectID.readProcessList()) ?? [])

        for (objectID, block) in outputBlocks where !current.contains(objectID) {
            var address = Self.outputAddress
            AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
            outputBlocks[objectID] = nil
        }

        for objectID in current where outputBlocks[objectID] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.noteChange() }
            var address = Self.outputAddress
            if AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block) == noErr {
                outputBlocks[objectID] = block
            }
        }
    }

    private func removeAllListeners() {
        isRunning = false
        if let listBlock {
            var address = Self.listAddress
            AudioObjectRemovePropertyListenerBlock(.system, &address, queue, listBlock)
            self.listBlock = nil
        }
        for (objectID, block) in outputBlocks {
            var address = Self.outputAddress
            AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
        }
        outputBlocks.removeAll()
    }
}
