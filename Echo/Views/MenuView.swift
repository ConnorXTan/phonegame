import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var engine: GameEngine

    @ScaledMetric(relativeTo: .largeTitle) private var logoWidth: CGFloat = 220
    @ScaledMetric(relativeTo: .subheadline) private var subtitleKerning: CGFloat = 4

    /// Two separate reasons the subtitle sits left of the wordmark, corrected
    /// together.
    ///
    /// One: the logo art is not symmetric. The target glyph hangs off the left
    /// of the L, so the green "LTN" letterforms span x 27–319 of a 326pt canvas
    /// and their center is 10pt right of the image's. Centering the subtitle on
    /// the *frame* parks it left of the letters the eye actually pairs it with,
    /// so give back that same 3.1% of the logo's width.
    ///
    /// Two: letter spacing lands after the final character as well as between,
    /// so the drawn glyphs carry a trailing gap that centering counts as ink.
    /// That costs half a gap to the left. (`.kerning` is documented as spacing
    /// *between* characters and was expected to avoid this; measuring the
    /// render showed it does not, hence the explicit correction.)
    private var wordmarkCenterOffset: CGFloat {
        logoWidth * (10.0 / 326.0) + subtitleKerning / 2
    }
    @ScaledMetric(relativeTo: .body) private var spectateGlyph: CGFloat = 18
    /// Brand glyph on the primary menu buttons (Host / Find).
    @ScaledMetric(relativeTo: .body) private var buttonGlyph: CGFloat = 20

    @State private var showManageGallery = false

    private var nameEmpty: Bool {
        engine.playerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A Mac can't play (no UWB — it could neither aim nor be hit), so it only
    /// gets the spectator/game-master role.
    private var isMac: Bool { ProcessInfo.processInfo.isiOSAppOnMac }

    var body: some View {
        VStack(spacing: Space.xl) {
            Spacer()

            // The logo is a wordmark, so the initials arrive meaning nothing on
            // a first launch. The expansion sits directly under it as a
            // subtitle — quiet enough to read past once you know it, present
            // enough that nobody has to guess what they installed.
            VStack(spacing: Space.sm) {
                Image(art: .logo)
                    .resizable()
                    .scaledToFit()
                    .frame(width: logoWidth)
                    .accessibilityHidden(true)

                Text("LASER TAG NOW")
                    .font(.app(.subheadline))
                    // kerning, not tracking: tracking adds its gap after every
                    // character *including the last*, so a centered string ends
                    // up sitting half a gap left of where it looks like it
                    // should. kerning only goes between characters.
                    .kerning(subtitleKerning)
                    .foregroundStyle(Color.ltnTextSecondary)
                    .offset(x: wordmarkCenterOffset)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("LTN, Laser Tag Now")

            if let notice = engine.hostEndedNotice {
                Label(notice, systemImage: "flag.checkered")
                    .font(.app(.footnote))
                    .foregroundStyle(.cyan)
                    .padding(12)
                    .background(.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 24)
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
