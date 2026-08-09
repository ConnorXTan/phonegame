import SwiftUI
import simd

/// Corner minimap: you sit at the centre, straight up is out the back of the
/// phone (where you're aiming). Each peer in weapon range is a blip with its
/// distance in metres, and walls ARKit has spotted draw as floor-plan lines —
/// a picture of the room, not game logic: they never block a shot.
///
/// Genuine data visualisation rather than icon art, so `Canvas` is the right
/// tool — the geometry *is* the content. Sibling of `RadarView`, which is the
/// bigger half-dome version living in the diagnostics sheet.
struct MiniMapView: View {
    @EnvironmentObject private var engine: GameEngine

    /// One entry per human, newest reading wins — a rejoin mints a new wire
    /// name, and two blips for one person would be worse than none.
    private var livePeers: [Player] {
        Dictionary(grouping: engine.opponents.filter { $0.isAlive }, by: \.name.displayCallSign)
            .values
            .compactMap { entries in
                entries.first { engine.ranging.latestReading(for: $0.name) != nil } ?? entries.first
            }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            Canvas { ctx, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2 - 12   // room for labels
                let maxRange = CGFloat(engine.settings.weaponRange)

                drawRings(ctx: ctx, center: center, radius: radius)
                drawCone(ctx: ctx, center: center, radius: radius)
                drawWalls(ctx: ctx, center: center, radius: radius, maxRange: maxRange)

                for player in livePeers {
                    // Stale blips lie about where someone is — drop them.
                    guard let reading = engine.ranging.latestReading(for: player.name),
                          Date().timeIntervalSince(reading.timestamp) < 1.5,
                          let distance = reading.distance else { continue }
                    let scaled = min(CGFloat(distance) / maxRange, 1.0) * radius

                    if let angle = bearing(reading) {
                        drawBlip(ctx: ctx, center: center, at: scaled, angle: CGFloat(angle),
                                 name: player.name.displayCallSign, distance: distance,
                                 locked: engine.aimedTarget == player.name,
                                 isAlly: engine.settings.teamPlay && !engine.isEnemy(player))
                    } else {
                        // Ranged but out of the UWB cone: the distance is solid,
                        // the direction isn't. A ring says exactly that.
                        drawRangeRing(ctx: ctx, center: center, at: scaled,
                                      name: player.name.displayCallSign, distance: distance)
                    }
                }

                // Self last, so it sits on top of any blip that gets close.
                ctx.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)),
                         with: .color(.echoText))
            }
        }
        // Fill only — no outline. The stroke sat a hair outside the last range
        // ring and read as a tighter fourth ring rather than a boundary.
        .background(Circle().fill(Color.echoBackground.opacity(Alpha.strong)))
        .accessibilityHidden(true)   // geometry; the ranging sheet reads the same data as text
    }

    /// Signed radians off boresight, positive to the right.
    private func bearing(_ reading: RangingReading) -> Float? {
        if let h = reading.horizontalAngle { return h }
        if let d = reading.direction { return atan2(d.x, -d.z) }
        return nil
    }

    /// Half, three-quarter, and full weapon range. The extra ring out near the
    /// rim is where the reading matters most — that's the band a target is in
    /// just before they walk into range.
    private func drawRings(ctx: GraphicsContext, center: CGPoint, radius: CGFloat) {
        for fraction: CGFloat in [0.5, 0.75, 1.0] {
            let r = radius * fraction
            ctx.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                       with: .color(.echoSecondary.opacity(Alpha.subtle)), lineWidth: 1)
        }
    }

    /// The aim cone, pointing up — the wedge a target has to be inside to hit.
    private func drawCone(ctx: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let cone = Double(engine.settings.aimConeDegrees)
        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: radius,
                    startAngle: .degrees(-90 - cone),
                    endAngle: .degrees(-90 + cone),
                    clockwise: false)
        path.closeSubpath()
        ctx.fill(path, with: .color(.echoPrimary.opacity(Alpha.surface)))
    }

    /// Detected walls as seen from above, in the same ego-centric frame as
    /// the blips: you at the centre, aim pointing up. Metres map linearly to
    /// points (radius = weapon range) and the layer clips to the map circle,
    /// so a long corridor wall can't escape the widget. Dimmer than any blip
    /// — the room is context, the people are the content.
    private func drawWalls(ctx: GraphicsContext, center: CGPoint, radius: CGFloat, maxRange: CGFloat) {
        guard let pose = engine.camera.groundPose else { return }
        let segments = engine.camera.wallSegments
        guard !segments.isEmpty else { return }
        let scale = radius / maxRange
        var path = Path()
        for segment in segments {
            path.move(to: mapPoint(segment.start, pose: pose, center: center, scale: scale))
            path.addLine(to: mapPoint(segment.end, pose: pose, center: center, scale: scale))
        }
        var layer = ctx   // copy: clip the walls, not the whole canvas
        layer.clip(to: Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                              width: radius * 2, height: radius * 2)))
        layer.stroke(path, with: .color(.echoTextSecondary.opacity(Alpha.strong)),
                     style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    /// World-XZ metres → canvas points: project the offset from the player
    /// onto the aim frame (forward = up on the map, right = right).
    private func mapPoint(_ world: SIMD2<Float>, pose: GroundPose,
                          center: CGPoint, scale: CGFloat) -> CGPoint {
        let offset = world - pose.position
        return CGPoint(
            x: center.x + CGFloat(simd_dot(offset, pose.right)) * scale,
            y: center.y - CGFloat(simd_dot(offset, pose.forward)) * scale)
    }

    private func drawBlip(ctx: GraphicsContext, center: CGPoint, at r: CGFloat, angle: CGFloat,
                          name: String, distance: Float, locked: Bool, isAlly: Bool) {
        let point = CGPoint(x: center.x + sin(angle) * r, y: center.y - cos(angle) * r)
        // Neutral until locked: echoAccent sits only 20° from echoPrimary, so
        // two greens would be indistinguishable at a glance under pressure.
        let color: Color = isAlly ? .echoTeamAlly : locked ? .echoPrimary : .echoTextSecondary
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

    private func drawRangeRing(ctx: GraphicsContext, center: CGPoint, at r: CGFloat,
                               name: String, distance: Float) {
        let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        ctx.stroke(Path(ellipseIn: rect),
                   with: .color(.echoTextTertiary),
                   style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        drawLabel(ctx: ctx, "\(name) \(String(format: "%.1f", distance))m", .echoTextSecondary,
                  at: CGPoint(x: center.x, y: center.y + r + 8))
    }

    /// Labels sit over a live camera feed, so each gets its own backing chip —
    /// bare text on a bright frame is unreadable. Also nudged to stay inside
    /// the canvas, since a blip near the rim would otherwise push it off.
    private func drawLabel(ctx: GraphicsContext, _ text: String, _ color: Color, at point: CGPoint) {
        let resolved = ctx.resolve(Text(text).font(.caption2.bold()).foregroundStyle(color))
        let size = resolved.measure(in: CGSize(width: 200, height: 40))
        let half = size.width / 2 + 3
        let x = min(max(point.x, half), ctx.clipBoundingRect.width - half)
        let anchored = CGPoint(x: x, y: point.y)
        let chip = CGRect(x: anchored.x - size.width / 2 - 3, y: anchored.y - size.height / 2 - 1,
                          width: size.width + 6, height: size.height + 2)
        ctx.fill(Path(roundedRect: chip, cornerRadius: 3),
                 with: .color(.echoBackground.opacity(Alpha.heavy)))
        ctx.draw(resolved, at: anchored)
    }
}
