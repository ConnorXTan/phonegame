import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var engine: GameEngine

    @ScaledMetric(relativeTo: .largeTitle) private var markSize: CGFloat = 44
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 44

    private var nameEmpty: Bool {
        engine.playerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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

            if let warning = engine.uwbWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.echoWarning)
                    .padding(Space.md)
                    .background(Color.echoWarning.opacity(Alpha.surface),
                                in: RoundedRectangle(cornerRadius: Radius.md))
                    .padding(.horizontal, Space.xl)
            }

            TextField("Your call sign", text: $engine.playerName)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(maxWidth: 260)

            VStack(spacing: Space.md) {
                Button {
                    engine.enterLobby(hosting: true)
                } label: {
                    Label("Host Game", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: 260)
                        .foregroundStyle(Color.echoOnPrimary)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color.echoPrimary)

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

            Text("Pick a short call sign — it's how other players see you.")
                .font(.caption2)
                .foregroundStyle(Color.echoTextSecondary)

            Spacer()
            Spacer()
        }
    }
}
