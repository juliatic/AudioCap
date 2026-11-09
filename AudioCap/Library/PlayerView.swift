import SwiftUI
import AVFoundation

/// Plays one library take and compares the length its header declares with the audio that actually decodes.
@Observable
@MainActor
final class PlayerModel {
    private(set) var entryID: LibraryEntry.ID?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var playerDuration: TimeInterval = 0
    private(set) var waveform: [Float] = []
    private(set) var analysis: FileAnalysis?
    private(set) var errorMessage: String?

    @ObservationIgnored private var player: OutputOnlyPlayer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?

    static let waveformBins = 400

    func load(_ entry: LibraryEntry) {
        unload()
        entryID = entry.id
        analysis = entry.analysis
        do {
            let player = try OutputOnlyPlayer(url: entry.fileURL)
            self.player = player
            playerDuration = player.duration
        } catch {
            errorMessage = error.audioCapDescription
        }
        let url = entry.fileURL
        analysisTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                try? AudioFileInspector.analyze(url, waveformBins: PlayerModel.waveformBins)
            }.value
            guard let self, !Task.isCancelled, self.entryID == entry.id, let result else { return }
            self.waveform = result.waveform
            self.analysis = result.analysis
        }
    }

    func unload() {
        timer?.invalidate()
        timer = nil
        analysisTask?.cancel()
        player?.stop()
        player = nil
        entryID = nil
        isPlaying = false
        currentTime = 0
        playerDuration = 0
        waveform = []
        analysis = nil
        errorMessage = nil
    }

    func togglePlayback() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
        } else {
            do {
                try player.play()
                startTimer()
            } catch {
                errorMessage = error.audioCapDescription
            }
        }
        refresh()
    }

    func seek(toFraction fraction: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(1, fraction)) * player.duration
        refresh()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        guard let player else { return }
        player.checkEngine()
        currentTime = player.currentTime
        isPlaying = player.isPlaying
        if !player.isPlaying {
            timer?.invalidate()
            timer = nil
        }
    }
}

struct PlayerView: View {
    let entry: LibraryEntry
    let model: PlayerModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(entry.displayName).font(AppStyle.headline)
                Spacer()
                Button("Close Player", systemImage: "xmark.circle.fill", action: onClose)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }

            WaveformView(peaks: model.waveform, progress: model.playerDuration > 0 ? model.currentTime / model.playerDuration : 0) {
                model.seek(toFraction: $0)
            }
            .frame(height: 64)

            HStack(spacing: 12) {
                Button(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill") {
                    model.togglePlayback()
                }
                .labelStyle(.iconOnly)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.errorMessage != nil)

                Text(verbatim: "\(Self.clock(model.currentTime)) / \(Self.clock(model.playerDuration))")
                    .monospacedDigit()
                Spacer()
            }

            lengthComparison

            if let error = model.errorMessage {
                Text(error).errorTextStyle()
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var lengthComparison: some View {
        if let analysis = model.analysis {
            HStack(spacing: 16) {
                LabeledContent("Header") { Text(Self.clock(analysis.headerDuration)).monospacedDigit() }
                LabeledContent("Decoded") { Text(Self.clock(analysis.decodedDuration)).monospacedDigit() }
                if entry.capturedFrames > 0, entry.sampleRate > 0 {
                    LabeledContent("Captured") { Text(Self.clock(Double(entry.capturedFrames) / entry.sampleRate)).monospacedDigit() }
                }
            }
            if analysis.lengthMatches, entry.lengthIsConsistent != false {
                Label { Text("Lengths match") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            } else {
                Label("Length mismatch: players may stop early or keep playing past the shown length", systemImage: "exclamationmark.triangle.fill")
                    .warningTextStyle()
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// `m:ss.mmm`, precise enough to show a mismatch of a few milliseconds.
    static func clock(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        let minutes = Int(value / 60)
        return String(format: "%d:%06.3f", minutes, value - Double(minutes * 60))
    }
}

/// Peak waveform; click or drag to scrub.
struct WaveformView: View {
    let peaks: [Float]
    let progress: Double
    var onScrub: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .leading) {
                Canvas { context, size in
                    guard !peaks.isEmpty else { return }
                    let step = size.width / CGFloat(peaks.count)
                    for (index, peak) in peaks.enumerated() {
                        let height = max(1, CGFloat(peak) * size.height)
                        let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2, width: max(1, step - 0.5), height: height)
                        let played = Double(index) / Double(peaks.count) < progress
                        context.fill(Path(rect), with: .color(played ? .accentColor : .secondary.opacity(0.5)))
                    }
                }
                Rectangle().fill(.primary).frame(width: 1).offset(x: size.width * progress)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                onScrub(value.location.x / max(1, size.width))
            })
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement()
        .accessibilityLabel(Text("Waveform"))
        .accessibilityValue(Text(progress.formatted(.percent.precision(.fractionLength(0)))))
        .accessibilityAdjustableAction { direction in
            onScrub(progress + (direction == .increment ? 0.05 : -0.05))
        }
    }
}
