import SwiftUI

/// Mid-match standings. A table, so the labels live once in a column header and
/// every row below is pure value — the old rows repeated "K", "D", and "HP" on
/// every line, which is the same three words printed once per player.
struct ScoreboardView: View {
    @EnvironmentObject private var engine: GameEngine

    /// Column widths, shared by the header and every row. With the labels only
    /// at the top, the columns have to line up exactly or the header stops
    /// naming anything.
    /// Wide enough for the word RANK on one line, which is what sets the name
    /// column's left edge.
    @ScaledMetric(relativeTo: .subheadline) private var rankWidth: CGFloat = 46
    @ScaledMetric(relativeTo: .subheadline) private var kdWidth: CGFloat = 58
    @ScaledMetric(relativeTo: .subheadline) private var hpWidth: CGFloat = 42

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
            ZStack {
                Color.echoBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        columnHeader
                        if engine.settings.teamPlay {
                            ForEach(teamsOrdered) { team in
                                teamHeader(team)
                                rows(ranked.filter { $0.team == team })
                            }
                        } else {
                            rows(ranked)
                        }
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.sm)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .navigationTitle("Scoreboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.echoBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationBackground(Color.echoBackground)
    }

    // MARK: - Header

    /// The one place the columns are named. A hairline under it is the one border
    /// this screen earns — it's what makes the labels read as a header rather
    /// than as a first row.
    private var columnHeader: some View {
        HStack(spacing: Space.md) {
            Text("RANK")
                .frame(width: rankWidth, alignment: .leading)
            Text("NAME")
            Spacer(minLength: Space.sm)
            Text("K | D")
                .frame(width: kdWidth, alignment: .trailing)
            Text("HP")
                .frame(width: hpWidth, alignment: .trailing)
        }
        .font(.appBold(.caption2))
        .tracking(1)
        .lineLimit(1)   // a wrapped column label stops naming its column
        .foregroundStyle(Color.echoTextTertiary)
        .padding(.horizontal, Space.sm)   // matches the rows, so columns line up
        .padding(.bottom, Space.sm)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.echoHairline)
                .frame(height: 1)
        }
        .accessibilityHidden(true)   // each row already speaks its own values
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
            Spacer()
        }
        .font(.appBold(.caption))
        .foregroundStyle(Color.echoTextSecondary)
        .padding(.horizontal, Space.sm)
        .padding(.top, Space.lg)
        .padding(.bottom, Space.xs)
    }

    // MARK: - Rows

    private func rows(_ players: [Player]) -> some View {
        ForEach(Array(players.enumerated()), id: \.element.id) { index, player in
            row(player, rank: index + 1)
        }
    }

    private func row(_ player: Player, rank: Int) -> some View {
        let isMe = player.name == engine.myName
        return HStack(spacing: Space.md) {
            Text("\(rank)")
                .font(.app(.headline).monospacedDigit())
                .foregroundStyle(rank == 1 ? Color.echoAccent : Color.echoTextSecondary)
                .frame(width: rankWidth, alignment: .leading)

            Text(player.name.displayCallSign)
                .font(isMe ? .appBold(.headline) : .app(.headline))
                .foregroundStyle(player.isConnected
                                 ? Color.echoText
                                 : Color.echoTextSecondary)
                .lineLimit(1)

            Spacer(minLength: Space.sm)

            killDeath(player)
                .frame(width: kdWidth, alignment: .trailing)

            Text("\(player.hp)")
                .font(.app(.subheadline).monospacedDigit())
                .foregroundStyle(Color.echoText)
                .frame(width: hpWidth, alignment: .trailing)
        }
        .padding(.vertical, Space.sm)
        .padding(.horizontal, Space.sm)
        // "You" is emphasis, not a new meaning — a surface tint and the bold
        // name carry it rather than another hue.
        .background(isMe ? Color.echoSurface : .clear,
                    in: RoundedRectangle(cornerRadius: Radius.sm))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(rank). \(player.name.displayCallSign)\(isMe ? ", you" : ""), "
            + "\(statusLabel(for: player)), \(player.kills) kills, "
            + "\(player.deaths) deaths, \(player.hp) health"
        )
    }

    /// Kills and deaths as one figure, split by a dim rule — two numbers that
    /// are read together shouldn't look like two separate columns.
    private func killDeath(_ player: Player) -> some View {
        (
            Text("\(player.kills)")
                .foregroundStyle(Color.echoText)
            + Text(" | ")
                .foregroundStyle(Color.echoTextTertiary)
            + Text("\(player.deaths)")
                .foregroundStyle(Color.echoTextSecondary)
        )
        .font(.app(.subheadline).monospacedDigit())
    }

    /// Spoken only. There's no status glyph in the row — the HP column already
    /// shows who's down — but VoiceOver has no column of numbers to scan, so it
    /// still gets the word.
    private func statusLabel(for player: Player) -> String {
        guard player.isConnected else { return "Disconnected" }
        return player.isAlive ? "Alive" : "Down"
    }
}
