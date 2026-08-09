import SwiftUI

struct LobbyView: View {
    @EnvironmentObject private var engine: GameEngine

    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 32
    /// The spectate eye, sized to sit where a role label would.
    @ScaledMetric(relativeTo: .caption) private var spectateGlyph: CGFloat = 14

    private var roster: [Player] {
        engine.players.values.sorted { $0.name < $1.name }
    }

    private func members(of team: Team) -> [Player] {
        roster.filter { $0.team == team }
    }

    /// Undecided joiners while their teamChange is still in flight.
    private var unassigned: [Player] {
        roster.filter { $0.team == nil }
    }

    /// A 2+ player match where one side is empty has nobody to shoot — hold
    /// Start until someone switches.
    private var teamsLopsided: Bool {
        engine.settings.teamPlay && roster.count >= 2
            && Team.allCases.contains { members(of: $0).isEmpty }
    }

    var body: some View {
        VStack(spacing: Space.xl) {
            HStack {
                Button("Leave", role: .destructive) { engine.leave() }
                Spacer()
                // Connection state, in the token that means connected.
                Label(engine.isHost ? "Hosting" : "Joined",
                      systemImage: "antenna.radiowaves.left.and.right")
                    .font(.app(.callout))
                    .foregroundStyle(Color.echoSecondary)
            }
            .padding(.horizontal)

            // Title and roster ride together — the count belongs to LOBBY, and
            // a full xl gap left the roster floating mid-screen.
            VStack(spacing: Space.md) {
                Text("LOBBY")
                    .font(.appBold(fixedSize: titleSize))
                    .tracking(3)

                rosterBoard
            }

            rolePicker
                .padding(.horizontal)

            if engine.settings.teamPlay {
                teamPicker
                    .padding(.horizontal)
            }

            if engine.isHost {
                // Three steps wider than the gap inside a block, so each label
                // groups with the control under it rather than floating between —
                // and the same gap the outer stack puts between ROLE and MODE.
                VStack(spacing: Space.xl) {
                    VStack(spacing: Space.sm) {
                        sectionLabel("MODE")
                        Picker("Mode", selection: Binding(
                            get: { engine.settings.teamPlay },
                            set: { engine.setTeamPlay($0) }
                        )) {
                            Text("Solo").tag(false)
                            Text("Teams").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(spacing: Space.sm) {
                        sectionLabel("LENGTH")
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

                    VStack(spacing: Space.sm) {
                        HStack {
                            // The label fills the row, so the value lands at the
                            // trailing edge without a spacer between them.
                            sectionLabel("PLAYER LIMIT")
                            Text("\(engine.settings.maxPlayers)")
                                .font(.app(.headline).monospacedDigit())
                                .foregroundStyle(Color.echoText)
                        }
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
                        .tint(Color.echoPrimary)
                        // A thumb position isn't a number, and VoiceOver can't
                        // read the one beside the label.
                        .accessibilityValue("\(engine.settings.maxPlayers) players")
                    }

                    Button {
                        engine.startGame()
                    } label: {
                        Text(roster.count < 2 ? "Start Anyway (solo test)" : "Start Game")
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(Color.echoOnPrimary)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Color.echoPrimary)
                    .disabled(teamsLopsided)

                    if teamsLopsided {
                        Text("Both teams need at least one player.")
                            .font(.app(.caption2))
                            .foregroundStyle(Color.echoTextSecondary)
                    }
                }
                .padding(.horizontal)
            } else {
                VStack(spacing: Space.sm) {
                    ProgressView()
                    Text("Waiting for the host to start…")
                        .foregroundStyle(Color.echoTextSecondary)
                    Text("The host sets the match length.")
                        .font(.app(.caption2))
                        .foregroundStyle(Color.echoTextTertiary)
                }
                .padding(.bottom, Space.md)
            }
        }
        .padding(.vertical)
    }

    // MARK: - Roster

    /// Hand-built rather than a `List`: a list carries its own section insets,
    /// so every roster header sat a step to the right of every other label on
    /// the screen, and its row fill came from the system's gray instead of the
    /// palette. Scrolls only when the roster outgrows the space it's given.
    private var rosterBoard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                if engine.settings.teamPlay {
                    ForEach(Team.allCases) { team in
                        rosterGroup {
                            teamHeader(team)
                        } rows: {
                            if members(of: team).isEmpty {
                                placeholderRow("No one yet")
                            } else {
                                ForEach(Array(members(of: team).enumerated()),
                                        id: \.element.id) { index, player in
                                    if index > 0 { rowSeparator }
                                    playerRow(player)
                                }
                            }
                        }
                    }
                    if !unassigned.isEmpty {
                        rosterGroup {
                            sectionLabel("PICKING A TEAM")
                        } rows: {
                            ForEach(Array(unassigned.enumerated()),
                                    id: \.element.id) { index, player in
                                if index > 0 { rowSeparator }
                                playerRow(player)
                            }
                        }
                    }
                } else {
                    rosterGroup {
                        rosterCount
                    } rows: {
                        ForEach(Array(roster.enumerated()), id: \.element.id) { index, player in
                            if index > 0 { rowSeparator }
                            playerRow(player)
                        }
                        if roster.count < 2 {
                            rowSeparator
                            waitingRow
                        }
                    }
                }
                if !engine.spectators.isEmpty {
                    rosterGroup {
                        sectionLabel("SPECTATORS · \(engine.spectators.count)")
                    } rows: {
                        ForEach(Array(engine.spectators.sorted().enumerated()),
                                id: \.element) { index, name in
                            if index > 0 { rowSeparator }
                            spectatorRow(name)
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// A header on the screen's own margin, with its rows in one card under it.
    private func rosterGroup<Header: View, Rows: View>(
        @ViewBuilder header: () -> Header,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            header()
            VStack(spacing: 0) { rows() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.md)
                .background(Color.echoSurface, in: RoundedRectangle(cornerRadius: Radius.md))
        }
    }

    private func placeholderRow(_ text: String) -> some View {
        Text(text)
            .font(.app(.caption))
            .foregroundStyle(Color.echoTextTertiary)
            .padding(.vertical, Space.md)
    }

    /// The last line of the roster card until someone shows up, so it's built
    /// like a roster row: same `.body` as a player name, and a small spinner
    /// that doesn't stand taller than the names above it.
    private var waitingRow: some View {
        HStack(spacing: Space.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Waiting for players to join…")
                .font(.app(.body))
                .foregroundStyle(Color.echoTextSecondary)
        }
        .padding(.vertical, Space.md)
    }

    /// A rule between roster rows, in the palette's "connected, in play" green
    /// rather than the neutral hairline — this card's contents are the live
    /// players, and it's the only card on the screen that has any.
    private var rowSeparator: some View {
        Rectangle()
            .fill(Color.echoSecondary.opacity(Alpha.muted))
            .frame(height: 1)
    }

    // MARK: - Settings

    /// Everyone picks their own loadout while waiting; the choice broadcasts
    /// so the whole roster shows it. The loadout numbers ride the label's own
    /// line — they describe the selection, so they don't need a row of their own
    /// under the control.
    private var rolePicker: some View {
        VStack(spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("ROLE")
                roleStats
            }
            Picker("Role", selection: Binding(
                get: { engine.myRole },
                set: { engine.selectRole($0) }
            )) {
                ForEach(PlayerRole.allCases) { role in
                    Text(role.label).tag(role)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var roleStats: some View {
        HStack(spacing: Space.md) {
            statChip("heart.fill", "\(engine.myRole.maxHP) hp")
            statChip("bolt.fill", "\(engine.myRole.damage) dmg")
            statChip("arrow.counterclockwise", "\(engine.myRole.magazineSize) rds")
            statChip("timer", String(format: "%.2gs", engine.myRole.fireCooldown))
        }
        .font(.app(.caption))
        .foregroundStyle(Color.echoTextSecondary)
        .lineLimit(1)
        // The strip wins the row over the label it shares: ROLE is one short
        // word with room to spare, four numbers aren't.
        .layoutPriority(1)
    }

    /// Glyph and value sit two points apart — they're one fact — with six times
    /// that between chips, so the strip reads as four pairs rather than eight
    /// loose pieces.
    private func statChip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: Space.xxs) {
            Image(systemName: icon)
                .accessibilityHidden(true)
            Text(text)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    /// The roster count, and the loudest thing on the screen after the title —
    /// it's the number everyone in the lobby is actually waiting on. No "PLAYERS"
    /// in front of it: it sits directly on top of the players.
    private var rosterCount: some View {
        Text("\(roster.count)/\(engine.settings.maxPlayers)")
            .font(.appBold(.title2).monospacedDigit())
            .foregroundStyle(Color.echoText)
            .textCase(nil)
            .accessibilityLabel("\(roster.count) of \(engine.settings.maxPlayers) players")
    }

    /// One step down from the roster count. A word is enough to name a block of
    /// controls — the icon, the label, and the trailing value that used to sit
    /// here all said the same thing the selected segment already says.
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.app(.headline))
            .foregroundStyle(Color.echoText)
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Name and role, nothing else. Everyone in a lobby is connected and on a
    /// phone by definition, so the checkmark and the handset were confirming
    /// facts the row's own existence already carried. A player who *has* dropped
    /// dims instead — absence of color, not another glyph.
    private func playerRow(_ player: Player) -> some View {
        HStack {
            Text(player.name.displayCallSign)
                .font(.app(.body))
                .foregroundStyle(player.isConnected
                                 ? Color.echoText
                                 : Color.echoTextTertiary)
            if player.name == engine.myName {
                Text("you")
                    .font(.app(.caption2))
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xxs)
                    .background(Color.echoSurface, in: Capsule())
            }
            Spacer()
            Text(player.role.label.uppercased())
                .font(.app(.caption2))
                .foregroundStyle(Color.echoTextSecondary)
        }
        .padding(.vertical, Space.md)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(player.name.displayCallSign)"
            + (player.name == engine.myName ? ", you" : "")
            + ", \(player.role.label)"
            + (player.isConnected ? "" : ", disconnected")
        )
    }

    /// Spectators have no loadout, so the eye takes the role slot — same column,
    /// different fact.
    private func spectatorRow(_ name: String) -> some View {
        HStack {
            Text(name.displayCallSign)
                .foregroundStyle(Color.echoTextSecondary)
            Spacer()
            Image(art: .spectate)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: spectateGlyph)
                .foregroundStyle(Color.echoTextSecondary)
        }
        .padding(.vertical, Space.md)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name.displayCallSign), spectating")
    }

    /// Team name plus headcount, tinted by relationship — and "YOUR TEAM" in
    /// words, so the color is never the only signal. This is the roster's
    /// header in team play, the same job the count does in solo, so it carries
    /// the same weight one step down: two of these are tinted and on screen at
    /// once, which is loud enough without the full size.
    private func teamHeader(_ team: Team) -> some View {
        let mine = team == engine.myTeam
        return HStack(spacing: Space.sm) {
            Circle()
                .fill(Color.echoTeam(team, relativeTo: engine.myTeam))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text("\(team.displayName.uppercased()) · \(members(of: team).count)")
                .font(.appBold(.title3).monospacedDigit())
                .foregroundStyle(Color.echoTeam(team, relativeTo: engine.myTeam))
            if mine {
                Text("YOUR TEAM")
                    .font(.appBold(.caption))
                    .foregroundStyle(Color.echoTeamAlly)
            }
        }
        .textCase(nil)
    }

    /// Join or switch sides. Everyone gets this, host included — team choice
    /// is per-player, not a host setting.
    private var teamPicker: some View {
        VStack(spacing: Space.sm) {
            // "TEAM", not "YOUR TEAM": the roster header is where you find out
            // which side is yours, and saying it twice makes neither one the
            // answer. This label just names the control, like ROLE and MODE.
            sectionLabel("TEAM")
            Picker("Your team", selection: Binding(
                get: { engine.myTeam ?? .alpha },
                set: { engine.selectTeam($0) }
            )) {
                ForEach(Team.allCases) { team in
                    Text(team.displayName).tag(team)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}
