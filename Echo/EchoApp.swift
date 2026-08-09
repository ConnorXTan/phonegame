import SwiftUI

@main
struct EchoApp: App {
    @StateObject private var engine = GameEngine()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var engine: GameEngine

    var body: some View {
        ZStack {
            if engine.phase == .menu {
                MenuView()
            } else if engine.phase == .browsing {
                if let net = engine.network {
                    LobbyBrowserView(net: net)
                } else {
                    MenuView()
                }
            } else if engine.isSpectator {
                SpectatorView()   // one screen covers lobby/playing/summary
            } else {
                switch engine.phase {
                case .menu, .browsing: MenuView()
                case .lobby: LobbyView()
                case .playing: GameHUDView()
                case .summary: MatchSummaryView()
                }
            }
        }
        // Brand face as the app-wide default, so text that doesn't set its own
        // font (buttons, text fields, alerts) still speaks in Echo's voice.
        // Explicit `.font(.app(...))` sites override this with the right style.
        .font(.app(.body))
        .animation(.easeInOut(duration: 0.25), value: engine.phase)
    }
}
