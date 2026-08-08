import SwiftUI

/// End-of-match scoreboard: who won, how you did, and the full standings.
/// Shown when the host's clock runs out.
struct MatchSummaryView: View {
    @EnvironmentObject private var engine: GameEngine

    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 40
    @ScaledMetric(relativeTo: .title) private var statSize: CGFloat = 34

    private var result: MatchResult? { engine.matchResult }

    var body: some View {
        ZStack {
            Color.echoBackground.ignoresSafeArea()

            if let result {
                ScrollView {
                    VStack(spacing: Space.xl) {
                        header(result)
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
                .font(.system(size: titleSize, weight: .black, design: .rounded))
                .tracking(6)
                .foregroundStyle(Color.echoText)

            headline(result)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .foregroundStyle(tint(result))

            Label(result.duration.durationLabel + " match", systemImage: "timer")
                .font(.caption)
                .foregroundStyle(Color.echoTextSecondary)
        }
    }

    @ViewBuilder
    private func headline(_ result: MatchResult) -> some View {
        if result.isDraw {
            Text("DRAW — no clear winner")
        } else if result.didIWin {
            Label("YOU WIN", systemImage: "trophy.fill")
        } else {
            Label("\(result.winner?.name.displayCallSign.uppercased() ?? "—") WINS",
                  systemImage: "trophy.fill")
        }
    }

    private func tint(_ result: MatchResult) -> Color {
        if result.isDraw { return .echoAccent }
        return result.didIWin ? .echoSecondary : .echoDanger
    }

    // MARK: - Your line

    private func personalCard(_ me: Player, placement: Int?) -> some View {
        VStack(spacing: Space.md) {
            HStack {
                Text("YOUR MATCH")
                    .font(.caption.bold())
                    .tracking(1.5)
                    .foregroundStyle(Color.echoTextSecondary)
                Spacer()
                if let placement {
                    Text(placementLabel(placement))
                        .font(.caption.bold())
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
                .font(.system(size: statSize, weight: .black, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2.bold())
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
                    .font(.caption.bold())
                    .tracking(1.5)
                    .foregroundStyle(Color.echoTextSecondary)
                Spacer()
                Text("K / D / RATIO")
                    .font(.caption2)
                    .foregroundStyle(Color.echoTextTertiary)
            }
            .padding(.bottom, Space.md)

            ForEach(Array(result.standings.enumerated()), id: \.element.id) { index, player in
                let isMe = player.name == result.myName
                HStack(spacing: Space.md) {
                    Text("\(index + 1)")
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(index == 0 ? Color.echoAccent : Color.echoTextSecondary)
                        .frame(width: 20, alignment: .leading)

                    Text(player.name.displayCallSign)
                        .font(isMe ? .body.bold() : .body)
                        .foregroundStyle(isMe ? Color.echoText : Color.echoTextSecondary)
                        .lineLimit(1)

                    // "You" is emphasis, not a new meaning — weight and a
                    // surface tint carry it rather than another hue.
                    if isMe {
                        Text("you")
                            .font(.caption2)
                            .padding(.horizontal, Space.sm)
                            .padding(.vertical, Space.xxs)
                            .background(Color.echoSurface, in: Capsule())
                    }

                    Spacer(minLength: Space.sm)

                    Text("\(player.kills)")
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(Color.echoSecondary)
                        .frame(width: 28, alignment: .trailing)
                    Text("\(player.deaths)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Color.echoDanger.opacity(Alpha.heavy))
                        .frame(width: 28, alignment: .trailing)
                    Text(player.kdString)
                        .font(.caption.monospacedDigit())
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
                .font(.footnote)
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
