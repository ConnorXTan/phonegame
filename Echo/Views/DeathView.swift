import SwiftUI

struct DeathView: View {
    @EnvironmentObject private var engine: GameEngine

    @ScaledMetric(relativeTo: .largeTitle) private var skullSize: CGFloat = 64
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 40
    @ScaledMetric(relativeTo: .largeTitle) private var countdownSize: CGFloat = 72

    var body: some View {
        ZStack {
            Color.echoBackground
                .opacity(Alpha.opaque)
                .ignoresSafeArea()

            VStack(spacing: Space.lg) {
                // Kill-feed skull in its own color — the red silhouette keeps its
                // white eye/nose holes, which a template tint would fill in flat.
                Image(art: .killSkull)
                    .resizable()
                    .scaledToFit()
                    .frame(width: skullSize, height: skullSize)
                    .accessibilityHidden(true)

                Text(engine.lastKilledBy != nil ? "ELIMINATED BY:" : "ELIMINATED")
                    .font(.appBold(fixedSize: titleSize))
                    .tracking(2)
                    .foregroundStyle(Color.echoDanger)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                if let killer = engine.lastKilledBy {
                    Text(killer.displayCallSign)
                        .font(.appBold(.title))
                        .foregroundStyle(Color.echoText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }

                Text(String(format: "%.1f", max(0, engine.respawnRemaining)))
                    .font(.appBold(fixedSize: countdownSize))
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
