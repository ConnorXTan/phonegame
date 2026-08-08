import SwiftUI

struct LobbyView: View {
    @EnvironmentObject private var engine: GameEngine

    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 32

    private var roster: [Player] {
        engine.players.values.sorted { $0.name < $1.name }
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
                Section("Players · \(roster.count)/\(engine.settings.maxPlayers)") {
                    ForEach(roster) { player in
                        HStack {
                            Image(systemName: "iphone.gen3")
                                .foregroundStyle(Color.echoSecondary)
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
                    if roster.count < 2 {
                        HStack {
                            ProgressView()
                            Text("Waiting for players to join…")
                                .foregroundStyle(Color.echoTextSecondary)
                                .padding(.leading, Space.sm)
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

            if engine.isHost {
                VStack(spacing: Space.md) {
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
                            set: { engine.settings.matchDuration = $0 }
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
                                    engine.refreshLobbyAdvertisement()
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
}
