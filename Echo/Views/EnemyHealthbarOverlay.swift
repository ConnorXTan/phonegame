import ARKit
import simd
import SwiftUI
import UIKit

/// Call sign + HP bar floating over each opponent's phone, projected through
/// the shared ARSession. Reads only state that already flows — UWB ranging and
/// the synced `players` table — so it adds nothing to the shoot path.
///
/// Position source, best first:
///   1. `NISession.worldTransform` — camera-assistance fusion, world-anchored,
///      so the bar stays glued at frame rate while the local camera pans.
///   2. The latest device-frame reading (raw U1 direction, or horizontalAngle
///      for the target dummy and pre-convergence U2 phones) cast out from the
///      current camera pose.
/// Either way the bar hides once readings go stale (~1 s) — same rule as the
/// shoot path: old data must not pin a bar to empty space.
struct EnemyHealthbarOverlay: View {
    @EnvironmentObject private var engine: GameEngine

    /// Reference type on purpose: mutated during TimelineView frames without
    /// touching SwiftUI state invalidation.
    @State private var smoother = WorldSmoother()

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { context in
                ForEach(visibleTags(viewport: geo.size, at: context.date)) { tag in
                    EnemyTag(name: tag.name, hpFraction: tag.hpFraction)
                        .position(x: tag.point.x, y: tag.point.y - 48)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)   // live spatial chrome; the scoreboard carries the same info
    }

    // MARK: - Projection

    private struct Tag: Identifiable {
        let id: String       // wire name
        let name: String     // display call sign
        let point: CGPoint
        let hpFraction: CGFloat
    }

    private func visibleTags(viewport: CGSize, at date: Date) -> [Tag] {
        guard viewport != .zero,
              let frame = engine.camera.session.currentFrame else { return [] }
        let maxHP = CGFloat(max(1, engine.settings.maxHP))
        var tags: [Tag] = []
        for player in engine.opponents where player.isAlive && player.isConnected {
            guard let world = worldPosition(of: player.name, camera: frame.camera, at: date) else {
                smoother.drop(player.name)
                continue
            }
            let smoothed = smoother.update(player.name, target: world, at: date)
            // A point behind the camera plane projects to a mirrored ghost — cull it.
            let inCamera = frame.camera.transform.inverse * simd_float4(smoothed, 1)
            guard inCamera.z < 0 else { continue }
            let point = frame.camera.projectPoint(
                smoothed, orientation: .portrait, viewportSize: viewport)
            guard point.x > -32, point.x < viewport.width + 32,
                  point.y > 0, point.y < viewport.height else { continue }
            tags.append(Tag(
                id: player.name,
                name: player.name.displayCallSign,
                point: point,
                hpFraction: CGFloat(player.hp) / maxHP))
        }
        return tags
    }

    private func worldPosition(of name: String, camera: ARCamera, at date: Date) -> simd_float3? {
        guard let reading = engine.ranging.latestReading(for: name),
              date.timeIntervalSince(reading.timestamp) < 1.0 else { return nil }
        if let world = engine.ranging.worldPosition(for: name) { return world }
        guard let directional = engine.ranging.latestDirectional(for: name, within: 1.0)
        else { return nil }
        return synthesized(from: directional, camera: camera)
    }

    /// Fallback when there's no world transform: cast the device-frame reading
    /// out from the current camera pose. Device-anchored, so it moves at
    /// ranging rate rather than frame rate — good enough for a hover bar.
    private func synthesized(from reading: RangingReading, camera: ARCamera) -> simd_float3? {
        let deviceDirection: simd_float3
        if let d = reading.direction {
            deviceDirection = d
        } else if let h = reading.horizontalAngle {
            deviceDirection = simd_float3(sin(h), 0, -cos(h))   // + = to the right, eye level
        } else {
            return nil
        }
        // NI's device frame (portrait: +X right, +Y top, -Z out the back) is
        // ARKit's camera frame rotated 90° about Z — camera +X runs down the
        // long axis toward the home-button end.
        let deviceToCamera = simd_quatf(angle: .pi / 2, axis: simd_float3(0, 0, 1))
        let inCamera = deviceToCamera.act(deviceDirection)
        let t = camera.transform
        let world4 = t * simd_float4(inCamera, 0)
        let origin = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let direction = simd_normalize(simd_float3(world4.x, world4.y, world4.z))
        return origin + direction * (reading.distance ?? TargetDummy.distance)
    }
}

/// Per-peer low-pass over world positions. UWB updates land at ~5 Hz; without
/// smoothing the bar teleports a few centimeters on each one. Time-constant
/// form keeps the lag the same at any display refresh rate.
private final class WorldSmoother {
    private var state: [String: (position: simd_float3, at: Date)] = [:]

    func update(_ name: String, target: simd_float3, at date: Date) -> simd_float3 {
        guard let previous = state[name] else {
            state[name] = (target, date)
            return target
        }
        let dt = Float(date.timeIntervalSince(previous.at))
        // A gap or a big jump is a respawn/relocation, not noise — snap, don't glide.
        guard dt < 0.5, simd_distance(previous.position, target) < 2 else {
            state[name] = (target, date)
            return target
        }
        let alpha = 1 - exp(-dt / 0.15)
        let position = previous.position + (target - previous.position) * alpha
        state[name] = (position, date)
        return position
    }

    func drop(_ name: String) { state[name] = nil }
}

/// The floating tag itself: call sign over a thin HP capsule. Sized as chrome,
/// not prose — it sits over a live camera feed.
private struct EnemyTag: View {
    let name: String
    let hpFraction: CGFloat

    private var barColor: Color {
        hpFraction > 0.5 ? .green : hpFraction > 0.25 ? .orange : .red
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(name.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.4))
                Capsule()
                    .fill(barColor)
                    .frame(width: 64 * max(0, min(1, hpFraction)))
            }
            .frame(width: 64, height: 4)
            .animation(.easeOut(duration: 0.2), value: hpFraction)
        }
        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
    }
}
