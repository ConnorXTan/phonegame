import SwiftUI

/// Pick a lobby to join. Rows come straight from host advertisements —
/// occupancy, capacity, and whether the match is already running. Players
/// can't enter a full lobby; spectators always can (they take no slot).
struct LobbyBrowserView: View {
    @EnvironmentObject private var engine: GameEngine
    @ObservedObject var net: NetworkManager

    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 32

    var body: some View {
        ZStack {
            Color.echoBackground.ignoresSafeArea()
            VStack(spacing: Space.xl) {
                HStack {
                    Button("Back", role: .cancel) { engine.leave() }
                    Spacer()
                    Label(engine.myName.displayCallSign,
                          systemImage: engine.isSpectator ? "tv" : "person.fill")
                        .font(.app(.callout))
                        .foregroundStyle(Color.echoTextSecondary)
                }
                .padding(.horizontal)

                Text("LOBBIES")
                    .font(.app(fixedSize: titleSize).weight(.black))
                    .tracking(3)

                if let notice = engine.lobbyNotice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.app(.footnote))
                        .foregroundStyle(Color.echoWarning)
                        .padding(Space.md)
                        .background(Color.echoWarning.opacity(Alpha.surface),
                                    in: RoundedRectangle(cornerRadius: Radius.md))
                        .padding(.horizontal, Space.xl)
                }

                List {
                    if net.lobbies.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Searching for nearby lobbies…")
                                .foregroundStyle(Color.echoTextSecondary)
                                .padding(.leading, Space.sm)
                        }
                    }
                    ForEach(net.lobbies) { lobby in
                        lobbyRow(lobby)
                    }
                }
                .scrollContentBackground(.hidden)

                Text(engine.isSpectator
                     ? "You'll join as a spectator — watching, never playing."
                     : "Lobbies appear automatically when a host opens one nearby.")
                    .font(.app(.caption2))
                    .foregroundStyle(Color.echoTextTertiary)
            }
            .padding(.vertical)
        }
        .foregroundStyle(Color.echoText)
    }

    private func lobbyRow(_ lobby: DiscoveredLobby) -> some View {
        let joining = engine.joiningLobby == lobby.hostName
        let blocked = lobby.isFull && !engine.isSpectator
        return Button {
            engine.joinLobby(lobby)
        } label: {
            HStack(spacing: Space.md) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(blocked ? Color.echoInert : Color.echoPrimary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("\(lobby.hostName.displayCallSign)'s lobby")
                        .font(.app(.headline))
                    Text((lobby.isLive ? "Match in progress" : "In lobby")
                         + (lobby.isTeams ? " · Teams" : ""))
                        .font(.app(.caption2))
                        .foregroundStyle(lobby.isLive ? Color.echoAccent : Color.echoTextSecondary)
                }
                Spacer()
                if joining {
                    ProgressView()
                } else {
                    Text("\(lobby.playerCount)/\(lobby.capacity)")
                        .font(.app(.callout).monospacedDigit().bold())
                        .foregroundStyle(blocked ? Color.echoDanger : Color.echoTextSecondary)
                        .accessibilityLabel("\(lobby.playerCount) of \(lobby.capacity) players")
                }
            }
        }
        .disabled(blocked || engine.joiningLobby != nil)
    }
}
