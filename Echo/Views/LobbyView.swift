import SwiftUI

struct LobbyView: View {
    @EnvironmentObject private var engine: GameEngine

    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 32

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
                        Section("Picking a team…") {
                            ForEach(unassigned) { player in
                                playerRow(player)
                            }
                        }
                    }
                } else {
                    Section("Players · \(roster.count)/\(engine.settings.maxPlayers)") {
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
                    }
                }
                if !engine.spectators.isEmpty {
                    Section("Spectators · \(engine.spectators.count)") {
                        ForEach(engine.spectators.sorted(), id: \.self) { name in
                            HStack {
                                Image(systemName: "tv")
                                    .foregroundStyle(Color.echoTextSecondary)
                                    .accessibilityHidden(true)
                                Text(name.displayCallSign)
                                    .foregroundStyle(Color.echoTextSecondary)
                                Spacer()
                            }
                        }
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
                VStack(spacing: Space.md) {
                    VStack(spacing: Space.sm) {
                        HStack {
                            Label("Mode", systemImage: "flag.2.crossed")
                                .font(.caption)
                                .foregroundStyle(Color.echoTextSecondary)
                            Spacer()
                            Text(engine.settings.teamPlay ? "Two teams" : "Free-for-all")
                                .font(.caption.bold())
                        }
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
                        HStack {
                            Label("Match length", systemImage: "timer")
                                .font(.caption)
                                .foregroundStyle(Color.echoTextSecondary)
                            Spacer()
                            Text(engine.settings.matchDuration.durationLabel)
                                .font(.caption.bold().monospacedDigit())
                        }
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
                            Label("Player limit", systemImage: "person.3")
                                .font(.caption)
                                .foregroundStyle(Color.echoTextSecondary)
                            Spacer()
                            Text("\(engine.settings.maxPlayers)")
                                .font(.caption.bold().monospacedDigit())
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
                    }

                    HStack(spacing: Space.xl) {
                        statChip("scope", String(format: "%.0f m", engine.settings.weaponRange))
                        statChip("angle", String(format: "%.0f°", engine.settings.aimConeDegrees))
                    }
                    .font(.caption)
                    .foregroundStyle(Color.echoTextSecondary)

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
            HStack {
                Label("Your role", systemImage: engine.myRole.symbol)
                    .font(.caption)
                    .foregroundStyle(Color.echoTextSecondary)
                Spacer()
                Text(engine.myRole.blurb)
                    .font(.caption2)
                    .foregroundStyle(Color.echoTextTertiary)
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

    private func playerRow(_ player: Player) -> some View {
        HStack {
            Image(systemName: "iphone.gen3")
                .foregroundStyle(engine.settings.teamPlay && player.team != nil
                                 ? Color.echoTeam(player.team, relativeTo: engine.myTeam)
                                 : Color.echoSecondary)
                .accessibilityHidden(true)
            Text(player.name.displayCallSign)
            if player.name == engine.myName {
                Text("you")
                    .font(.caption2)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xxs)
                    .background(Color.echoSurface, in: Capsule())
            }
            Spacer()
            Label(player.role.label.uppercased(), systemImage: player.role.symbol)
                .font(.caption2)
                .foregroundStyle(Color.echoTextSecondary)
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.echoSecondary)
                .accessibilityLabel("Connected")
        }
    }

    /// Team name plus headcount, tinted by relationship — and "your team" in
    /// words, so the color is never the only signal.
    private func teamHeader(_ team: Team) -> some View {
        let mine = team == engine.myTeam
        return HStack(spacing: Space.sm) {
            Circle()
                .fill(Color.echoTeam(team, relativeTo: engine.myTeam))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text("\(team.displayName) · \(members(of: team).count)")
            if mine {
                Text("your team")
                    .foregroundStyle(Color.echoTeamAlly)
            }
        }
    }

    /// Join or switch sides. Everyone gets this, host included — team choice
    /// is per-player, not a host setting.
    private var teamPicker: some View {
        VStack(spacing: Space.sm) {
            HStack {
                Label("Your team", systemImage: "shield.lefthalf.filled")
                    .font(.caption)
                    .foregroundStyle(Color.echoTextSecondary)
                Spacer()
                Text(engine.myTeam?.displayName ?? "—")
                    .font(.caption.bold())
                    .foregroundStyle(Color.echoTeamAlly)
            }
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
