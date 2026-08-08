import SwiftUI

/// The laptop's control room: match setup with full host parity in the lobby,
/// a broadcast-style live view (standings rail, camera feed, kill feed) during
/// play, and final standings after. Click a player to watch their viewfinder.
struct SpectatorView: View {
    @EnvironmentObject private var engine: GameEngine

    @ScaledMetric(relativeTo: .largeTitle) private var winnerTitleSize: CGFloat = 40
    @ScaledMetric(relativeTo: .largeTitle) private var emptyGlyphSize: CGFloat = 56

    /// Alphabetical while the lobby fills; live standings once the match runs.
    private var roster: [Player] {
        let players = engine.opponents
        guard engine.phase != .lobby else { return players }
        return players.sorted { a, b in
            if a.kills != b.kills { return a.kills > b.kills }
            if a.deaths != b.deaths { return a.deaths < b.deaths }
            return a.name < b.name
        }
    }

    var body: some View {
        ZStack {
            Color.echoBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.md)
                Divider().overlay(Color.echoHairline)
                if engine.phase == .summary, let result = engine.matchResult {
                    summary(result)
                } else {
                    HStack(spacing: 0) {
                        playerRail
                            .frame(width: 280)
                        Divider().overlay(Color.echoHairline)
                        if engine.phase == .lobby {
                            if !engine.isHost {
                                waitingForHostPanel
                            } else if engine.externalMatchInProgress {
                                matchInProgressPanel
                            } else {
                                setupPanel
                            }
                        } else {
                            feedPanel
                        }
                    }
                }
            }
        }
        .foregroundStyle(Color.echoText)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.lg) {
            HStack(spacing: Space.sm) {
                Image(systemName: "tv")
                    .foregroundStyle(Color.echoPrimary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("ECHO")
                        .font(.headline.weight(.black))
                        .tracking(2)
                    Text("GAME MASTER")
                        .font(.caption2)
                        .tracking(2)
                        .foregroundStyle(Color.echoTextSecondary)
                }
            }

            if engine.phase == .playing {
                Text(engine.matchRemaining.clockString)
                    .font(.title2.monospacedDigit().bold())
                    .foregroundStyle(engine.matchRemaining < 30 ? Color.echoDanger : Color.echoText)
                    .accessibilityLabel("Time remaining \(engine.matchRemaining.clockString)")
            }

            Spacer()

            Label("\(roster.count)", systemImage: "iphone.gen3")
                .font(.callout.monospacedDigit())
                .foregroundStyle(Color.echoTextSecondary)
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.xs)
                .background(Color.echoSurface, in: Capsule())
                .accessibilityLabel("\(roster.count) players connected")

            Button(role: .destructive) {
                engine.leave()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.title3)
            }
            .accessibilityLabel("Close the game")
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption2.bold())
            .tracking(1)
            .foregroundStyle(Color.echoTextSecondary)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xxs)
            .background(Color.echoSurface, in: Capsule())
    }

    // MARK: - Lobby: match setup (host parity with LobbyView)

    private var setupPanel: some View {
        ScrollView {
            VStack(spacing: Space.xl) {
                VStack(spacing: Space.xs) {
                    Text("MATCH SETUP")
                        .font(.caption.bold())
                        .tracking(3)
                        .foregroundStyle(Color.echoTextSecondary)
                    Text("Players join from their phones — the roster fills itself.")
                        .font(.caption2)
                        .foregroundStyle(Color.echoTextTertiary)
                }

                VStack(spacing: Space.lg) {
                    settingRow(label: "Match length", icon: "timer") {
                        Picker("Match length", selection: Binding(
                            get: { engine.settings.matchDuration },
                            set: { engine.settings.matchDuration = $0 }
                        )) {
                            ForEach(GameSettings.durationChoices, id: \.self) { seconds in
                                Text(seconds.durationLabel).tag(seconds)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    settingRow(label: "Player limit — \(engine.settings.maxPlayers)", icon: "person.3") {
                        Slider(
                            value: Binding(
                                get: { Double(engine.settings.maxPlayers) },
                                set: {
                                    engine.settings.maxPlayers = Int($0.rounded())
                                    engine.refreshLobbyAdvertisement()
                                }
                            ),
                            in: 2...8,
                            step: 1
                        )
                        .tint(Color.echoPrimary)
                    }

                    Divider().overlay(Color.echoHairline)

                    HStack(spacing: Space.xl) {
                        statChip("scope", String(format: "%.0f m", engine.settings.weaponRange))
                        statChip("angle", String(format: "%.0f°", engine.settings.aimConeDegrees))
                    }
                    .font(.caption)
                    .foregroundStyle(Color.echoTextSecondary)
                }
                .padding(Space.xl)
                .background(Color.echoSurface, in: RoundedRectangle(cornerRadius: Radius.lg))
                .frame(maxWidth: 560)

                Button {
                    engine.startGame()
                } label: {
                    Label(roster.isEmpty ? "Waiting for players…" : "Start Match",
                          systemImage: "play.fill")
                        .font(.headline)
                        .frame(minWidth: 260)
                        .foregroundStyle(Color.echoOnPrimary)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color.echoPrimary)
                .disabled(roster.isEmpty)

                if !roster.isEmpty {
                    Text("\(roster.count) in — you can keep waiting or start now.")
                        .font(.caption2)
                        .foregroundStyle(Color.echoTextTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(Space.xxl)
        }
    }

    /// Joined someone else's lobby as a pure spectator: the host runs the
    /// match; we watch. No Start button exists in this mode.
    private var waitingForHostPanel: some View {
        VStack(spacing: Space.md) {
            ProgressView()
            Text("Waiting for the host to start the match…")
                .foregroundStyle(Color.echoTextSecondary)
            Text("You're spectating — the host controls settings and start. Once the match runs, click a player to watch their view.")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.echoTextTertiary)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A real match was already running when this screen opened. The laptop
    /// never joins or takes over a live game — it waits for the end.
    private var matchInProgressPanel: some View {
        VStack(spacing: Space.lg) {
            Image(systemName: "lock.fill")
                .font(.system(size: emptyGlyphSize, weight: .thin))
                .foregroundStyle(Color.echoTextTertiary)
                .accessibilityHidden(true)
            Text("MATCH IN PROGRESS")
                .font(.caption.bold())
                .tracking(3)
                .foregroundStyle(Color.echoTextSecondary)
            Text("A game with \(engine.externalMatchPlayers) players is already running on the phones. The laptop can't join or take over a live match — this screen unlocks the moment it ends.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.echoTextSecondary)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func settingRow(label: String, icon: String, @ViewBuilder control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Label(label, systemImage: icon)
                .font(.caption.bold())
                .foregroundStyle(Color.echoTextSecondary)
            control()
        }
    }

    private func statChip(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
    }

    // MARK: - Player rail

    private var playerRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                Text(engine.phase == .lobby ? "ROSTER" : "STANDINGS")
                    .font(.caption2.bold())
                    .tracking(2)
                    .foregroundStyle(Color.echoTextTertiary)
                    .padding(.horizontal, Space.xs)

                if roster.isEmpty {
                    VStack(spacing: Space.sm) {
                        ProgressView()
                        Text("Waiting for players…")
                            .font(.caption)
                            .foregroundStyle(Color.echoTextSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, Space.xxl)
                }
                ForEach(Array(roster.enumerated()), id: \.element.id) { index, player in
                    playerCard(player, rank: engine.phase == .lobby ? nil : index + 1)
                }
            }
            .padding(Space.md)
        }
    }

    private func playerCard(_ player: Player, rank: Int?) -> some View {
        let watching = engine.watchingPlayer == player.name
        return Button {
            engine.watch(watching ? nil : player.name)
        } label: {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    if let rank {
                        Text("\(rank)")
                            .font(.caption.monospacedDigit().bold())
                            .foregroundStyle(rank == 1 ? Color.echoAccent : Color.echoTextTertiary)
                            .frame(width: 16)
                    }
                    Circle()
                        .fill(statusColor(for: player))
                        .frame(width: 9, height: 9)
                        .accessibilityLabel(statusLabel(for: player))
                    Text(player.name.displayCallSign)
                        .font(.headline)
                        .lineLimit(1)
                    Label(player.role.label.uppercased(), systemImage: player.role.symbol)
                        .font(.caption2)
                        .foregroundStyle(Color.echoTextTertiary)
                    Spacer()
                    if watching {
                        Label("LIVE", systemImage: "record.circle.fill")
                            .font(.caption2.bold())
                            .foregroundStyle(Color.echoPrimary)
                    }
                }
                GeometryReader { geo in
                    let frac = CGFloat(player.hp) / CGFloat(max(1, player.role.maxHP))
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
        .hoverEffect(.highlight)
        .accessibilityHint(watching ? "Stops watching this player" : "Watches this player's camera")
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
            if let frame = engine.spectatorFrame, engine.watchingPlayer != nil {
                GeometryReader { geo in
                    let fit = Self.fittedRect(image: frame.size, in: geo.size)
                    Image(uiImage: frame)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Their HUD, redrawn: enemy tags pinned to the frame and
                    // the crosshair — nothing else from their chrome.
                    if let overlay = engine.spectatorOverlay {
                        ForEach(overlay.tags, id: \.name) { tag in
                            EnemyTag(name: tag.name, hpFraction: CGFloat(tag.hp))
                                .position(x: fit.minX + CGFloat(tag.x) * fit.width,
                                          y: fit.minY + CGFloat(tag.y) * fit.height - 40)
                        }
                        spectatedCrosshair(overlay, center: CGPoint(x: fit.midX, y: fit.midY))
                    }
                }
                .clipped()
                .allowsHitTesting(false)
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
        .overlay(alignment: .top) { watchedStatusBar }
        .overlay(alignment: .bottom) { killFeedStrip }
    }

    /// Where a scaledToFit image actually lands inside its container.
    private static func fittedRect(image: CGSize, in container: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / image.width, container.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// The spectated player's crosshair: hot when they're locked, faint when
    /// they're scanning — same semantics as their reticle.
    @ViewBuilder
    private func spectatedCrosshair(_ overlay: SpectatorOverlayState, center: CGPoint) -> some View {
        let locked = overlay.lockedTarget != nil
        VStack(spacing: Space.xs) {
            Image(systemName: locked ? "scope" : "plus")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(locked ? Color.echoPrimary : Color.echoText.opacity(Alpha.muted))
            if let target = overlay.lockedTarget {
                Text("LOCKED · \(target.uppercased())")
                    .font(.caption2.bold())
                    .foregroundStyle(Color.echoPrimary)
            }
        }
        .position(center)
        .animation(.easeOut(duration: 0.15), value: locked)
    }

    /// Who's on air and how they're doing, pinned over the feed.
    @ViewBuilder
    private var watchedStatusBar: some View {
        if let watching = engine.watchingPlayer, let player = engine.players[watching] {
            HStack(spacing: Space.md) {
                Label("LIVE · \(watching.displayCallSign.uppercased())",
                      systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.bold())
                    .foregroundStyle(Color.echoOnPrimary)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.xs)
                    .background(Color.echoPrimary, in: Capsule())
                Spacer()
                Text("\(player.hp) HP · \(player.kills) K · \(player.deaths) D")
                    .font(.caption.monospacedDigit().bold())
                Capsule()
                    .fill(Color.echoHealth(CGFloat(player.hp) / CGFloat(max(1, player.role.maxHP))))
                    .frame(width: 72 * max(0, CGFloat(player.hp) / CGFloat(max(1, player.role.maxHP))), height: 6)
                    .frame(width: 72, alignment: .leading)
                    .background(Color.echoText.opacity(Alpha.subtle), in: Capsule())
            }
            .padding(Space.md)
            .background(Color.echoBackground.opacity(Alpha.strong))
        }
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

            chip(result.duration.durationLabel)

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
