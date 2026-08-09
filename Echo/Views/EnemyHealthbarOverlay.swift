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
///      for pre-convergence U2 phones) cast out from the
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
                    EnemyTag(name: tag.name, hpFraction: tag.hpFraction, hearts: tag.hearts,
                             side: tag.side, effects: tag.effects, date: tag.date)
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
        let hearts: Int
        let side: EnemyTag.Side
        let effects: [ActiveEffect]
        let date: Date
    }

    private func visibleTags(viewport: CGSize, at date: Date) -> [Tag] {
        guard viewport != .zero,
              let frame = engine.camera.session.currentFrame else { return [] }
        var tags: [Tag] = []
        for player in engine.opponents where player.isAlive && player.isConnected {
            // Cloak: the tag vanishes but the player stays fully shootable —
            // dropping the smoother state means the reappearance snaps into
            // place instead of gliding in from a five-second-old position.
            guard !engine.isCloaked(player.name, at: date),
                  let world = worldPosition(of: player.name, camera: frame.camera, at: date) else {
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
            let side: EnemyTag.Side = !engine.settings.teamPlay ? .neutral
                : engine.isEnemy(player) ? .enemy : .ally
            tags.append(Tag(
                id: player.name,
                name: player.name.displayCallSign,
                point: point,
                hpFraction: CGFloat(player.hp) / CGFloat(max(1, player.role.maxHP)),
                hearts: player.role.maxHP,
                side: side,
                effects: engine.effects(for: player.name, at: date),
                date: date))
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
        return origin + direction * (reading.distance ?? 5)
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
/// not prose — it sits over a live camera feed. Internal because the
/// spectator's feed redraws the exact same tag from streamed overlay state.
/// In team play the call sign carries the side's tint, and allies also get a
/// shield glyph so hue is never the only difference.
struct EnemyTag: View {
    enum Side { case neutral, ally, enemy }


    let name: String
    let hpFraction: CGFloat
    var hearts: Int = 5
    var side: Side = .neutral
    /// Their running powerups, rendered as mini countdown badges under the
    /// bar. Defaulted empty so the spectator feed's redraw (which doesn't
    /// stream effect state) keeps its shorter call.
    var effects: [ActiveEffect] = []
    var date: Date = Date()

    /// Fixed geometry, not spacing: the gauge is read at a distance over a
    /// moving camera feed, so it keeps its size independent of type scaling.
    /// Five hearts at this size span roughly the old 64pt bar.
    private static let heartSize: CGFloat = 11
    /// Mini version of the HUD's 30pt effect badge — subordinate to the tag.
    private static let effectSize: CGFloat = 20

    private var nameColor: Color {
        switch side {
        case .neutral: return .ltnTextSecondary
        case .ally: return .ltnTeamAlly
        case .enemy: return .ltnDanger
        }
    }

    var body: some View {
        VStack(spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                if side == .ally {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.app(.caption2))
                }
                Text(name.uppercased())
                    .font(.appBold(.caption2))
                    .lineLimit(1)
            }
            .foregroundStyle(nameColor)
            HeartBar(fraction: hpFraction, total: hearts, size: Self.heartSize)
            if !effects.isEmpty {
                HStack(spacing: Space.xs) {
                    ForEach(effects) { effect in
                        EffectRingBadge(kind: effect.kind,
                                        fraction: fraction(of: effect),
                                        diameter: Self.effectSize)
                    }
                }
            }
        }
        .shadow(color: Color.ltnBackground.opacity(Alpha.strong), radius: 2, y: 1)
    }

    private func fraction(of effect: ActiveEffect) -> Double {
        guard effect.duration > 0 else { return 0 }
        return effect.until.timeIntervalSince(date) / effect.duration
    }
}
