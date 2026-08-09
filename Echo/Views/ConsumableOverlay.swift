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

/// The marker itself: the kind's glyph in a scrim disc, ringed by the despawn
/// countdown, distance underneath so the player knows how far the sprint is.
/// Fixed geometry, like EnemyTag — chrome read at a distance over a moving
/// feed, not prose.
private struct ConsumableMarker: View {
    let kind: ConsumableKind
    let distance: Float
    let remaining: Double

    /// Disc diameter; the ring rides its edge.
    private static let discSize: CGFloat = 44

    var body: some View {
        VStack(spacing: Space.xs) {
            ZStack {
                Circle()
                    .fill(Color.echoBackground.opacity(Alpha.strong))
                Circle()
                    .stroke(Color.echoText.opacity(Alpha.subtle), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: remaining)
                    .stroke(Color.echoAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))   // countdown runs from 12 o'clock
                Image(systemName: kind.symbol)
                    .font(.app(fixedSize: 18))
                    .foregroundStyle(Color.echoAccent)
            }
            .frame(width: Self.discSize, height: Self.discSize)

            Text(String(format: "%.1fm", distance))
                .font(.appBold(.caption2).monospacedDigit())
                .foregroundStyle(Color.echoText)
                .padding(.horizontal, Space.xs)
                .padding(.vertical, Space.xxs)
                .background(Color.echoBackground.opacity(Alpha.heavy), in: Capsule())
        }
        .shadow(color: Color.echoBackground.opacity(Alpha.strong), radius: 2, y: 1)
    }
}
