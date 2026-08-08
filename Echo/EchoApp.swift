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
            switch engine.phase {
            case .menu: MenuView()
            case .lobby: LobbyView()
            case .playing: GameHUDView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: engine.phase)
    }
}
