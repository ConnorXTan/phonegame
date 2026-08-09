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

    /// Your own side reads first — that's the half you scan for under pressure.
    private var teamsOrdered: [Team] {
        guard let mine = engine.myTeam else { return Team.allCases }
        return [mine, mine.other]
    }

    var body: some View {
        NavigationStack {
            List {
                if engine.settings.teamPlay {
                    ForEach(teamsOrdered) { team in
                        Section {
                            ForEach(Array(ranked.filter { $0.team == team }.enumerated()),
                                    id: \.element.id) { index, player in
                                row(player, rank: index + 1)
                            }
                        } header: {
                            teamHeader(team)
                        }
                    }
                } else {
                    ForEach(Array(ranked.enumerated()), id: \.element.id) { index, player in
                        row(player, rank: index + 1)
                    }
                }
            }
            .navigationTitle("Scoreboard")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Team name, combined kills, and "your team" in words beside the tint.
    private func teamHeader(_ team: Team) -> some View {
        HStack(spacing: Space.sm) {
            Circle()
                .fill(Color.echoTeam(team, relativeTo: engine.myTeam))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text("\(team.displayName) · \(engine.teamKills(team)) kills")
            if team == engine.myTeam {
                Text("your team")
                    .foregroundStyle(Color.echoTeamAlly)
            }
        }
    }

    private func row(_ player: Player, rank: Int) -> some View {
        HStack(spacing: Space.md) {
            Text("\(rank)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(rank == 1 ? Color.echoAccent : Color.echoTextSecondary)
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

    private func statusColor(for player: Player) -> Color {
        guard player.isConnected else { return .echoInert }
        return player.isAlive ? .echoSecondary : .echoDanger
    }

    private func statusLabel(for player: Player) -> String {
        guard player.isConnected else { return "Disconnected" }
        return player.isAlive ? "Alive" : "Down"
    }
}
