import SwiftUI

struct LobbyView: View {
    @EnvironmentObject private var engine: GameEngine

    private var roster: [Player] {
        engine.players.values.sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Button("Leave", role: .destructive) { engine.leave() }
                Spacer()
                Label(engine.isHost ? "Hosting" : "Joined",
                      systemImage: "antenna.radiowaves.left.and.right")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            Text("LOBBY")
                .font(.system(size: 32, weight: .black, design: .rounded))
                .tracking(3)

            List {
                Section("Players · \(roster.count)") {
                    ForEach(roster) { player in
                        HStack {
                            Image(systemName: "iphone.gen3")
                                .foregroundStyle(.green)
                            Text(player.name.displayCallSign)
                            if player.name == engine.myName {
                                Text("you")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.blue.opacity(0.3), in: Capsule())
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    if roster.count < 2 {
                        HStack {
                            ProgressView()
                            Text("Searching for nearby players…")
                                .foregroundStyle(.secondary)
                                .padding(.leading, 8)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)

            if engine.isHost {
                VStack(spacing: 14) {
                    Picker("Mode", selection: Binding(
                        get: { engine.settings.mode },
                        set: { engine.settings = .preset(for: $0) }
                    )) {
                        Text("Indoor").tag(GameMode.indoor)
                        Text("Outdoor").tag(GameMode.outdoor)
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 20) {
                        statChip("scope", String(format: "%.0f m", engine.settings.weaponRange))
                        statChip("angle", String(format: "%.0f°", engine.settings.aimConeDegrees))
                        statChip("bolt.fill", "\(engine.settings.damage) dmg")
                        statChip("heart.fill", "\(engine.settings.maxHP) hp")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button {
                        engine.startGame()
                    } label: {
                        Text(roster.count < 2 ? "Start Anyway (solo test)" : "Start Game")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)
                }
                .padding(.horizontal)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for the host to start…")
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 12)
            }
        }
        .padding(.vertical)
    }

    private func statChip(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
    }
}
