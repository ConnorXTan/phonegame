import SwiftUI

struct DeathView: View {
    @EnvironmentObject private var engine: GameEngine

    @ScaledMetric(relativeTo: .largeTitle) private var glyphSize: CGFloat = 52
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 40
    @ScaledMetric(relativeTo: .largeTitle) private var countdownSize: CGFloat = 72

    var body: some View {
        ZStack {
            Color.echoBackground
                .opacity(Alpha.opaque)
                .ignoresSafeArea()

            VStack(spacing: Space.lg) {
                Image(systemName: "xmark.shield.fill")
                    .font(.system(size: glyphSize))
                    .foregroundStyle(Color.echoDanger)

                Text("ELIMINATED")
                    .font(.system(size: titleSize, weight: .black, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(Color.echoDanger)

                if let killer = engine.lastKilledBy {
                    Text("tagged by \(killer.displayCallSign)")
                        .font(.headline)
                        .foregroundStyle(Color.echoTextSecondary)
                }

                Text(String(format: "%.1f", max(0, engine.respawnRemaining)))
                    .font(.system(size: countdownSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.echoText)
                    .contentTransition(.numericText())

                Text("respawning…")
                    .font(.subheadline)
                    .foregroundStyle(Color.echoTextTertiary)
            }
            .accessibilityElement(children: .combine)
        }
        .transition(.opacity)
    }
}
