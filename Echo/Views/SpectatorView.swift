import SwiftUI

/// The laptop's control room: match setup with full host parity in the lobby,
/// a broadcast-style live view (standings rail, camera feed, kill feed) during
/// play, and final standings after. Click a player to watch their viewfinder.
struct SpectatorView: View {
    @EnvironmentObject private var engine: GameEngine

    @ScaledMetric(relativeTo: .largeTitle) private var winnerTitleSize: CGFloat = 40
    @ScaledMetric(relativeTo: .largeTitle) private var emptyGlyphSize: CGFloat = 56
    @ScaledMetric(relativeTo: .caption) private var killSkullSize: CGFloat = 14
    @ScaledMetric(relativeTo: .headline) private var reviewSkullSize: CGFloat = 18

    // Kill review playback: which clip is open and when playback started
    // (drives the flipbook clock). Frames decode per tick, not up front —
    // ~7 s of 720p bitmaps would be hundreds of MB held decoded.
    @State private var reviewClipID: UUID?
    @State private var reviewStarted = Date()
    private static let clipFPS = Double(ClipEncoder.framesPerSecond)
    @State private var showManageGallery = false

    private var reviewClip: KillClip? {
        reviewClipID.flatMap { id in engine.killClips.first { $0.id == id } }
    }

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
            Color.ltnBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.md)
                Divider().overlay(Color.ltnHairline)
                if engine.phase == .summary, let result = engine.matchResult {
                    summary(result)
                        .overlay {
                            if let clip = reviewClip { replayOverlay(clip) }
                        }
                } else {
                    HStack(spacing: 0) {
                        playerRail
                            .frame(width: 280)
                        Divider().overlay(Color.ltnHairline)
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
        .font(.app(.body))
        .foregroundStyle(Color.ltnText)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.lg) {
            HStack(spacing: Space.sm) {
                Image(systemName: "tv")
                    .foregroundStyle(Color.ltnPrimary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("LTN")
                        .font(.appBold(.headline))
                        .tracking(2)
                    Text("GAME MASTER")
                        .font(.app(.caption2))
                        .tracking(2)
                        .foregroundStyle(Color.ltnTextSecondary)
                }
            }

            if engine.phase == .playing {
                Text(engine.matchRemaining.clockString)
                    .font(.app(.title2).monospacedDigit().bold())
                    .foregroundStyle(engine.matchRemaining < 30 ? Color.ltnDanger : Color.ltnText)
                    .accessibilityLabel("Time remaining \(engine.matchRemaining.clockString)")
                if engine.settings.teamPlay {
                    teamScoreChip
                }
            }

            Spacer()

            if engine.phase == .playing, engine.isHost {
                Button {
                    engine.endMatchEarly()
                } label: {
                    Label("End Match", systemImage: "flag.checkered")
                }
                .buttonStyle(.bordered)
                .tint(Color.ltnDanger)
                .accessibilityHint("Ends the match now; final standings use current tallies")
            }

            Label("\(roster.count)", systemImage: "iphone.gen3")
                .font(.app(.callout).monospacedDigit())
                .foregroundStyle(Color.ltnTextSecondary)
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.xs)
                .background(Color.ltnSurface, in: Capsule())
                .accessibilityLabel("\(roster.count) players connected")

            Button {
                showManageGallery = true
            } label: {
                Image(systemName: "photo.stack")
                    .font(.title3)
            }
            .accessibilityLabel("Manage the killcam gallery")
            .sheet(isPresented: $showManageGallery) { ManageGalleryView() }

            Button(role: .destructive) {
                engine.leave()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.app(.title3))
            }
            .accessibilityLabel("Close the game")
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.appBold(.caption2))
            .tracking(1)
            .foregroundStyle(Color.ltnTextSecondary)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xxs)
            .background(Color.ltnSurface, in: Capsule())
    }

    /// The broadcast has no side, so team colors are absolute here: alpha
    /// blue, bravo red — the names carry the meaning either way.
    private var teamScoreChip: some View {
        HStack(spacing: Space.xs) {
            Text("ALPHA \(engine.teamKills(.alpha))")
                .foregroundStyle(Color.ltnTeamAbsolute(.alpha))
            Text("·")
                .foregroundStyle(Color.ltnTextTertiary)
            Text("BRAVO \(engine.teamKills(.bravo))")
                .foregroundStyle(Color.ltnTeamAbsolute(.bravo))
        }
        .font(.appBold(.caption2).monospacedDigit())
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xxs)
        .background(Color.ltnSurface, in: Capsule())
        .accessibilityLabel("Team alpha \(engine.teamKills(.alpha)), team bravo \(engine.teamKills(.bravo))")
    }

    // MARK: - Lobby: match setup (host parity with LobbyView)

    private var setupPanel: some View {
        ScrollView {
            VStack(spacing: Space.xl) {
                VStack(spacing: Space.xs) {
                    Text("MATCH SETUP")
                        .font(.appBold(.caption))
                        .tracking(3)
                        .foregroundStyle(Color.ltnTextSecondary)
                    Text("Players join from their phones — the roster fills itself.")
                        .font(.app(.caption2))
                        .foregroundStyle(Color.ltnTextTertiary)
                }

                VStack(spacing: Space.lg) {
                    settingRow(label: "Mode — \(engine.settings.teamPlay ? "two teams" : "free-for-all")",
                               icon: "flag.2.crossed") {
                        Picker("Mode", selection: Binding(
                            get: { engine.settings.teamPlay },
                            set: { engine.setTeamPlay($0) }
                        )) {
                            Text("Solo").tag(false)
                            Text("Teams").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }

                    settingRow(label: "Match length", icon: "timer") {
                        Picker("Match length", selection: Binding(
                            get: { engine.settings.matchDuration },
                            set: {
                                engine.settings.matchDuration = $0
                                engine.hostSettingsChanged()
                            }
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
                                    engine.hostSettingsChanged()
                                }
                            ),
                            in: 2...8,
                            step: 1
                        )
                        .tint(Color.ltnPrimary)
                    }

                    Divider().overlay(Color.ltnHairline)

                    HStack(spacing: Space.xl) {
                        statChip("scope", String(format: "%.0f m", engine.settings.weaponRange))
                        statChip("angle", String(format: "%.0f°", engine.settings.aimConeDegrees))
                    }
                    .font(.app(.caption))
                    .foregroundStyle(Color.ltnTextSecondary)
                }
                .padding(Space.xl)
                .background(Color.ltnSurface, in: RoundedRectangle(cornerRadius: Radius.lg))
                .frame(maxWidth: 560)

                Button {
                    engine.startGame()
                } label: {
                    Label(roster.count < 2 ? "Waiting for players…" : "Start Match",
                          systemImage: "play.fill")
                        .font(.app(.headline))
                        .frame(minWidth: 260)
                        .foregroundStyle(Color.ltnOnPrimary)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color.ltnPrimary)
                .disabled(roster.count < 2)

                if !roster.isEmpty {
                    Text(roster.count < 2 ? "Matches need at least two players." : "\(roster.count) in — you can keep waiting or start now.")
                        .font(.app(.caption2))
                        .foregroundStyle(Color.ltnTextTertiary)
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
                .foregroundStyle(Color.ltnTextSecondary)
            Text("You're spectating — the host controls settings and start. Once the match runs, click a player to watch their view.")
                .font(.app(.caption2))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.ltnTextTertiary)
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
                .foregroundStyle(Color.ltnTextTertiary)
                .accessibilityHidden(true)
            Text("MATCH IN PROGRESS")
                .font(.appBold(.caption))
                .tracking(3)
                .foregroundStyle(Color.ltnTextSecondary)
            Text("A game with \(engine.externalMatchPlayers) players is already running on the phones. The laptop can't join or take over a live match — this screen unlocks the moment it ends.")
                .font(.app(.callout))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.ltnTextSecondary)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func settingRow(label: String, icon: String, @ViewBuilder control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Label(label, systemImage: icon)
                .font(.appBold(.caption))
                .foregroundStyle(Color.ltnTextSecondary)
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
                    .font(.appBold(.caption2))
                    .tracking(2)
                    .foregroundStyle(Color.ltnTextTertiary)
                    .padding(.horizontal, Space.xs)

                if roster.isEmpty {
                    VStack(spacing: Space.sm) {
                        ProgressView()
                        Text("Waiting for players…")
                            .font(.app(.caption))
                            .foregroundStyle(Color.ltnTextSecondary)
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

    /// In the lobby the rail is a roster, not a channel picker — there's no
    /// camera to watch until the match starts, so cards only become watch
    /// buttons in play. Spectators wait it out like players do on the phone.
    @ViewBuilder
    private func playerCard(_ player: Player, rank: Int?) -> some View {
        let watching = engine.watchingPlayer == player.name
        if engine.phase == .lobby {
            playerCardBody(player, rank: rank, watching: watching)
        } else {
            Button {
                engine.watch(watching ? nil : player.name)
            } label: {
                playerCardBody(player, rank: rank, watching: watching)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityHint(watching ? "Stops watching this player" : "Watches this player's camera")
        }
    }

    private func playerCardBody(_ player: Player, rank: Int?, watching: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                if let rank {
                    Text("\(rank)")
                        .font(.app(.caption).monospacedDigit().bold())
                        .foregroundStyle(rank == 1 ? Color.ltnAccent : Color.ltnTextTertiary)
                        .frame(width: 16)
                }
                Circle()
                    .fill(statusColor(for: player))
                    .frame(width: 9, height: 9)
                    .accessibilityLabel(statusLabel(for: player))
                Text(player.name.displayCallSign)
                    .font(.app(.headline))
                    .lineLimit(1)
                Label(player.role.label.uppercased(), systemImage: player.role.symbol)
                    .font(.app(.caption2))
                    .foregroundStyle(Color.ltnTextTertiary)
                if engine.settings.teamPlay, let team = player.team {
                    Text(team.displayName.uppercased())
                        .font(.appBold(.caption2))
                        .tracking(1)
                        .foregroundStyle(Color.ltnTeamAbsolute(team))
                }
                Spacer()
                if watching {
                    Label("LIVE", systemImage: "record.circle.fill")
                        .font(.appBold(.caption2))
                        .foregroundStyle(Color.ltnPrimary)
                }
            }
            GeometryReader { geo in
                let frac = CGFloat(player.hp) / CGFloat(max(1, player.role.maxHP))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.ltnText.opacity(Alpha.subtle))
                    Capsule()
                        .fill(Color.ltnHealth(frac))
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
            .font(.app(.caption2).monospacedDigit())
            .foregroundStyle(Color.ltnTextSecondary)
        }
        .padding(Space.md)
        .background(watching ? Color.ltnPrimary.opacity(Alpha.surface) : Color.ltnSurface,
                    in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .stroke(watching ? Color.ltnPrimary : .clear, lineWidth: 1.5)
        )
    }

    private func statusColor(for player: Player) -> Color {
        guard player.isConnected else { return .ltnInert }
        return player.isAlive ? .ltnSecondary : .ltnDanger
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
                        .foregroundStyle(Color.ltnTextSecondary)
                }
            } else {
                VStack(spacing: Space.md) {
                    Image(systemName: "tv")
                        .font(.system(size: emptyGlyphSize, weight: .thin))
                        .foregroundStyle(Color.ltnTextTertiary)
                        .accessibilityHidden(true)
                    Text("Click a player to watch their view")
                        .foregroundStyle(Color.ltnTextSecondary)
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

    /// The spectated player's aim reference: a neutral crosshair only — the
    /// hit markers and health bars carry the drama, no lock callout.
    private func spectatedCrosshair(_ overlay: SpectatorOverlayState, center: CGPoint) -> some View {
        Image(systemName: "plus")
            .font(.system(size: 40, weight: .thin))
            .foregroundStyle(Color.ltnText.opacity(Alpha.muted))
            .position(center)
    }

    /// Who's on air and how they're doing, pinned over the feed.
    @ViewBuilder
    private var watchedStatusBar: some View {
        if let watching = engine.watchingPlayer, let player = engine.players[watching] {
            HStack(spacing: Space.md) {
                Label("LIVE · \(watching.displayCallSign.uppercased())",
                      systemImage: "dot.radiowaves.left.and.right")
                    .font(.appBold(.caption))
                    .foregroundStyle(Color.ltnOnPrimary)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.xs)
                    .background(Color.ltnPrimary, in: Capsule())
                Spacer()
                Text("\(player.hp) HP · \(player.kills) K · \(player.deaths) D")
                    .font(.app(.caption).monospacedDigit().bold())
                Capsule()
                    .fill(Color.ltnHealth(CGFloat(player.hp) / CGFloat(max(1, player.role.maxHP))))
                    .frame(width: 72 * max(0, CGFloat(player.hp) / CGFloat(max(1, player.role.maxHP))), height: 6)
                    .frame(width: 72, alignment: .leading)
                    .background(Color.ltnText.opacity(Alpha.subtle), in: Capsule())
            }
            .padding(Space.md)
            .background(Color.ltnBackground.opacity(Alpha.strong))
        }
    }

    private var killFeedStrip: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            ForEach(engine.killFeed.prefix(4)) { event in
                HStack(spacing: Space.sm) {
                    Text(event.killer.displayCallSign)
                    Image(art: .killSkull)
                        .resizable()
                        .scaledToFit()
                        .frame(height: killSkullSize)
                    Text(event.victim.displayCallSign)
                }
                .font(.app(.caption).monospacedDigit())
                .foregroundStyle(Color.ltnTextSecondary)
                .accessibilityLabel("\(event.killer.displayCallSign) tagged \(event.victim.displayCallSign)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.md)
        .background(Color.ltnBackground.opacity(Alpha.strong))
    }

    // MARK: - Summary

    private func summary(_ result: MatchResult) -> some View {
        VStack(spacing: Space.lg) {
            Spacer()
            winnerHeadline(result)
                .font(.appBold(fixedSize: winnerTitleSize))
                .foregroundStyle(result.isDraw ? Color.ltnText : Color.ltnAccent)

            chip((engine.settings.teamPlay ? "TEAMS · " : "") + result.duration.durationLabel)

            VStack(spacing: Space.sm) {
                ForEach(Array(result.standings.enumerated()), id: \.element.id) { index, player in
                    HStack(spacing: Space.lg) {
                        Text("\(index + 1)")
                            .font(.app(.headline).monospacedDigit())
                            .foregroundStyle(index == 0 ? Color.ltnAccent : Color.ltnTextSecondary)
                            .frame(width: 28)
                        if result.teamPlay, let team = player.team {
                            Circle()
                                .fill(Color.ltnTeamAbsolute(team))
                                .frame(width: 8, height: 8)
                                .accessibilityLabel("Team \(team.displayName)")
                        }
                        Text(player.name.displayCallSign)
                            .font(.app(.headline))
                        Spacer()
                        Text("\(player.kills) K")
                            .font(.app(.subheadline).monospacedDigit())
                        Text("\(player.deaths) D")
                            .font(.app(.subheadline).monospacedDigit())
                            .foregroundStyle(Color.ltnTextSecondary)
                        Text(player.kdString)
                            .font(.app(.caption).monospacedDigit())
                            .foregroundStyle(Color.ltnTextSecondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.sm)
                    .background(Color.ltnSurface, in: RoundedRectangle(cornerRadius: Radius.md))
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: 460)

            if !engine.killClips.isEmpty {
                killReviewRail
            }

            Button {
                engine.returnToLobby()
            } label: {
                Label("Back to Lobby", systemImage: "arrow.uturn.left")
                    .foregroundStyle(Color.ltnOnPrimary)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.ltnPrimary)
            Spacer()
        }
        .padding()
    }

    // MARK: - Kill review

    private var killReviewRail: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("KILL REVIEW")
                .font(.appBold(.caption2))
                .tracking(2)
                .foregroundStyle(Color.ltnTextTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.md) {
                    ForEach(engine.killClips) { clip in
                        killClipCard(clip)
                    }
                }
            }
        }
        .frame(maxWidth: 560)
    }

    private func killClipCard(_ clip: KillClip) -> some View {
        Button {
            openReview(clip)
        } label: {
            VStack(spacing: Space.xs) {
                ZStack {
                    if let first = clip.frames.first, let thumb = UIImage(data: first) {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.ltnSurface
                    }
                    Image(systemName: "play.fill")
                        .font(.title3)
                        .foregroundStyle(Color.ltnText.opacity(Alpha.heavy))
                }
                .frame(width: 96, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                HStack(spacing: Space.xs) {
                    Text(clip.killer.displayCallSign)
                    Image(art: .killSkull)
                        .resizable()
                        .scaledToFit()
                        .frame(height: killSkullSize)
                    Text(clip.victim.displayCallSign)
                }
                .font(.appBold(.caption2))
                .lineLimit(1)
                publishBadge(clip.publishState)
            }
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    @ViewBuilder
    private func publishBadge(_ state: KillClip.PublishState) -> some View {
        switch state {
        case .idle:
            Text("unpublished")
                .font(.app(.caption2))
                .foregroundStyle(Color.ltnTextTertiary)
        case .uploading:
            ProgressView().controlSize(.mini)
        case .published:
            Label("LIVE ON GALLERY", systemImage: "checkmark.circle.fill")
                .font(.appBold(.caption2))
                .foregroundStyle(Color.ltnSecondary)
        case .failed:
            Label("failed — retry", systemImage: "exclamationmark.triangle.fill")
                .font(.app(.caption2))
                .foregroundStyle(Color.ltnWarning)
        }
    }

    private func openReview(_ clip: KillClip) {
        reviewStarted = Date()
        reviewClipID = clip.id
        // First pass plays the clip's sounds in place; loops replay silently.
        for event in clip.sounds {
            DispatchQueue.main.asyncAfter(deadline: .now() + event.offset) { [weak engine] in
                guard engine != nil, reviewClipID == clip.id else { return }
                SoundManager.shared.play(event.name, volume: event.volume, rate: event.rate)
            }
        }
    }

    private func replayOverlay(_ clip: KillClip) -> some View {
        ZStack {
            Color.ltnBackground.opacity(Alpha.opaque).ignoresSafeArea()
            VStack(spacing: Space.lg) {
                HStack(spacing: Space.sm) {
                    Text(clip.killer.displayCallSign)
                    Image(art: .killSkull)
                        .resizable()
                        .scaledToFit()
                        .frame(height: reviewSkullSize)
                    Text(clip.victim.displayCallSign)
                }
                .font(.appBold(.headline))

                TimelineView(.periodic(from: reviewStarted, by: 1.0 / Self.clipFPS)) { context in
                    let elapsed = context.date.timeIntervalSince(reviewStarted)
                    let index = clip.frames.isEmpty ? 0
                        : Int(elapsed * Self.clipFPS) % clip.frames.count
                    if clip.frames.indices.contains(index),
                       let frame = UIImage(data: clip.frames[index]) {
                        GeometryReader { geo in
                            let fit = Self.fittedRect(image: frame.size, in: geo.size)
                            Image(uiImage: frame)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            // The shooter's HUD at that instant: enemy tags
                            // pinned into the frame plus their crosshair.
                            if clip.overlays.indices.contains(index) {
                                let overlay = clip.overlays[index]
                                ForEach(overlay.tags, id: \.name) { tag in
                                    EnemyTag(name: tag.name, hpFraction: CGFloat(tag.hp))
                                        .position(x: fit.minX + CGFloat(tag.x) * fit.width,
                                                  y: fit.minY + CGFloat(tag.y) * fit.height - 40)
                                }
                                spectatedCrosshair(overlay, center: CGPoint(x: fit.midX, y: fit.midY))
                            }
                            // Hit/kill markers replayed with the HUD's art and
                            // bloom-fade, timed off the clip clock.
                            let clipTime = Double(index) / Self.clipFPS
                            ForEach(Array(clip.markers.enumerated()), id: \.offset) { item in
                                let marker = item.element
                                let age = clipTime - marker.offset
                                if age >= 0, age < ClipMarkerEvent.duration {
                                    let fade = age / ClipMarkerEvent.duration
                                    Image(art: marker.isKill ? .hitMarkerKill : .hitMarker)
                                        .renderingMode(.template)
                                        .resizable()
                                        .scaledToFit()
                                        .foregroundStyle(marker.isKill ? Color.ltnDanger : Color.ltnText)
                                        // Same reticle-relative read as the live
                                        // HUD, against this view's 40pt
                                        // crosshair rather than its 74pt ring.
                                        .frame(width: marker.isKill ? 17 : 15,
                                               height: marker.isKill ? 17 : 15)
                                        .opacity(1 - fade)
                                        .scaleEffect(0.8 + 0.4 * fade)
                                        .position(x: fit.midX, y: fit.midY)
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                    }
                }
                .frame(maxWidth: 420, maxHeight: 540)

                HStack(spacing: Space.lg) {
                    switch clip.publishState {
                    case .idle, .failed:
                        Button {
                            engine.publishKillClip(clip.id)
                        } label: {
                            Label(clip.publishState == .failed ? "Retry Publish" : "Publish to Gallery",
                                  systemImage: "arrow.up.circle.fill")
                                .foregroundStyle(Color.ltnOnPrimary)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.ltnPrimary)
                    case .uploading:
                        ProgressView("Publishing…")
                    case .published(let url):
                        Label("Published", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.ltnSecondary)
                        Button {
                            UIPasteboard.general.string = url.absoluteString
                        } label: {
                            Label("Copy Link", systemImage: "link")
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.ltnText)
                    }

                    Button("Close") {
                        reviewClipID = nil
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.ltnText)
                }
            }
            .padding(Space.xl)
        }
    }

    @ViewBuilder
    private func winnerHeadline(_ result: MatchResult) -> some View {
        if result.isDraw {
            Text("DRAW")
        } else if result.teamPlay {
            Label("TEAM \(result.winningTeam?.displayName.uppercased() ?? "") WINS",
                  systemImage: "trophy.fill")
        } else {
            Label("\(result.winner?.name.displayCallSign.uppercased() ?? "") WINS",
                  systemImage: "trophy.fill")
        }
    }
}
