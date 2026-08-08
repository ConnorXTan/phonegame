import SwiftUI

/// Phase-2 milestone view: live per-peer UWB numbers. Walk around a room and
/// watch distance/direction update; direction goes nil when the peer leaves
/// the FoV cone (or a body blocks the signal).
struct DebugRangingView: View {
    @EnvironmentObject private var engine: GameEngine

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                List {
                    if engine.opponents.isEmpty {
                        Text("No peers connected")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(engine.opponents) { player in
                        row(for: player)
                    }
                }
            }
            .navigationTitle("UWB Ranging")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func row(for player: Player) -> some View {
        let reading = engine.ranging.latestReading(for: player.name)
        let angle = reading?.angleOffBoresight
        let inCone = angle.map { $0 < engine.settings.aimConeRadians } ?? false
        let inRange = (reading?.distance).map { $0 < engine.settings.weaponRange } ?? false

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(inCone && inRange ? Color.red : (reading != nil ? Color.green : Color.gray))
                    .frame(width: 10, height: 10)
                Text(player.name.displayCallSign).font(.headline)
                Spacer()
                Text("\(engine.ranging.sampleRate(for: player.name)) Hz")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let reading {
                grid(reading: reading, angle: angle, inCone: inCone)
            } else {
                Text("no readings yet — waiting for token exchange / UWB lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            calibrationRow(for: player)
                .font(.caption.monospacedDigit())
        }
        .padding(.vertical, 4)
    }

    private func grid(reading: RangingReading, angle: Float?, inCone: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            row("distance", reading.distance.map { String(format: "%.2f m", $0) } ?? "—")
            row("direction", reading.direction.map {
                String(format: "(%.2f, %.2f, %.2f)", $0.x, $0.y, $0.z)
            } ?? "nil — not in your sights")
            row("angle off boresight", angle.map { String(format: "%.1f°", $0 * 180 / .pi) } ?? "—")
            row("in cone", angle == nil ? "—" : (inCone ? "YES 🎯" : "no"))
            row("horizontal angle", reading.horizontalAngle.map {
                String(format: "%.1f°", $0 * 180 / .pi)
            } ?? "—")
        }
        .font(.caption.monospacedDigit())
    }

    private func calibrationRow(for player: Player) -> some View {
        row("aim assist", engine.ranging.convergenceHint(for: player.name) ?? "ready")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }
}
