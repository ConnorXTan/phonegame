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
                Label(engine.isHost ? "Hosting" : "Joined",
                      systemImage: "antenna.radiowaves.left.and.right")
                    .font(.callout)
                    .foregroundStyle(Color.echoTextSecondary)
            }
            .padding(.horizontal)

            Text("LOBBY")
                .font(.system(size: titleSize, weight: .black, design: .rounded))
                .tracking(3)

            List {
                if engine.settings.teamPlay {
                    ForEach(Team.allCases) { team in
                        Section {
                            ForEach(members(of: team)) { player in
                                playerRow(player)
                            }
                            if members(of: team).isEmpty {
                                Text("No one yet")
                                    .font(.caption)
                                    .foregroundStyle(Color.echoTextTertiary)
                            }
                        } header: {
                            teamHeader(team)
                        }
                    }
                    if !unassigned.isEmpty {
                        Section {
                            ForEach(unassigned) { player in
                                playerRow(player)
                            }
                        } header: {
                            sectionLabel("PICKING A TEAM")
                        }
                    }
                } else {
                    Section {
                        ForEach(roster) { player in
                            playerRow(player)
                        }
                        if roster.count < 2 {
                            HStack {
                                ProgressView()
                                Text("Waiting for players to join…")
                                    .foregroundStyle(Color.echoTextSecondary)
                                    .padding(.leading, Space.sm)
                            }
                        }
                    } header: {
                        rosterCount
                    }
                }
                if !engine.spectators.isEmpty {
                    Section {
                        ForEach(engine.spectators.sorted(), id: \.self) { name in
                            spectatorRow(name)
                        }
                    } header: {
                        sectionLabel("SPECTATORS · \(engine.spectators.count)")
                    }
                }
            }
            .scrollContentBackground(.hidden)

            rolePicker
                .padding(.horizontal)

            if engine.settings.teamPlay {
                teamPicker
                    .padding(.horizontal)
            }

            if engine.isHost {
                // One step wider than the gap inside a block, so each label
                // groups with the control under it rather than floating between.
                VStack(spacing: Space.lg) {
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
                                .font(.headline.monospacedDigit())
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
                            .font(.caption2)
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
                        .font(.caption2)
                        .foregroundStyle(Color.echoTextTertiary)
                }
                .padding(.bottom, Space.md)
            }
        }
        .padding(.vertical)
    }

    /// Everyone picks their own loadout while waiting; the choice broadcasts
    /// so the whole roster shows it.
    private var rolePicker: some View {
        VStack(spacing: Space.sm) {
            sectionLabel("ROLE")
            Picker("Role", selection: Binding(
                get: { engine.myRole },
                set: { engine.selectRole($0) }
            )) {
                ForEach(PlayerRole.allCases) { role in
                    Text(role.label).tag(role)
                }
            }
            .pickerStyle(.segmented)
            HStack(spacing: Space.xl) {
                statChip("heart.fill", "\(engine.myRole.maxHP) hp")
                statChip("bolt.fill", "\(engine.myRole.damage) dmg")
                statChip("arrow.counterclockwise", "\(engine.myRole.magazineSize) rds")
                statChip("timer", String(format: "%.2gs", engine.myRole.fireCooldown))
            }
            .font(.caption)
            .foregroundStyle(Color.echoTextSecondary)
        }
    }

    private func statChip(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
    }

    /// The roster count, and the loudest thing on the screen after the title —
    /// it's the number everyone in the lobby is actually waiting on. No "PLAYERS"
    /// in front of it: it sits directly on top of the players.
    private var rosterCount: some View {
        Text("\(roster.count)/\(engine.settings.maxPlayers)")
            .font(.title2.bold().monospacedDigit())
            .foregroundStyle(Color.echoText)
            .textCase(nil)
            .accessibilityLabel("\(roster.count) of \(engine.settings.maxPlayers) players")
    }

    /// One step down from the roster count. A word is enough to name a block of
    /// controls — the icon, the label, and the trailing value that used to sit
    /// here all said the same thing the selected segment already says.
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.headline)
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
                .foregroundStyle(player.isConnected
                                 ? Color.echoText
                                 : Color.echoTextTertiary)
            if player.name == engine.myName {
                Text("you")
                    .font(.caption2)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xxs)
                    .background(Color.echoSurface, in: Capsule())
            }
            Spacer()
            Text(player.role.label.uppercased())
                .font(.caption2)
                .foregroundStyle(Color.echoTextSecondary)
        }
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
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(Color.echoTeam(team, relativeTo: engine.myTeam))
            if mine {
                Text("YOUR TEAM")
                    .font(.caption.bold())
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
