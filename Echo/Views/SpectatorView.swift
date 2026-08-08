import SwiftUI

/// The laptop's control room: live roster with HP/K/D, click a player to
/// watch their viewfinder, host controls (mode, duration, Start), kill feed,
/// and final standings. Covers lobby, playing, and summary phases.
struct SpectatorView: View {
    @EnvironmentObject private var engine: GameEngine

    private var roster: [Player] { engine.opponents }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                Divider().overlay(.white.opacity(0.15))
                if engine.phase == .summary, let result = engine.matchResult {
                    summary(result)
                } else {
                    content
                }
            }
        }
        .foregroundStyle(.white)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            Label("ECHO · SPECTATOR", systemImage: "tv")
                .font(.headline.weight(.black))
                .tracking(1)

            if engine.phase == .playing {
                Text(engine.matchRemaining.clockString)
                    .font(.title3.monospacedDigit().bold())
                    .foregroundStyle(engine.matchRemaining < 30 ? .red : .white)
            }

            Spacer()

            if engine.phase == .lobby {
                Picker("Mode", selection: Binding(
                    get: { engine.settings.mode },
                    set: { engine.settings = .preset(for: $0) }
                )) {
                    Text("Indoor").tag(GameMode.indoor)
                    Text("Outdoor").tag(GameMode.outdoor)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                Menu {
                    ForEach(GameSettings.durationChoices, id: \.self) { choice in
                        Button(choice.durationLabel) { engine.settings.matchDuration = choice }
                    }
                } label: {
                    Label(engine.settings.matchDuration.durationLabel, systemImage: "clock")
                }

                Button {
                    engine.startGame()
                } label: {
                    Label("Start Match", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(roster.isEmpty)
            }

            Button(role: .destructive) {
                engine.leave()
            } label: {
                Image(systemName: "xmark.circle")
            }
        }
    }

    // MARK: - Main layout

    private var content: some View {
        HStack(spacing: 0) {
            playerRail
                .frame(width: 260)
            Divider().overlay(.white.opacity(0.15))
            feedPanel
        }
    }

    private var playerRail: some View {
        ScrollView {
            VStack(spacing: 10) {
                if roster.isEmpty {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for players…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)
                }
                ForEach(roster) { player in
                    playerCard(player)
                }
            }
            .padding(12)
        }
    }

    private func playerCard(_ player: Player) -> some View {
        let watching = engine.watchingPlayer == player.name
        return Button {
            engine.watch(watching ? nil : player.name)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle()
                        .fill(player.isConnected ? (player.isAlive ? Color.green : Color.red) : Color.gray)
                        .frame(width: 9, height: 9)
                    Text(player.name.displayCallSign)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if watching {
                        Text("● LIVE")
                            .font(.caption2.bold())
                            .foregroundStyle(.red)
                    }
                }
                GeometryReader { geo in
                    let frac = CGFloat(player.hp) / CGFloat(max(1, engine.settings.maxHP))
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule()
                            .fill(frac > 0.5 ? Color.green : frac > 0.25 ? Color.orange : Color.red)
                            .frame(width: geo.size.width * max(0, frac))
                    }
                }
                .frame(height: 6)
                HStack {
                    Text("\(player.hp) HP")
                    Spacer()
                    Text("\(player.kills) K · \(player.deaths) D")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(watching ? Color.red.opacity(0.15) : Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(watching ? Color.red : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Camera feed

    private var feedPanel: some View {
        ZStack {
            if let frame = engine.spectatorFrame, let watching = engine.watchingPlayer {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        Label("LIVE · \(watching.displayCallSign.uppercased())", systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption.bold())
                            .padding(6)
                            .background(.red, in: Capsule())
                            .padding(10)
                    }
            } else if let watching = engine.watchingPlayer {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Connecting to \(watching.displayCallSign)'s viewfinder…")
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "tv")
                        .font(.system(size: 56, weight: .thin))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("Click a player to watch their view")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { killFeedStrip }
    }

    private var killFeedStrip: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(engine.killFeed.prefix(4)) { event in
                Text("\(event.killer.displayCallSign)  ⚡︎  \(event.victim.displayCallSign)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.black.opacity(0.5))
    }

    // MARK: - Summary

    private func summary(_ result: MatchResult) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Text(result.isDraw ? "DRAW" : "🏆 \(result.winner?.name.displayCallSign.uppercased() ?? "") WINS")
                .font(.system(size: 40, weight: .black, design: .rounded))
                .foregroundStyle(result.isDraw ? .white : .yellow)

            VStack(spacing: 8) {
                ForEach(Array(result.standings.enumerated()), id: \.element.id) { index, player in
                    HStack(spacing: 14) {
                        Text("\(index + 1)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(index == 0 ? .yellow : .secondary)
                            .frame(width: 28)
                        Text(player.name.displayCallSign)
                            .font(.headline)
                        Spacer()
                        Text("\(player.kills) K")
                            .font(.subheadline.monospacedDigit())
                        Text("\(player.deaths) D")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(player.kdString)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxWidth: 460)

            Button {
                engine.returnToLobby()
            } label: {
                Label("Back to Lobby", systemImage: "arrow.uturn.left")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }
}
