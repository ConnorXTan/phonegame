import ARKit
import simd
import SwiftUI

/// Drop markers floating at each consumable's anchor, projected through the
/// shared ARSession — the pickup counterpart of EnemyHealthbarOverlay. The
/// anchors are constants in our world frame, so there is nothing to smooth:
/// re-projecting per frame pins them in place while the camera pans.
struct ConsumableOverlay: View {
    @EnvironmentObject private var engine: GameEngine

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { context in
                ForEach(visibleMarkers(viewport: geo.size, at: context.date)) { marker in
                    ConsumableMarker(kind: marker.kind,
                                     distance: marker.distance,
                                     remaining: marker.remaining)
                        .position(marker.point)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)   // spatial chrome; a grab announces via the effect badge
    }

    private struct Marker: Identifiable {
        let id: UUID
        let kind: ConsumableKind
        let point: CGPoint
        let distance: Float
        let remaining: Double
    }

    private func visibleMarkers(viewport: CGSize, at date: Date) -> [Marker] {
        guard viewport != .zero,
              let frame = engine.camera.session.currentFrame else { return [] }
        var markers: [Marker] = []
        for drop in engine.consumables {
            // A point behind the camera plane projects to a mirrored ghost — cull it.
            let inCamera = frame.camera.transform.inverse * simd_float4(drop.position, 1)
            guard inCamera.z < 0 else { continue }
            let point = frame.camera.projectPoint(
                drop.position, orientation: .portrait, viewportSize: viewport)
            guard point.x > -32, point.x < viewport.width + 32,
                  point.y > 0, point.y < viewport.height else { continue }
            let cam = frame.camera.transform.columns.3
            let offset = drop.position - simd_float3(cam.x, cam.y, cam.z)
            markers.append(Marker(
                id: drop.id, kind: drop.kind, point: point,
                // Horizontal distance, matching the pickup check — a readout
                // that says 1 m should mean you're standing on it.
                distance: simd_length(simd_float2(offset.x, offset.z)),
                remaining: drop.remainingFraction(at: date)))
        }
        return markers
    }
}

/// The consumable signature, shared by every surface that shows one: the
/// kind's glyph in a scrim disc, ringed in the powerup violet by a countdown
/// that drains from 12 o'clock. On a field drop the ring is time until
/// despawn; on an effect badge it's time until the buff lapses — same
/// picture, same meaning: how long this lasts.
struct EffectRingBadge: View {
    let kind: ConsumableKind
    let fraction: Double
    let diameter: CGFloat

    /// Stroke tracks the disc so the 20pt tag badge and the 44pt field
    /// marker keep the same visual weight.
    private var ringWidth: CGFloat { max(2, diameter / 12) }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.ltnBackground.opacity(Alpha.strong))
            Circle()
                .stroke(Color.ltnText.opacity(Alpha.subtle), lineWidth: ringWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(kind.tint, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            // Full colour so each power-up reads by its own hue as well as its
            // shape; the scrim disc keeps it legible over the camera feed.
            Image(art: kind.art)
                .resizable()
                .scaledToFit()
                .frame(width: diameter * 0.56, height: diameter * 0.56)
        }
        .frame(width: diameter, height: diameter)
    }
}

/// A field drop's marker: the shared badge at field size, distance chip
/// underneath so the player knows how far the sprint is. Fixed geometry,
/// like EnemyTag — chrome read at a distance over a moving feed, not prose.
private struct ConsumableMarker: View {
    let kind: ConsumableKind
    let distance: Float
    let remaining: Double

    /// Disc diameter; the ring rides its edge.
    private static let discSize: CGFloat = 44

    var body: some View {
        VStack(spacing: Space.xs) {
            EffectRingBadge(kind: kind, fraction: remaining, diameter: Self.discSize)

            Text(String(format: "%.1fm", distance))
                .font(.appBold(.caption2).monospacedDigit())
                .foregroundStyle(Color.ltnText)
                .padding(.horizontal, Space.xs)
                .padding(.vertical, Space.xxs)
                .background(Color.ltnBackground.opacity(Alpha.heavy), in: Capsule())
        }
        .shadow(color: Color.ltnBackground.opacity(Alpha.strong), radius: 2, y: 1)
    }
}
