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
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(index == 0 ? .yellow : .secondary)
                            .frame(width: 24)

                        Circle()
                            .fill(player.isConnected ? (player.isAlive ? Color.green : Color.red) : Color.gray)
                            .frame(width: 10, height: 10)

                        Text(player.name.displayCallSign)
                            .font(player.name == engine.myName ? .headline.bold() : .headline)
                            .foregroundStyle(player.isConnected ? .primary : .secondary)

                        Spacer()

                        Text("\(player.kills) K")
                            .font(.subheadline.monospacedDigit())
                        Text("\(player.deaths) D")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("\(player.hp) HP")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
            .navigationTitle("Scoreboard")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
