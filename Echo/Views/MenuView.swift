import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var engine: GameEngine

    @ScaledMetric(relativeTo: .largeTitle) private var logoWidth: CGFloat = 220
    @ScaledMetric(relativeTo: .body) private var spectateGlyph: CGFloat = 18
    /// Brand glyph on the primary menu buttons (Host / Find).
    @ScaledMetric(relativeTo: .body) private var buttonGlyph: CGFloat = 20

    @State private var showManageGallery = false
    @State private var showTrainingSetup = false

    private var nameEmpty: Bool {
        engine.playerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A Mac can't play (no UWB — it could neither aim nor be hit), so it only
    /// gets the spectator/game-master role.
    private var isMac: Bool { ProcessInfo.processInfo.isiOSAppOnMac }

    var body: some View {
        VStack(spacing: Space.xl) {
            Spacer()

            // The wordmark stands alone. The expansion stays in the VoiceOver
            // label, so a screen-reader player still hears what the initials
            // mean even though nothing on screen spells it out.
            Image(art: .logo)
                .resizable()
                .scaledToFit()
                .frame(width: logoWidth)
                .accessibilityLabel("LTN, Laser Tag Now")

            if let notice = engine.hostEndedNotice {
                Label(notice, systemImage: "flag.checkered")
                    .font(.app(.footnote))
                    .foregroundStyle(Color.ltnAccent)
                    .padding(Space.md)
                    .background(Color.ltnAccent.opacity(Alpha.surface),
                                in: RoundedRectangle(cornerRadius: Radius.md))
                    .padding(.horizontal, Space.xl)
            }

            if !isMac, let warning = engine.uwbWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.app(.footnote))
                    .foregroundStyle(Color.ltnWarning)
                    .padding(Space.md)
                    .background(Color.ltnWarning.opacity(Alpha.surface),
                                in: RoundedRectangle(cornerRadius: Radius.md))
                    .padding(.horizontal, Space.xl)
            }

            if let notice = engine.lobbyNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.app(.footnote))
                    .foregroundStyle(Color.ltnWarning)
                    .padding(Space.md)
                    .background(Color.ltnWarning.opacity(Alpha.surface),
                                in: RoundedRectangle(cornerRadius: Radius.md))
                    .padding(.horizontal, Space.xl)
            }

            TextField(isMac ? "Spectator name (optional)" : "Username", text: $engine.playerName)
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
                        Label {
                            Text("Host a Lobby")
                        } icon: {
                            Image(art: .hostLobby)
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: buttonGlyph, height: buttonGlyph)
                        }
                        .frame(maxWidth: 260)
                        .foregroundStyle(Color.ltnOnPrimary)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Color.ltnPrimary)

                    Button {
                        engine.enterBrowser(asSpectator: false)
                    } label: {
                        Label {
                            Text("Find Lobbies")
                        } icon: {
                            Image(art: .joinLobby)
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: buttonGlyph, height: buttonGlyph)
                        }
                        .frame(maxWidth: 260)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .disabled(nameEmpty)

                // Solo drills need no lobby, no call sign — and no UWB, so
                // it stays enabled even when the warning above is showing.
                // The sheet picks the loadout on the way in.
                Button {
                    showTrainingSetup = true
                } label: {
                    Label("Training Range", systemImage: "target")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .sheet(isPresented: $showTrainingSetup) {
                    TrainingSetupView(role: engine.myRole)
                }
            }

            if isMac {
                VStack(spacing: Space.md) {
                    Button {
                        engine.enterSpectator(hosting: true)
                    } label: {
                        Label("Host a Game", systemImage: "tv")
                            .frame(maxWidth: 260)
                            .foregroundStyle(Color.ltnOnPrimary)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Color.ltnPrimary)

                    Button {
                        engine.enterBrowser(asSpectator: true)
                    } label: {
                        Label {
                            Text("Spectate a Lobby")
                        } icon: {
                            Image(art: .spectate)
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: spectateGlyph, height: spectateGlyph)
                        }
                        .frame(maxWidth: 260)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(Color.ltnText)   // neutral — the accent read as a warning here

                    Button {
                        showManageGallery = true
                    } label: {
                        Label("Manage Gallery", systemImage: "photo.stack")
                            .frame(maxWidth: 260)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(Color.ltnText)
                    .sheet(isPresented: $showManageGallery) { ManageGalleryView() }
                }
            }

            Spacer()
            Spacer()
        }
        // Warm the peer cache while the player is still here, so the lobby
        // fills immediately on Host/Join instead of after discovery warmup.
        .onAppear { engine.prewarmDiscovery() }
        .onChange(of: engine.playerName) { engine.prewarmDiscovery() }
    }
}
