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
                // Kill-feed skull, template-tinted to danger, over the word set
                // in real type — the baked "ELIMINATED" banner clipped its glyphs.
                Image(art: .killSkull)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: skullSize, height: skullSize)
                    .foregroundStyle(Color.echoDanger)
                    .accessibilityHidden(true)

                Text("ELIMINATED")
                    .font(.appBold(fixedSize: titleSize))
                    .tracking(2)
                    .foregroundStyle(Color.echoDanger)

                if let killer = engine.lastKilledBy {
                    Text("tagged by \(killer.displayCallSign)")
                        .font(.app(.headline))
                        .foregroundStyle(Color.echoTextSecondary)
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
