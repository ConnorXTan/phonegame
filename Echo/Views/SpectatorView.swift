import SwiftUI

/// The laptop's control room: live roster with HP/K/D, click a player to
/// watch their viewfinder, host controls (mode, duration, Start), kill feed,
/// and final standings. Covers lobby, playing, and summary phases.
struct SpectatorView: View {
    @EnvironmentObject private var engine: GameEngine

    @ScaledMetric(relativeTo: .largeTitle) private var winnerTitleSize: CGFloat = 40
    @ScaledMetric(relativeTo: .largeTitle) private var emptyGlyphSize: CGFloat = 56

    private var roster: [Player] { engine.opponents }

    var body: some View {
        ZStack {
            Color.echoBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                    .padding(.horizontal)
                    .padding(.vertical, Space.md)
                Divider().overlay(Color.echoHairline)
                if engine.phase == .summary, let result = engine.matchResult {
                    summary(result)
                } else {
                    content
                }
            }
        }
        .foregroundStyle(Color.echoText)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.lg) {
            Label("ECHO · SPECTATOR", systemImage: "tv")
                .font(.headline.weight(.black))
                .tracking(1)

            if engine.phase == .playing {
                Text(engine.matchRemaining.clockString)
                    .font(.title3.monospacedDigit().bold())
                    .foregroundStyle(engine.matchRemaining < 30 ? Color.echoDanger : Color.echoText)
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
                        .foregroundStyle(Color.echoOnPrimary)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.echoPrimary)
                .disabled(roster.isEmpty)
            }

            Button(role: .destructive) {
                engine.leave()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .accessibilityLabel("Leave")
        }
    }

    // MARK: - Main layout

    private var content: some View {
        HStack(spacing: 0) {
            playerRail
                .frame(width: 260)
            Divider().overlay(Color.echoHairline)
            feedPanel
        }
    }

    private var playerRail: some View {
        ScrollView {
            VStack(spacing: Space.md) {
                if roster.isEmpty {
                    VStack(spacing: Space.sm) {
                        ProgressView()
                        Text("Waiting for players…")
                            .font(.caption)
                            .foregroundStyle(Color.echoTextSecondary)
                    }
                    .padding(.top, Space.xxl)
                }
                ForEach(roster) { player in
                    playerCard(player)
                }
            }
            .padding(Space.md)
        }
    }

    private func playerCard(_ player: Player) -> some View {
        let watching = engine.watchingPlayer == player.name
        return Button {
            engine.watch(watching ? nil : player.name)
        } label: {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    Circle()
                        .fill(statusColor(for: player))
                        .frame(width: 9, height: 9)
                        .accessibilityLabel(statusLabel(for: player))
                    Text(player.name.displayCallSign)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if watching {
                        Label("LIVE", systemImage: "record.circle.fill")
                            .font(.caption2.bold())
                            .foregroundStyle(Color.echoPrimary)
                    }
                }
                GeometryReader { geo in
                    let frac = CGFloat(player.hp) / CGFloat(max(1, engine.settings.maxHP))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.echoText.opacity(Alpha.subtle))
                        Capsule()
                            .fill(Color.echoHealth(frac))
                            .frame(width: geo.size.width * max(0, frac))
                    }
                }
                .frame(height: 6)
                .accessibilityHidden(true)   // the HP figure below carries this
                HStack {
                    Text("\(player.hp) HP")
                    Spacer()
                    Text("\(player.kills) K · \(player.deaths) D")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.echoTextSecondary)
            }
            .padding(Space.md)
            .background(watching ? Color.echoPrimary.opacity(Alpha.surface) : Color.echoSurface,
                        in: RoundedRectangle(cornerRadius: Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .stroke(watching ? Color.echoPrimary : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func statusColor(for player: Player) -> Color {
        guard player.isConnected else { return .echoInert }
        return player.isAlive ? .echoSecondary : .echoDanger
    }

    private func statusLabel(for player: Player) -> String {
        guard player.isConnected else { return "Disconnected" }
        return player.isAlive ? "Alive" : "Down"
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
                        Label("LIVE · \(watching.displayCallSign.uppercased())",
                              systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption.bold())
                            .foregroundStyle(Color.echoOnPrimary)
                            .padding(Space.sm)
                            .background(Color.echoPrimary, in: Capsule())
                            .padding(Space.md)
                    }
            } else if let watching = engine.watchingPlayer {
                VStack(spacing: Space.md) {
                    ProgressView()
                    Text("Connecting to \(watching.displayCallSign)'s viewfinder…")
                        .foregroundStyle(Color.echoTextSecondary)
                }
            } else {
                VStack(spacing: Space.md) {
                    Image(systemName: "tv")
                        .font(.system(size: emptyGlyphSize, weight: .thin))
                        .foregroundStyle(Color.echoTextTertiary)
                        .accessibilityHidden(true)
                    Text("Click a player to watch their view")
                        .foregroundStyle(Color.echoTextSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { killFeedStrip }
    }

    private var killFeedStrip: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            ForEach(engine.killFeed.prefix(4)) { event in
                (
                    Text(event.killer.displayCallSign)
                    + Text("  \(Image(systemName: "bolt.fill"))  ")
                    + Text(event.victim.displayCallSign)
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.echoTextSecondary)
                .accessibilityLabel("\(event.killer.displayCallSign) tagged \(event.victim.displayCallSign)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.md)
        .background(Color.echoBackground.opacity(Alpha.strong))
    }

    // MARK: - Summary

    private func summary(_ result: MatchResult) -> some View {
        VStack(spacing: Space.lg) {
            Spacer()
            winnerHeadline(result)
                .font(.system(size: winnerTitleSize, weight: .black, design: .rounded))
                .foregroundStyle(result.isDraw ? Color.echoText : Color.echoAccent)

            VStack(spacing: Space.sm) {
                ForEach(Array(result.standings.enumerated()), id: \.element.id) { index, player in
                    HStack(spacing: Space.lg) {
                        Text("\(index + 1)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(index == 0 ? Color.echoAccent : Color.echoTextSecondary)
                            .frame(width: 28)
                        Text(player.name.displayCallSign)
                            .font(.headline)
                        Spacer()
                        Text("\(player.kills) K")
                            .font(.subheadline.monospacedDigit())
                        Text("\(player.deaths) D")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Color.echoTextSecondary)
                        Text(player.kdString)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.echoTextSecondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.sm)
                    .background(Color.echoSurface, in: RoundedRectangle(cornerRadius: Radius.md))
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: 460)

            Button {
                engine.returnToLobby()
            } label: {
                Label("Back to Lobby", systemImage: "arrow.uturn.left")
                    .foregroundStyle(Color.echoOnPrimary)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.echoPrimary)
            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private func winnerHeadline(_ result: MatchResult) -> some View {
        if result.isDraw {
            Text("DRAW")
        } else {
            Label("\(result.winner?.name.displayCallSign.uppercased() ?? "") WINS",
                  systemImage: "trophy.fill")
        }
    }
}
