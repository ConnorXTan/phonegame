import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var engine: GameEngine

    @ScaledMetric(relativeTo: .largeTitle) private var logoWidth: CGFloat = 220
    /// Tied to `.largeTitle` — the same metric as `logoWidth` — rather than to
    /// a text style of its own. The words are positioned as fractions of the
    /// logo's width, so if the two scaled at different rates a large Dynamic
    /// Type setting would grow the words faster than the stops they sit between
    /// and run LASER into TAG. Sharing the metric fixes the ratio at every size.
    @ScaledMetric(relativeTo: .largeTitle) private var subtitleSize: CGFloat = 19

    /// Each word of the expansion sits under the letter it came from. The three
    /// stops are the letterforms' own centers, measured off the logo art by
    /// connected component: on its 326pt canvas the L spans x 27–127, the T
    /// 102–202 (they overlap — the art is hand-drawn and tightly kerned), and
    /// the N 213–319. Stored as fractions so they hold at any logo width.
    ///
    /// Note the stops are *not* evenly spaced: L→T is 23% of the width but T→N
    /// is 35%. That asymmetry is in the wordmark itself, so the row inherits it.
    private static let letterStops: [(word: String, center: CGFloat)] = [
        ("LASER", 77.0 / 326.0),
        ("TAG", 152.0 / 326.0),
        ("NOW", 266.0 / 326.0),
    ]

    /// Enough room for the tallest glyph plus its descender-free breathing
    /// space; the row is positioned, so it needs an explicit height.
    private var subtitleRowHeight: CGFloat { subtitleSize * 1.4 }
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

    /// The expansion, laid out as three independently placed words rather than
    /// one centered string — each one parked under its own initial. Positioning
    /// in the logo's own coordinate space is what makes the alignment exact:
    /// there is no string metric that would land the words under the letters by
    /// accident.
    private var subtitleRow: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Self.letterStops, id: \.word) { stop in
                Text(stop.word)
                    .font(.app(fixedSize: subtitleSize))
                    .foregroundStyle(Color.ltnTextSecondary)
                    .fixedSize()
                    .position(x: logoWidth * stop.center, y: subtitleRowHeight / 2)
            }
        }
        .frame(width: logoWidth, height: subtitleRowHeight)
    }

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

                subtitleRow
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
