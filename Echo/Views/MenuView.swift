import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var engine: GameEngine

    private var nameEmpty: Bool {
        engine.playerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A Mac can't play (no UWB — it could neither aim nor be hit), so it only
    /// gets the spectator/game-master role.
    private var isMac: Bool { ProcessInfo.processInfo.isiOSAppOnMac }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 44))
                    .foregroundStyle(.red)
                Text("ECHO")
                    .font(.system(size: 44, weight: .black, design: .rounded))
                    .tracking(4)
                Text("UWB laser tag · aim like a camera")
                    .foregroundStyle(.secondary)
            }

            if let warning = engine.uwbWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.yellow)
                    .padding(12)
                    .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 24)
            }

            if !isMac {
                TextField("Your call sign", text: $engine.playerName)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(maxWidth: 260)

                VStack(spacing: 12) {
                    Button {
                        engine.enterLobby(hosting: true)
                    } label: {
                        Label("Host Game", systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: 260)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)

                    Button {
                        engine.enterLobby(hosting: false)
                    } label: {
                        Label("Join Game", systemImage: "person.3.fill")
                            .frame(maxWidth: 260)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .disabled(nameEmpty)
            }

            if isMac {
                Button {
                    engine.enterSpectator(hosting: true)
                } label: {
                    Label("Run the Game (spectate & host)", systemImage: "tv")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.red)
            } else {
                Button {
                    engine.enterSpectator(hosting: true)
                } label: {
                    Label("Spectate & Host (big screen)", systemImage: "tv")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            Text(isMac ? "This Mac has no UWB chip, so it runs the show instead of playing."
                       : "Pick a short call sign — it's how other players see you.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()
            Spacer()
        }
    }
}
