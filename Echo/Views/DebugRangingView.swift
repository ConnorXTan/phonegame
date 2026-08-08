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
                    // Lives here rather than on the HUD: the game screen is the
                    // camera viewfinder, so the top-down view is a diagnostic.
                    Section("Radar") {
                        RadarView()
                            .frame(height: 180)
                            .listRowBackground(Color.echoBackground)
                    }
                    if engine.opponents.isEmpty {
                        Text("No peers connected")
                            .foregroundStyle(Color.echoTextSecondary)
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

        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Circle()
                    .fill(inCone && inRange
                          ? Color.echoPrimary
                          : (reading != nil ? Color.echoSecondary : Color.echoInert))
                    .frame(width: 10, height: 10)
                    .accessibilityLabel(inCone && inRange
                                        ? "In your sights"
                                        : (reading != nil ? "Ranging" : "No signal"))
                Text(player.name.displayCallSign).font(.headline)
                Spacer()
                Text("\(engine.ranging.sampleRate(for: player.name)) Hz")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.echoTextSecondary)
            }

            if let reading {
                grid(reading: reading, angle: angle, inCone: inCone)
            } else {
                Text("no readings yet — waiting for token exchange / UWB lock")
                    .font(.caption)
                    .foregroundStyle(Color.echoTextSecondary)
            }
            calibrationRow(for: player)
                .font(.caption.monospacedDigit())
            invalidationRows(for: player)
                .font(.caption.monospacedDigit())
        }
        .padding(.vertical, Space.xs)
    }

    private func grid(reading: RangingReading, angle: Float?, inCone: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            row("reading age", String(format: "%.2f s", Date().timeIntervalSince(reading.timestamp)))
            row("distance", reading.distance.map { String(format: "%.2f m", $0) } ?? "—")
            row("direction", reading.direction.map {
                String(format: "(%.2f, %.2f, %.2f)", $0.x, $0.y, $0.z)
            } ?? "nil — not in your sights")
            row("angle off boresight", angle.map { String(format: "%.1f°", $0 * 180 / .pi) } ?? "—")
            row("in cone", angle == nil ? "—" : (inCone ? "yes" : "no"))
            row("horizontal angle", reading.horizontalAngle.map {
                String(format: "%.1f°", $0 * 180 / .pi)
            } ?? "—")
        }
        .font(.caption.monospacedDigit())
    }

    private func calibrationRow(for player: Player) -> some View {
        row("aim assist", engine.ranging.convergenceHint(for: player.name) ?? "ready")
    }

    /// Raw NIError from the last session invalidation. Playtests run without
    /// Xcode attached, so this sheet is the only place the code is readable.
    @ViewBuilder
    private func invalidationRows(for player: Player) -> some View {
        if let inv = engine.ranging.lastInvalidation(for: player.name) {
            row("last NI error", inv.message)
            row("invalidations", "\(inv.count), last \(Int(Date().timeIntervalSince(inv.at))) s ago")
        } else {
            row("last NI error", "none")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Color.echoTextSecondary)
            Spacer()
            Text(value)
        }
    }
}
