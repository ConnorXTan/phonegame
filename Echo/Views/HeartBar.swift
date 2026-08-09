import SwiftUI

/// A discrete health gauge drawn with the hand-drawn heart art: a full red heart
/// (`C1`) for each remaining segment, a faint broken heart (`C2`) for each lost
/// one. Shape carries the reading as much as color — a broken heart is legibly
/// "gone" even where the red/dim contrast is hard to see — so it satisfies the
/// "color is never the only signal" rule the capsule bar leaned on.
///
/// HP is continuous (0…maxHP) but hearts are discrete, so the count is rounded
/// to the nearest segment. A living player never shows zero hearts: any HP above
/// none keeps at least one lit, so "still in the fight" and "eliminated" don't
/// collapse to the same picture.
struct HeartBar: View {
    /// 0…1 share of max HP remaining.
    let fraction: CGFloat
    var total: Int = 5
    /// Edge length of one heart. Fixed geometry — this is a gauge over a live
    /// camera feed, sized to be read at a glance, not scaled with body text.
    var size: CGFloat
    var spacing: CGFloat = Space.xxs

    private var filled: Int {
        let clamped = max(0, min(1, fraction))
        let rounded = Int((clamped * CGFloat(total)).rounded())
        return clamped > 0 ? max(1, rounded) : 0
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<total, id: \.self) { index in
                heart(lit: index < filled)
                    .frame(width: size, height: size)
            }
        }
        .animation(.easeOut(duration: 0.2), value: filled)
    }

    @ViewBuilder
    private func heart(lit: Bool) -> some View {
        if lit {
            Image(art: .heartFull)
                .resizable()
                .scaledToFit()
        } else {
            // Broken-heart art is a solid silhouette; template it so a lost slot
            // reads as a faint tint of the HUD text rather than a black blob.
            Image(art: .heartEmpty)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.ltnText.opacity(Alpha.subtle))
        }
    }
}
