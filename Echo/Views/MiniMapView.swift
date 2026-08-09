import ARKit
import SwiftUI
import simd

/// Corner minimap: a 120° forward fan — you at the apex, straight up is out
/// the back of the phone (where you're aiming). The spread matches the UWB
/// field of view, so the fan shows exactly the region a bearing can come
/// from; a ranged peer without one draws as a dashed arc at its distance.
///
/// Genuine data visualisation rather than icon art, so `Canvas` is the right
/// tool — the geometry *is* the content. Sibling of `RadarView`, which is the
/// bigger half-dome version living in the diagnostics sheet.
struct MiniMapView: View {
    @EnvironmentObject private var engine: GameEngine

    /// Height:width for the HUD's frame. Width fixes the rim (2·R·sin 60°);
    /// height is R plus label headroom and the apex inset.
    static let aspect: CGFloat = 0.7

    /// ±60° — the fan's half-angle, ≈ the UWB field of view.
    private static let halfAngle: CGFloat = .pi / 3

    /// Meters at the fan's rim — a display scale for the blips and range
    /// rings, not a gameplay limit; shots land at any distance.
    private static let displayRange: CGFloat = 15

    /// One entry per human, newest reading wins — a rejoin mints a new wire
    /// name, and two blips for one person would be worse than none. Cloaked
    /// players drop out entirely: a blip with a name is exactly the reveal
    /// the cloak exists to suppress.
    private var livePeers: [Player] {
        Dictionary(grouping: engine.opponents.filter { $0.isAlive && !engine.isCloaked($0.name) },
                   by: \.name.displayCallSign)
            .values
            .compactMap { entries in
                entries.first { engine.ranging.latestReading(for: $0.name) != nil } ?? entries.first
            }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            Canvas { ctx, size in
                let apex = CGPoint(x: size.width / 2, y: size.height - 8)   // room for the self dot
                let radius = min(apex.y - 12,                               // label headroom above the rim
                                 (size.width / 2 - 2) / sin(Self.halfAngle))
                let maxRange = Self.displayRange

                // The fan itself is the widget's surface — ltnBackground at
                // Alpha.strong, the scrim weight that keeps everything on it
                // legible over the camera feed.
                ctx.fill(wedge(apex: apex, radius: radius),
                         with: .color(.ltnBackground.opacity(Alpha.strong)))
                drawRangeArcs(ctx: ctx, apex: apex, radius: radius)
                // Under the player blips: a drop and a person at the same
                // spot should read as the person.
                drawConsumables(ctx: ctx, apex: apex, radius: radius, maxRange: maxRange)

                for player in livePeers {
                    // Stale blips lie about where someone is — drop them.
                    guard let reading = engine.ranging.latestReading(for: player.name),
                          Date().timeIntervalSince(reading.timestamp) < 1.5,
                          let distance = reading.distance else { continue }
                    let scaled = min(CGFloat(distance) / maxRange, 1.0) * radius

                    if let angle = bearing(reading), abs(angle) <= Float(Self.halfAngle) {
                        drawBlip(ctx: ctx, apex: apex, at: scaled, angle: CGFloat(angle),
                                 name: player.name.displayCallSign, distance: distance,
                                 locked: engine.aimedTarget == player.name,
                                 isAlly: engine.settings.teamPlay && !engine.isEnemy(player))
                    } else {
                        // Ranged but no bearing in view: the distance is solid,
                        // the direction isn't. A dashed arc says exactly that —
                        // and stays nameless, because a label with no dot under
                        // it is a name floating over a direction we don't have.
                        drawDistanceArc(ctx: ctx, apex: apex, at: scaled)
                    }
                }

                // Self last, so it sits on top of any blip that gets close.
                ctx.fill(Path(ellipseIn: CGRect(x: apex.x - 4, y: apex.y - 4, width: 8, height: 8)),
                         with: .color(.ltnText))
            }
        }
        .accessibilityHidden(true)   // geometry; the ranging sheet reads the same data as text
    }

    /// Signed radians off boresight, positive to the right.
    private func bearing(_ reading: RangingReading) -> Float? {
        if let h = reading.horizontalAngle { return h }
        if let d = reading.direction { return atan2(d.x, -d.z) }
        return nil
    }

    /// The fan: apex at the player, opening ±60° about straight-up. Straight
    /// up is -90° in canvas angles, so the rim runs -150° → -30°.
    private func wedge(apex: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        path.move(to: apex)
        path.addArc(center: apex, radius: radius,
                    startAngle: .degrees(-150), endAngle: .degrees(-30), clockwise: false)
        path.closeSubpath()
        return path
    }

    /// Half, three-quarter, and full display range — distance reference
    /// rings for reading a blip's radius, not a gameplay boundary.
    private func drawRangeArcs(ctx: GraphicsContext, apex: CGPoint, radius: CGFloat) {
        for fraction: CGFloat in [0.5, 0.75, 1.0] {
            var arc = Path()
            arc.addArc(center: apex, radius: radius * fraction,
                       startAngle: .degrees(-150), endAngle: .degrees(-30), clockwise: false)
            ctx.stroke(arc, with: .color(.ltnSecondary.opacity(Alpha.subtle)), lineWidth: 1)
        }
    }

    private func drawBlip(ctx: GraphicsContext, apex: CGPoint, at r: CGFloat, angle: CGFloat,
                          name: String, distance: Float, locked: Bool, isAlly: Bool) {
        let point = CGPoint(x: apex.x + sin(angle) * r, y: apex.y - cos(angle) * r)
        // Neutral until locked: ltnAccent sits only 20° from ltnPrimary, so
        // two greens would be indistinguishable at a glance under pressure.
        let color: Color = isAlly ? .ltnTeamAlly : locked ? .ltnPrimary : .ltnTextSecondary
        let dot = Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
        if isAlly {
            // Hollow, so allies differ from enemies by shape as well as hue —
            // an ally can never be locked, so this never fights the lock cue.
            ctx.stroke(dot, with: .color(color), lineWidth: 2)
        } else {
            ctx.fill(dot, with: .color(color))
        }
        drawLabel(ctx: ctx, "\(name) \(String(format: "%.1f", distance))m", color,
                  at: CGPoint(x: point.x, y: point.y - 12))
    }

    /// Drop markers, placed by casting each world anchor through the current
    /// camera pose. Unlike peers this bearing has no UWB field-of-view limit,
    /// so a drop behind you is still a real reading — off-fan drops collapse
    /// to the distance-arc treatment, dotted (not dashed) and in the pickup
    /// color so they never masquerade as a person.
    private func drawConsumables(ctx: GraphicsContext, apex: CGPoint,
                                 radius: CGFloat, maxRange: CGFloat) {
        guard !engine.consumables.isEmpty,
              let camera = engine.camera.session.currentFrame?.camera else { return }
        let transform = camera.transform
        let origin = simd_float3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        for drop in engine.consumables {
            let offset = drop.position - origin
            let distance = simd_length(simd_float2(offset.x, offset.z))
            let scaled = min(CGFloat(distance) / maxRange, 1.0) * radius
            // World → camera → NI device frame (portrait: +X right, -Z out
            // the back) — the same frame peer bearings arrive in.
            let inCamera = transform.inverse * simd_float4(offset, 0)
            let inDevice = simd_quatf(angle: -.pi / 2, axis: simd_float3(0, 0, 1))
                .act(simd_float3(inCamera.x, inCamera.y, inCamera.z))
            let angle = CGFloat(atan2(inDevice.x, -inDevice.z))
            if abs(angle) <= Self.halfAngle {
                let point = CGPoint(x: apex.x + sin(angle) * scaled,
                                    y: apex.y - cos(angle) * scaled)
                let chip = Path(ellipseIn: CGRect(x: point.x - 7, y: point.y - 7,
                                                  width: 14, height: 14))
                ctx.fill(chip, with: .color(.ltnBackground.opacity(Alpha.heavy)))
                let blip = ctx.resolve(Image(art: drop.kind.art))
                ctx.draw(blip, in: CGRect(x: point.x - 6, y: point.y - 6,
                                          width: 12, height: 12))
            } else {
                var arc = Path()
                arc.addArc(center: apex, radius: scaled,
                           startAngle: .degrees(-150), endAngle: .degrees(-30), clockwise: false)
                ctx.stroke(arc, with: .color(.ltnPowerup.opacity(Alpha.strong)),
                           style: StrokeStyle(lineWidth: 1, dash: [1.5, 3]))
            }
        }
    }

    /// Someone at this range, somewhere off the fan. Pure geometry: the arc's
    /// radius against the range rings is the whole reading, so there's nothing
    /// for a name to add that wouldn't also imply a bearing we don't have.
    private func drawDistanceArc(ctx: GraphicsContext, apex: CGPoint, at r: CGFloat) {
        var arc = Path()
        arc.addArc(center: apex, radius: r,
                   startAngle: .degrees(-150), endAngle: .degrees(-30), clockwise: false)
        ctx.stroke(arc, with: .color(.ltnTextTertiary),
                   style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }

    /// Labels sit over a live camera feed, so each gets its own backing chip —
    /// bare text on a bright frame is unreadable. Also nudged to stay inside
    /// the canvas, since a blip near the rim would otherwise push it off.
    private func drawLabel(ctx: GraphicsContext, _ text: String, _ color: Color, at point: CGPoint) {
        let resolved = ctx.resolve(Text(text).font(.appBold(.caption2)).foregroundStyle(color))
        let size = resolved.measure(in: CGSize(width: 200, height: 40))
        let half = size.width / 2 + 3
        let x = min(max(point.x, half), ctx.clipBoundingRect.width - half)
        let anchored = CGPoint(x: x, y: point.y)
        let chip = CGRect(x: anchored.x - size.width / 2 - 3, y: anchored.y - size.height / 2 - 1,
                          width: size.width + 6, height: size.height + 2)
        ctx.fill(Path(roundedRect: chip, cornerRadius: 3),
                 with: .color(.ltnBackground.opacity(Alpha.heavy)))
        ctx.draw(resolved, at: anchored)
    }
}
