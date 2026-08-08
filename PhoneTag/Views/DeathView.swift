import SwiftUI

struct DeathView: View {
    @EnvironmentObject private var engine: GameEngine

    var body: some View {
        ZStack {
            Color(red: 0.25, green: 0, blue: 0)
                .opacity(0.94)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "xmark.shield.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.red)

                Text("ELIMINATED")
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(.red)

                if let killer = engine.lastKilledBy {
                    Text("tagged by \(killer.displayCallSign)")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.8))
                }

                Text(String(format: "%.1f", max(0, engine.respawnRemaining)))
                    .font(.system(size: 72, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())

                Text("respawning…")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .transition(.opacity)
    }
}
