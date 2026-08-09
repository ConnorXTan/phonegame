import SwiftUI

struct DeathView: View {
    @EnvironmentObject private var engine: GameEngine

    @ScaledMetric(relativeTo: .largeTitle) private var bannerWidth: CGFloat = 240
    @ScaledMetric(relativeTo: .largeTitle) private var countdownSize: CGFloat = 72

    var body: some View {
        ZStack {
            Color.echoBackground
                .opacity(Alpha.opaque)
                .ignoresSafeArea()

            VStack(spacing: Space.lg) {
                Image(art: .eliminated)
                    .resizable()
                    .scaledToFit()
                    .frame(width: bannerWidth)
                    .accessibilityLabel("Eliminated")

                if let killer = engine.lastKilledBy {
                    Text("tagged by \(killer.displayCallSign)")
                        .font(.app(.headline))
                        .foregroundStyle(Color.echoTextSecondary)
                }

                Text(String(format: "%.1f", max(0, engine.respawnRemaining)))
                    .font(.app(fixedSize: countdownSize).weight(.bold))
                    .foregroundStyle(Color.echoText)
                    .contentTransition(.numericText())

                Text("respawning…")
                    .font(.app(.subheadline))
                    .foregroundStyle(Color.echoTextTertiary)
            }
            .accessibilityElement(children: .combine)
        }
        .transition(.opacity)
    }
}
