import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var engine: GameEngine

    @ScaledMetric(relativeTo: .largeTitle) private var markSize: CGFloat = 44
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 44

    private var nameEmpty: Bool {
        engine.playerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A Mac can't play (no UWB — it could neither aim nor be hit), so it only
    /// gets the spectator/game-master role.
    private var isMac: Bool { ProcessInfo.processInfo.isiOSAppOnMac }

    var body: some View {
        VStack(spacing: Space.xl) {
            Spacer()

            VStack(spacing: Space.sm) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: markSize))
                    .foregroundStyle(Color.echoPrimary)
                    .accessibilityHidden(true)
                Text("ECHO")
                    .font(.system(size: titleSize, weight: .black, design: .rounded))
                    .tracking(4)
                Text("UWB laser tag · aim like a camera")
                    .foregroundStyle(Color.echoTextSecondary)
            }

            if let notice = engine.hostEndedNotice {
                Label(notice, systemImage: "flag.checkered")
                    .font(.footnote)
                    .foregroundStyle(.cyan)
                    .padding(12)
                    .background(.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 24)
            }

            if let warning = engine.uwbWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.echoWarning)
                    .padding(Space.md)
                    .background(Color.echoWarning.opacity(Alpha.surface),
                                in: RoundedRectangle(cornerRadius: Radius.md))
                    .padding(.horizontal, Space.xl)
            }

            if let notice = engine.lobbyNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.echoWarning)
                    .padding(Space.md)
                    .background(Color.echoWarning.opacity(Alpha.surface),
                                in: RoundedRectangle(cornerRadius: Radius.md))
                    .padding(.horizontal, Space.xl)
            }

            TextField(isMac ? "Spectator name (optional)" : "Your call sign", text: $engine.playerName)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(maxWidth: 260)

            if !isMac {
                VStack(spacing: Space.md) {
                    Button {
                        engine.enterLobby(hosting: true)
                    } label: {
                        Label("Host a Lobby", systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: 260)
                            .foregroundStyle(Color.echoOnPrimary)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Color.echoPrimary)

                    Button {
                        engine.enterBrowser(asSpectator: false)
                    } label: {
                        Label("Find Lobbies", systemImage: "person.3.fill")
                            .frame(maxWidth: 260)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .disabled(nameEmpty)
            }

            if isMac {
                VStack(spacing: Space.md) {
                    Button {
                        engine.enterSpectator(hosting: true)
                    } label: {
                        Label("Run the Game (host a lobby)", systemImage: "tv")
                            .frame(maxWidth: 260)
                            .foregroundStyle(Color.echoOnPrimary)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Color.echoPrimary)

                    Button {
                        engine.enterBrowser(asSpectator: true)
                    } label: {
                        Label("Spectate a Lobby", systemImage: "binoculars.fill")
                            .frame(maxWidth: 260)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }

            Text(isMac ? "This Mac has no UWB chip — it runs the show or watches, never plays."
                       : "Pick a short call sign — it's how other players see you.")
                .font(.caption2)
                .foregroundStyle(Color.echoTextSecondary)

            Spacer()
            Spacer()
        }
    }
}
