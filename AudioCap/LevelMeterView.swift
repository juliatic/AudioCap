import SwiftUI

/// Live peak/RMS meter with a short peak hold, in dBFS.
struct LevelMeterView: View {
    let level: AudioLevel

    @State private var held: Double = -240
    @State private var heldAt = Date.distantPast

    private static let floorDb: Double = -60
    private static let holdSeconds: TimeInterval = 1.5

    var body: some View {
        HStack(spacing: 12) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color(level.peakDb).opacity(0.45))
                        .frame(width: width * Self.fraction(level.peakDb))
                    Capsule().fill(color(level.peakDb))
                        .frame(width: width * Self.fraction(level.rmsDb))
                    Rectangle().fill(color(held))
                        .frame(width: 2)
                        .offset(x: max(0, width * Self.fraction(held) - 2))
                        .opacity(held > Self.floorDb ? 1 : 0)
                }
            }
            .frame(height: 12)

            Text(Self.dbText(level.peakDb))
                .monospacedDigit()
                .frame(minWidth: 90, alignment: .trailing)
        }
        .onChange(of: level) { _, new in
            let now = Date()
            if new.peakDb >= held || now.timeIntervalSince(heldAt) > Self.holdSeconds {
                held = new.peakDb
                heldAt = now
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Level"))
        .accessibilityValue(Text(Self.dbText(level.peakDb)))
    }

    private func color(_ db: Double) -> Color {
        db > -1 ? .red : db > -6 ? .yellow : .green
    }

    static func fraction(_ db: Double) -> Double { max(0, min(1, (db - floorDb) / -floorDb)) }

    static func dbText(_ db: Double) -> String {
        db <= -120 ? "−∞ dBFS" : "\(db.formatted(.number.precision(.fractionLength(1)))) dBFS"
    }
}
