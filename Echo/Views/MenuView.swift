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

    /// Where a word hangs off its stop.
    private enum WordAnchor { case centered, leading }

    /// Each word of the expansion sits under the letter it came from. The stops
    /// come off the logo art by connected component, not by eye: on its 326pt
    /// canvas the L spans x 27–127, the T 102–202 (they overlap — the art is
    /// hand-drawn and tightly kerned, so only 2D components separate them), and
    /// the N 213–319. Stored as fractions so they hold at any logo width.
    ///
    /// LASER and TAG hang from their letters' centers. NOW starts at the N's
    /// left edge instead: centering it left 49pt of daylight after TAG against
    /// only 13pt before it, which read as NOW drifting off on its own. Anchoring
    /// to the stem closes that to 23pt and the row scans as one line.
    private static let letterStops: [(word: String, stop: CGFloat, anchor: WordAnchor)] = [
        ("LASER", 77.0 / 326.0, .centered),
        ("TAG", 152.0 / 326.0, .centered),
        ("NOW", 213.0 / 326.0, .leading),
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
        // ZStack(alignment: .leading) pins every word's leading guide to the
        // same x and centers them vertically. Overriding that guide per word is
        // what lets one word hang from its center and another from its left
        // edge: the returned value is the offset *into* the view that gets
        // pinned, so -x puts the left edge at x, and width/2 - x centers it
        // there. Color.clear forces the stack to the logo's full width, which
        // the stops are fractions of.
        ZStack(alignment: .leading) {
            Color.clear
            ForEach(Self.letterStops, id: \.word) { stop in
                let x = logoWidth * stop.stop
                Text(stop.word)
                    .font(.app(fixedSize: subtitleSize))
                    .foregroundStyle(Color.ltnTextSecondary)
                    .fixedSize()
                    .alignmentGuide(.leading) { d in
                        stop.anchor == .centered ? d.width / 2 - x : -x
                    }
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
