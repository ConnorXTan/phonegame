import SwiftUI
import simd

/// Top-down radar: you are the dot at the bottom, straight up = out the back
/// of the phone (your aim). Blips use camera-assistance horizontalAngle when
/// available, else the raw direction vector. Peers with distance but no
/// direction are listed as "distance only" — they're out of the FoV cone.
struct RadarView: View {
    @EnvironmentObject private var engine: GameEngine

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            Canvas { ctx, size in
                let center = CGPoint(x: size.width / 2, y: size.height * 0.92)
                let radius = min(size.width / 2, size.height * 0.88) - 6
                let maxRange = CGFloat(engine.settings.weaponRange) * 1.5

                drawGrid(ctx: ctx, center: center, radius: radius)
                drawCone(ctx: ctx, center: center, radius: radius)

                var blindList: [(String, Float)] = []
                for player in engine.opponents where player.isAlive {
                    guard let reading = engine.ranging.latestReading(for: player.name) else { continue }
                    let angle = blipAngle(reading)
                    if let angle {
                        let dist = CGFloat(reading.distance ?? Float(maxRange))
                        drawBlip(ctx: ctx, center: center, radius: radius,
                                 angle: CGFloat(angle), distance: dist,
                                 maxRange: maxRange, name: player.name.displayCallSign,
                                 locked: engine.aimedTarget == player.name)
                    } else if let d = reading.distance {
                        blindList.append((player.name.displayCallSign, d))
                    }
                }

                // Peers we can range but not aim at (out of the UWB FoV cone).
                for (i, item) in blindList.enumerated() {
                    let text = Text("\(item.0) · \(String(format: "%.1f m", item.1))")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.4))
                    ctx.draw(text, at: CGPoint(x: 8, y: 10 + CGFloat(i) * 14), anchor: .leading)
                }

                // Self marker
                ctx.fill(Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)),
                         with: .color(.cyan))
            }
        }
    }

    /// Signed radians off boresight in the horizontal plane; positive = right.
    private func blipAngle(_ reading: RangingReading) -> Float? {
        if let h = reading.horizontalAngle { return h }
        if let d = reading.direction { return atan2(d.x, -d.z) }
        return nil
    }

    private func drawGrid(ctx: GraphicsContext, center: CGPoint, radius: CGFloat) {
        for fraction: CGFloat in [0.33, 0.66, 1.0] {
            let r = radius * fraction
            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            ctx.stroke(Path(ellipseIn: rect), with: .color(.green.opacity(0.25)), lineWidth: 1)
        }
        var vertical = Path()
        vertical.move(to: center)
        vertical.addLine(to: CGPoint(x: center.x, y: center.y - radius))
        ctx.stroke(vertical, with: .color(.green.opacity(0.35)), lineWidth: 1)
    }

    private func drawCone(ctx: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let cone = CGFloat(engine.settings.aimConeDegrees)
        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: radius,
                    startAngle: .degrees(-90 - Double(cone)),
                    endAngle: .degrees(-90 + Double(cone)),
                    clockwise: false)
        path.closeSubpath()
        ctx.fill(path, with: .color(.red.opacity(0.10)))
    }

    private func drawBlip(ctx: GraphicsContext, center: CGPoint, radius: CGFloat,
                          angle: CGFloat, distance: CGFloat, maxRange: CGFloat,
                          name: String, locked: Bool) {
        let r = min(distance / maxRange, 1.0) * radius
        let point = CGPoint(x: center.x + sin(angle) * r,
                            y: center.y - cos(angle) * r)
        let color: Color = locked ? .red : .orange
        ctx.fill(Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)),
                 with: .color(color))
        let label = Text("\(name) \(String(format: "%.1f", distance))m")
            .font(.caption2.bold())
            .foregroundStyle(color)
        ctx.draw(label, at: CGPoint(x: point.x, y: point.y - 14))
    }
}
