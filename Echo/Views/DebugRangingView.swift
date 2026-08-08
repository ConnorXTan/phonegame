import SwiftUI

/// Phase-2 milestone view: live per-peer UWB numbers. Walk around a room and
/// watch distance/direction update; direction goes nil when the peer leaves
/// the FoV cone (or a body blocks the signal).
struct DebugRangingView: View {
    @EnvironmentObject private var engine: GameEngine

    /// One row per human. Every rejoin mints a fresh "#xxxx" wire name and the
    /// old roster entry is kept during a match (so a reconnect doesn't wipe
    /// their score), which otherwise stacks up a new row each time someone is
    /// seen. Collapse by call sign and show whichever entry is actually live.
    private var peers: [Player] {
        Dictionary(grouping: engine.opponents, by: \.name.displayCallSign)
            .values
            .compactMap { entries in
                entries.first { $0.isConnected && engine.ranging.latestReading(for: $0.name) != nil }
                    ?? entries.first { $0.isConnected }
                    ?? entries.first
            }
            .sorted { $0.name.displayCallSign < $1.name.displayCallSign }
    }

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
                    if peers.isEmpty {
                        Text("No peers connected")
                            .foregroundStyle(Color.echoTextSecondary)
                    }
                    ForEach(peers) { player in
                        row(for: player)
                    }
                }
            }
            .navigationTitle("UWB Ranging")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Name and distance only. The dot still carries lock state, so the row
    /// answers "are they in my sights" without spelling out the geometry.
    private func row(for player: Player) -> some View {
        let reading = engine.ranging.latestReading(for: player.name)
        let angle = reading?.angleOffBoresight
        let inCone = angle.map { $0 < engine.settings.aimConeRadians } ?? false
        let inRange = (reading?.distance).map { $0 < engine.settings.weaponRange } ?? false

        return HStack(spacing: Space.sm) {
            Circle()
                .fill(inCone && inRange
                      ? Color.echoPrimary
                      : (reading != nil ? Color.echoSecondary : Color.echoInert))
                .frame(width: 10, height: 10)
                .accessibilityLabel(inCone && inRange
                                    ? "In your sights"
                                    : (reading != nil ? "Ranging" : "No signal"))
            Text(player.name.displayCallSign)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: Space.sm)
            Text(reading?.distance.map { String(format: "%.2f m", $0) } ?? "—")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(reading == nil ? Color.echoTextSecondary : Color.echoText)
                .fixedSize()
        }
        .padding(.vertical, Space.xxs)
    }
}
