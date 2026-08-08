import SwiftUI

/// End-of-match scoreboard: who won, how you did, and the full standings.
/// Shown when the host's clock runs out.
struct MatchSummaryView: View {
    @EnvironmentObject private var engine: GameEngine

    private var result: MatchResult? { engine.matchResult }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let result {
                ScrollView {
                    VStack(spacing: 22) {
                        header(result)
                        if let me = result.me {
                            personalCard(me, placement: result.myPlacement)
                        }
                        standings(result)
                    }
                    .padding(.horizontal)
                    .padding(.top, 28)
                    .padding(.bottom, 12)
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
        VStack(spacing: 8) {
            Text("TIME")
                .font(.system(size: 40, weight: .black, design: .rounded))
                .tracking(6)
                .foregroundStyle(.white)

            Text(headline(result))
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .foregroundStyle(tint(result))

            Label(result.duration.durationLabel + " match", systemImage: "timer")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func headline(_ result: MatchResult) -> String {
        if result.isDraw { return "DRAW — no clear winner" }
        if result.didIWin { return "🏆  YOU WIN" }
        return "🏆  \(result.winner?.name.displayCallSign.uppercased() ?? "—") WINS"
    }

    private func tint(_ result: MatchResult) -> Color {
        if result.isDraw { return .orange }
        return result.didIWin ? .green : .red
    }

    // MARK: - Your line

    private func personalCard(_ me: Player, placement: Int?) -> some View {
        VStack(spacing: 14) {
            HStack {
                Text("YOUR MATCH")
                    .font(.caption.bold())
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
                Spacer()
                if let placement {
                    Text(placementLabel(placement))
                        .font(.caption.bold())
                        .foregroundStyle(placement == 1 ? .yellow : .secondary)
                }
            }

            HStack(spacing: 0) {
                stat("KILLS", "\(me.kills)", .green)
                divider
                stat("DEATHS", "\(me.deaths)", .red)
                divider
                stat("K/D", me.kdString, .white)
            }
        }
        .padding(18)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(width: 1, height: 42)
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 34, weight: .black, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2.bold())
                .tracking(1)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
                    .foregroundStyle(.secondary)
                Spacer()
                Text("K / D / RATIO")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 10)

            ForEach(Array(result.standings.enumerated()), id: \.element.id) { index, player in
                let isMe = player.name == result.myName
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(index == 0 ? .yellow : .secondary)
                        .frame(width: 20, alignment: .leading)

                    Text(player.name.displayCallSign)
                        .font(isMe ? .body.bold() : .body)
                        .foregroundStyle(isMe ? .white : .white.opacity(0.75))
                        .lineLimit(1)

                    if isMe {
                        Text("you")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.35), in: Capsule())
                    }

                    Spacer(minLength: 8)

                    Text("\(player.kills)")
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(.green)
                        .frame(width: 28, alignment: .trailing)
                    Text("\(player.deaths)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.red.opacity(0.85))
                        .frame(width: 28, alignment: .trailing)
                    Text(player.kdString)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(isMe ? .blue.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                engine.returnToLobby()
            } label: {
                Text(engine.isHost ? "Back to Lobby — run it again" : "Back to Lobby")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)

            Button("Leave Game", role: .destructive) { engine.leave() }
                .font(.footnote)
        }
        .padding(.horizontal)
        .padding(.bottom, 16)
        .background(
            LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }
}
