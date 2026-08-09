import SwiftUI

/// End-of-match scoreboard: who won, how you did, and the full standings.
/// Shown when the host's clock runs out.
struct MatchSummaryView: View {
    @EnvironmentObject private var engine: GameEngine

    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 40
    @ScaledMetric(relativeTo: .title) private var statSize: CGFloat = 34
    @ScaledMetric(relativeTo: .title3) private var trophySize: CGFloat = 26

    private var result: MatchResult? { engine.matchResult }

    var body: some View {
        ZStack {
            Color.echoBackground.ignoresSafeArea()

            if let result {
                ScrollView {
                    VStack(spacing: Space.xl) {
                        header(result)
                        if result.teamPlay {
                            teamTotals(result)
                        }
                        if let me = result.me {
                            personalCard(me, placement: result.myPlacement)
                        }
                        standings(result)
                    }
                    .padding(.horizontal)
                    .padding(.top, Space.xl)
                    .padding(.bottom, Space.md)
                }
                .scrollBounceBehavior(.basedOnSize)

                VStack {
                    Spacer()
                    actions
                }
            }
        }
        .statusBarHidden()
    }

    // MARK: - Header

    private func header(_ result: MatchResult) -> some View {
        VStack(spacing: Space.sm) {
            Text("TIME")
                .font(.appBold(fixedSize: titleSize))
                .tracking(6)
                .foregroundStyle(Color.echoText)

            headline(result)
                .font(.appBold(.title3))
                .multilineTextAlignment(.center)
                .foregroundStyle(tint(result))

            Label(result.duration.durationLabel + " match", systemImage: "timer")
                .font(.app(.caption))
                .foregroundStyle(Color.echoTextSecondary)
        }
    }

    @ViewBuilder
    private func headline(_ result: MatchResult) -> some View {
        if result.isDraw {
            Text("DRAW — no clear winner")
        } else if result.teamPlay {
            if result.didIWin {
                Label("YOUR TEAM WINS", systemImage: "trophy.fill")
            } else {
                Label("TEAM \(result.winningTeam?.displayName.uppercased() ?? "—") WINS",
                      systemImage: "trophy.fill")
            }
        } else if result.didIWin {
            Label { Text("YOU WIN") } icon: { trophy }
        } else {
            Label { Text("\(result.winner?.name.displayCallSign.uppercased() ?? "—") WINS") }
                icon: { trophy }
        }
    }

    /// The hand-drawn trophy, sized to sit on the headline's cap height.
    private var trophy: some View {
        Image(art: .leaderboard)
            .resizable()
            .scaledToFit()
            .frame(width: trophySize, height: trophySize)
    }

    private func tint(_ result: MatchResult) -> Color {
        if result.isDraw { return .echoAccent }
        return result.didIWin ? .echoSecondary : .echoDanger
    }

    // MARK: - Team score

    /// The two team totals side by side, your side first and tinted ally-blue.
    /// A viewer with no team (shouldn't happen for a player) falls back to
    /// alpha-first.
    private func teamTotals(_ result: MatchResult) -> some View {
        let mine = result.myTeam ?? .alpha
        let theirs = mine.other
        return HStack(spacing: 0) {
            stat(mine.displayName.uppercased(), "\(result.kills(for: mine))", .echoTeamAlly)
            divider
            stat(theirs.displayName.uppercased(), "\(result.kills(for: theirs))", .echoDanger)
        }
        .padding(Space.lg)
        .background(Color.echoSurface, in: RoundedRectangle(cornerRadius: Radius.lg))
    }

    // MARK: - Your line

    private func personalCard(_ me: Player, placement: Int?) -> some View {
        VStack(spacing: Space.md) {
            HStack {
                Text("YOUR MATCH")
                    .font(.appBold(.caption))
                    .tracking(1.5)
                    .foregroundStyle(Color.echoTextSecondary)
                Spacer()
                if let placement {
                    Text(placementLabel(placement))
                        .font(.appBold(.caption))
                        .foregroundStyle(placement == 1 ? Color.echoAccent : Color.echoTextSecondary)
                }
            }

            HStack(spacing: 0) {
                stat("KILLS", "\(me.kills)", .echoSecondary)
                divider
                stat("DEATHS", "\(me.deaths)", .echoDanger)
                divider
                stat("K/D", me.kdString, .echoText)
            }
        }
        .padding(Space.lg)
        .background(Color.echoSurface, in: RoundedRectangle(cornerRadius: Radius.lg))
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.echoHairline)
            .frame(width: 1, height: 42)
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: Space.xs) {
            Text(value)
                .font(.appBold(fixedSize: statSize).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.appBold(.caption2))
                .tracking(1)
                .foregroundStyle(Color.echoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func placementLabel(_ place: Int) -> String {
        switch place {
        case 1: return "1st place"
        case 2: return "2nd place"
        case 3: return "3rd place"
        default: return "\(place)th place"
        }
    }

    // MARK: - Standings

    private func standings(_ result: MatchResult) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("FINAL STANDINGS")
                    .font(.appBold(.caption))
                    .tracking(1.5)
                    .foregroundStyle(Color.echoTextSecondary)
                Spacer()
                Text("K / D / RATIO")
                    .font(.app(.caption2))
                    .foregroundStyle(Color.echoTextTertiary)
            }
            .padding(.bottom, Space.md)

            ForEach(Array(result.standings.enumerated()), id: \.element.id) { index, player in
                let isMe = player.name == result.myName
                HStack(spacing: Space.md) {
                    Text("\(index + 1)")
                        .font(.appBold(.subheadline).monospacedDigit())
                        .foregroundStyle(index == 0 ? Color.echoAccent : Color.echoTextSecondary)
                        .frame(width: 20, alignment: .leading)

                    if result.teamPlay {
                        Circle()
                            .fill(Color.echoTeam(player.team, relativeTo: result.myTeam))
                            .frame(width: 8, height: 8)
                            .accessibilityLabel("Team \(player.team?.displayName ?? "unknown")")
                    }

                    Text(player.name.displayCallSign)
                        .font(isMe ? .appBold(.body) : .app(.body))
                        .foregroundStyle(isMe ? Color.echoText : Color.echoTextSecondary)
                        .lineLimit(1)

                    // "You" is emphasis, not a new meaning — weight and a
                    // surface tint carry it rather than another hue.
                    if isMe {
                        Text("you")
                            .font(.app(.caption2))
                            .padding(.horizontal, Space.sm)
                            .padding(.vertical, Space.xxs)
                            .background(Color.echoSurface, in: Capsule())
                    }

                    Spacer(minLength: Space.sm)

                    Text("\(player.kills)")
                        .font(.appBold(.subheadline).monospacedDigit())
                        .foregroundStyle(Color.echoSecondary)
                        .frame(width: 28, alignment: .trailing)
                    Text("\(player.deaths)")
                        .font(.app(.subheadline).monospacedDigit())
                        .foregroundStyle(Color.echoDanger.opacity(Alpha.heavy))
                        .frame(width: 28, alignment: .trailing)
                    Text(player.kdString)
                        .font(.app(.caption).monospacedDigit())
                        .foregroundStyle(Color.echoTextSecondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(.vertical, Space.md)
                .padding(.horizontal, Space.md)
                .background(isMe ? Color.echoSurface : .clear,
                            in: RoundedRectangle(cornerRadius: Radius.md))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(index + 1). \(player.name.displayCallSign)\(isMe ? ", you" : ""), "
                    + "\(player.kills) kills, \(player.deaths) deaths"
                )
            }
        }
        .padding(Space.lg)
        .background(Color.echoSurface, in: RoundedRectangle(cornerRadius: Radius.lg))
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: Space.md) {
            Button {
                engine.returnToLobby()
            } label: {
                Text(engine.isHost ? "Back to Lobby — run it again" : "Back to Lobby")
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(Color.echoOnPrimary)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Color.echoPrimary)

            Button("Leave Game", role: .destructive) { engine.leave() }
                .font(.app(.footnote))
        }
        .padding(.horizontal)
        .padding(.bottom, Space.lg)
        .background(
            LinearGradient(colors: [Color.echoBackground.opacity(0), Color.echoBackground],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }
}
