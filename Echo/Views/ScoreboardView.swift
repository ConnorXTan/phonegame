import SwiftUI

struct ScoreboardView: View {
    @EnvironmentObject private var engine: GameEngine

    private var ranked: [Player] {
        engine.players.values.sorted { a, b in
            if a.kills != b.kills { return a.kills > b.kills }
            if a.deaths != b.deaths { return a.deaths < b.deaths }
            return a.name < b.name
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(ranked.enumerated()), id: \.element.id) { index, player in
                    HStack(spacing: Space.md) {
                        Text("\(index + 1)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(index == 0 ? Color.echoAccent : Color.echoTextSecondary)
                            .frame(width: 24)

                        Circle()
                            .fill(statusColor(for: player))
                            .frame(width: 10, height: 10)
                            .accessibilityLabel(statusLabel(for: player))

                        Text(player.name.displayCallSign)
                            .font(player.name == engine.myName ? .headline.bold() : .headline)
                            .foregroundStyle(player.isConnected
                                             ? Color.echoText
                                             : Color.echoTextSecondary)

                        Spacer()

                        Text("\(player.kills) K")
                            .font(.subheadline.monospacedDigit())
                        Text("\(player.deaths) D")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Color.echoTextSecondary)
                        Text("\(player.hp) HP")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.echoTextSecondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .navigationTitle("Scoreboard")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func statusColor(for player: Player) -> Color {
        guard player.isConnected else { return .echoInert }
        return player.isAlive ? .echoSecondary : .echoDanger
    }

    private func statusLabel(for player: Player) -> String {
        guard player.isConnected else { return "Disconnected" }
        return player.isAlive ? "Alive" : "Down"
    }
}
