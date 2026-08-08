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
        .animation(.easeInOut(duration: 0.25), value: engine.phase)
    }
}
