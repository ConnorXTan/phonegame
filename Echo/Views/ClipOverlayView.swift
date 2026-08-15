import SwiftUI

/// The killcam chrome — enemy tags, the neutral crosshair, and hit-marker
/// pops — drawn in one place for every consumer: the spectator's live feed,
/// the in-app clip review, and the published MP4 (`ClipEncoder` rasterizes
/// this same view through `ImageRenderer`), so the gallery can't drift from
/// what the app shows.
///
/// The crosshair is deliberately neutral — no lock ring, no callout; the
/// markers and hearts carry the drama.
struct ClipOverlayView: View {
    /// The shooter's HUD state at this frame; nil draws markers only.
    let overlay: SpectatorOverlayState?
    /// Every marker in the clip window; only the ones alive at `clipTime` show.
    var markers: [ClipMarkerEvent] = []
    var clipTime: TimeInterval = 0
    /// Where the camera frame sits in this view's coordinate space — tag
    /// positions are normalized to it.
    let fit: CGRect

    /// Fixed-geometry aim reference over the camera frame, exempt from
    /// Dynamic Type like the reticle it stands in for.
    private static let crosshairSize: CGFloat = 40

    var body: some View {
        ZStack {
            if let overlay {
                ForEach(overlay.tags, id: \.name) { tag in
                    EnemyTag(name: tag.name, hpFraction: CGFloat(tag.hp), hearts: tag.hearts)
                        // Same lift the live overlay gives the tag: it floats
                        // above the phone it's pinned to, not on top of it.
                        .position(x: fit.minX + CGFloat(tag.x) * fit.width,
                                  y: fit.minY + CGFloat(tag.y) * fit.height - 40)
                }
                Image(systemName: "plus")
                    .font(.system(size: Self.crosshairSize, weight: .thin))
                    .foregroundStyle(Color.ltnText.opacity(Alpha.muted))
                    .position(x: fit.midX, y: fit.midY)
            }
            // Hit/kill markers replayed with the HUD's art and bloom-fade,
            // timed off the clip clock.
            ForEach(Array(markers.enumerated()), id: \.offset) { item in
                let marker = item.element
                let age = clipTime - marker.offset
                if age >= 0, age < ClipMarkerEvent.duration {
                    let fade = age / ClipMarkerEvent.duration
                    Image(art: marker.isKill ? .hitMarkerKill : .hitMarker)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(marker.isKill ? Color.ltnDanger : Color.ltnText)
                        // Same reticle-relative read as the live HUD, against
                        // this view's 40pt crosshair rather than its 74pt ring.
                        .frame(width: marker.isKill ? 17 : 15,
                               height: marker.isKill ? 17 : 15)
                        .opacity(1 - fade)
                        .scaleEffect(0.8 + 0.4 * fade)
                        .position(x: fit.midX, y: fit.midY)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)   // replay chrome; the surrounding UI carries the words
    }
}
