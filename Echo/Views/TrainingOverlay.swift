import ARKit
import simd
import SwiftUI
import UIKit

/// The range's world-anchored layer: glowing console orbs with their labels,
/// the counter panel floating above them, and the live drone — all projected
/// through the shared ARSession per frame, the same way the enemy tags and
/// drop markers stay pinned while the camera pans.
struct TrainingOverlay: View {
    @ObservedObject var range: TrainingRange
    let camera: AimCameraManager

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { context in
                // Explicit ZStack: every child positions itself in absolute
                // screen coordinates, which only holds while each one is
                // handed the full viewport to resolve `.position` against.
                ZStack {
                    if let frame = camera.session.currentFrame, geo.size != .zero {
                        let projector = Projector(frame: frame, viewport: geo.size)
                        orbLayer(projector, at: context.date)
                        counterPanel(projector)
                        droneLayer(projector, at: context.date)
                        killBurst(projector, at: context.date)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        // Spatial chrome: the HUD's top strip carries the same score for
        // VoiceOver, and the lock state reads through the aim element.
        .accessibilityHidden(true)
    }

    // MARK: - Orbs

    @ViewBuilder
    private func orbLayer(_ projector: Projector, at date: Date) -> some View {
        ForEach(range.orbs) { orb in
            if let point = projector.point(orb.position),
               let radius = projector.screenLength(TrainingRange.orbRadius, at: orb.position) {
                let diameter = min(max(radius * 2, 24), 96)   // legible floor, sane ceiling
                ZStack {
                    OrbSprite(color: orbColor(orb), diameter: diameter,
                              pulse: reduceMotion ? 0 : pulsePhase(at: date))
                    Text(orb.label)
                        .font(.appBold(.caption2))
                        .foregroundStyle(Color.ltnText)
                        .padding(.horizontal, Space.xs)
                        .padding(.vertical, Space.xxs)
                        .background(Color.ltnBackground.opacity(Alpha.heavy), in: Capsule())
                        // Clear of the halo (0.85 × diameter), and derived from
                        // the same diameter as the sprite so the label rides
                        // with the orb instead of drifting against it.
                        .offset(y: diameter * 0.85 + 12)
                }
                .position(point)
            }
        }
    }

    /// Start orbs are interactive-green; RESET is the accent. The two greens
    /// never appear together — start orbs show while idle/finished, RESET
    /// only mid-run — and every orb carries its text label regardless.
    private func orbColor(_ orb: TrainingOrb) -> Color {
        switch orb.action {
        case .start: return .ltnPrimary
        case .reset: return .ltnAccent
        }
    }

    /// Slow breathing glow, 2 s period.
    private func pulsePhase(at date: Date) -> Double {
        (sin(date.timeIntervalSinceReferenceDate * .pi) + 1) / 2
    }

    // MARK: - Counter

    @ViewBuilder
    private func counterPanel(_ projector: Projector) -> some View {
        if let center = range.consoleCenter,
           let point = projector.point(center + simd_float3(0, TrainingRange.counterLift, 0)) {
            VStack(spacing: Space.xxs) {
                Text("\(range.kills) / \(TrainingRange.dronesPerRun)")
                    .font(.appBold(.title2).monospacedDigit())
                    .foregroundStyle(Color.ltnText)
                if range.state == .running {
                    Text(range.difficulty.label)
                        .font(.app(.caption2))
                        .foregroundStyle(Color.ltnTextSecondary)
                } else if range.state == .finished {
                    Text(resultLine)
                        .font(.app(.caption2).monospacedDigit())
                        .foregroundStyle(Color.ltnTextSecondary)
                    Text("Shoot an orb to go again")
                        .font(.app(.caption2))
                        .foregroundStyle(Color.ltnTextTertiary)
                } else {
                    Text("Shoot an orb to start")
                        .font(.app(.caption2))
                        .foregroundStyle(Color.ltnTextSecondary)
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .background(Color.ltnBackground.opacity(Alpha.strong),
                        in: RoundedRectangle(cornerRadius: Radius.md))
            .position(point)
        }
    }

    private var resultLine: String {
        var parts: [String] = []
        if let accuracy = range.accuracy {
            parts.append("ACC \(Int((accuracy * 100).rounded()))%")
        }
        parts.append(range.runDuration.clockString)
        parts.append(range.difficulty.label)
        return parts.joined(separator: " · ")
    }

    // MARK: - Drone

    @ViewBuilder
    private func droneLayer(_ projector: Projector, at date: Date) -> some View {
        ForEach(range.drones) { drone in
            if let point = projector.point(drone.position),
               let radius = projector.screenLength(TrainingRange.droneRadius, at: drone.position) {
                let diameter = min(max(radius * 2, 40), 104)
                // Pop-in: the sprite grows to size over its first quarter
                // second, driven statelessly off spawn age so TimelineView
                // redraws stay cheap. Reduce Motion keeps it full-size and
                // fades instead.
                let age = drone.age(at: date)
                let pop = reduceMotion ? 1 : min(1, 0.4 + (age / 0.25) * 0.6)
                ZStack {
                    DroneSprite(diameter: diameter,
                                remaining: drone.remainingFraction(at: date))
                        .scaleEffect(pop)
                    // Four hearts, fixed geometry like the enemy tags — chrome
                    // read at a distance over a moving feed. Tight against the
                    // ring: the drone glyph fills most of the disc, so a gap
                    // measured off the disc's edge reads as a bar floating in
                    // space next to the target rather than belonging to it.
                    HeartBar(fraction: CGFloat(drone.hp) / CGFloat(TrainingDrone.maxHP),
                             total: TrainingDrone.maxHP, size: 11)
                        .shadow(color: Color.ltnBackground.opacity(Alpha.strong), radius: 2, y: 1)
                        .offset(y: -(diameter / 2 + 9))
                }
                .opacity(min(1, age / 0.15))
                .position(point)
            }
        }
    }

    /// Expanding ring where the last drone died. Brief and stateless — age
    /// drives the geometry, so it needs no transition bookkeeping.
    @ViewBuilder
    private func killBurst(_ projector: Projector, at date: Date) -> some View {
        if let kill = range.lastKill,
           case let age = date.timeIntervalSince(kill.at), age < 0.45,
           let point = projector.point(kill.position) {
            let progress = age / 0.45
            Circle()
                .stroke(Color.ltnDanger, lineWidth: 3)
                .frame(width: reduceMotion ? 56 : 24 + 72 * progress)
                .opacity(1 - progress)
                .position(point)
        }
    }
}

/// Screen-space projection through one ARFrame, shared by every element so
/// a single frame's pose positions the whole layer consistently.
private struct Projector {
    let frame: ARFrame
    let viewport: CGSize

    /// Screen point for a world position, or nil when it's behind the lens
    /// (mirrored ghost) or far off screen.
    func point(_ world: simd_float3) -> CGPoint? {
        let inCamera = frame.camera.transform.inverse * simd_float4(world, 1)
        guard inCamera.z < 0 else { return nil }
        let point = frame.camera.projectPoint(
            world, orientation: .portrait, viewportSize: viewport)
        guard point.x > -80, point.x < viewport.width + 80,
              point.y > -80, point.y < viewport.height + 80 else { return nil }
        return point
    }

    /// On-screen length of a world-space distance at `world` — projects the
    /// point and an offset twin, so sprites size with perspective under
    /// whatever FoV the camera actually has.
    ///
    /// The offset runs along the *camera's* up axis, not gravity's. A
    /// gravity-up twin foreshortens with pitch: tilt the phone 40° down and
    /// the same sphere measures 23% smaller, point it at the floor and the
    /// length collapses to nothing. Anything sized or offset by this — sprite
    /// diameters, the label below an orb, the hearts above a drone — then
    /// slides and breathes as the player tilts, which reads as the targets
    /// drifting vertically in the world. The camera's own up axis is always
    /// perpendicular to the view direction, so the measurement depends on
    /// distance alone.
    func screenLength(_ meters: Float, at world: simd_float3) -> CGFloat? {
        let transform = frame.camera.transform
        let inCamera = transform.inverse * simd_float4(world, 1)
        guard inCamera.z < 0 else { return nil }
        let up = simd_float3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        let a = frame.camera.projectPoint(world, orientation: .portrait, viewportSize: viewport)
        let b = frame.camera.projectPoint(world + up * meters,
                                          orientation: .portrait, viewportSize: viewport)
        return hypot(a.x - b.x, a.y - b.y)
    }
}

/// A glowing console control: soft halo, lit core, breathing shadow. Composed
/// of plain circles — game-world geometry over the feed, same family as the
/// reticle, not icon art.
private struct OrbSprite: View {
    let color: Color
    let diameter: CGFloat
    /// 0…1 breathing phase; 0 renders the resting glow (Reduce Motion).
    let pulse: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(Alpha.subtle))
                .frame(width: diameter * 1.7, height: diameter * 1.7)
            Circle()
                .fill(color)
                .frame(width: diameter, height: diameter)
                .shadow(color: color.opacity(Alpha.strong), radius: 8 + 6 * pulse)
            // Specular catch so the disc reads as a sphere, not a dot.
            Circle()
                .fill(Color.ltnText.opacity(Alpha.muted))
                .frame(width: diameter * 0.28, height: diameter * 0.28)
                .offset(x: -diameter * 0.18, y: -diameter * 0.18)
        }
    }
}

/// The pop-up target: drone glyph on a scrim disc, ringed by its escape
/// clock draining from 12 o'clock — the same "how long this lasts" language
/// as the consumable markers, in the enemy red.
private struct DroneSprite: View {
    let diameter: CGFloat
    /// 1 → 0 lifetime remaining.
    let remaining: Double

    /// `drone.fill` shipped with SF Symbols 6 (iOS 18); on the iOS 17 floor
    /// fall back to the bullseye rather than an empty image.
    private static let symbol =
        UIImage(systemName: "drone.fill") != nil ? "drone.fill" : "target"

    private var ringWidth: CGFloat { max(2, diameter / 14) }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.ltnBackground.opacity(Alpha.strong))
            // The track is what makes the body's edge readable once the clock
            // has drained — at Alpha.subtle a nearly-escaped drone lost its
            // outline entirely, leaving a small glyph with the health bar
            // apparently floating clear of it.
            Circle()
                .stroke(Color.ltnText.opacity(Alpha.muted), lineWidth: ringWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, remaining)))
                .stroke(Color.ltnDanger,
                        style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: Self.symbol)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.ltnDanger)
                .frame(width: diameter * 0.64, height: diameter * 0.64)
        }
        .frame(width: diameter, height: diameter)
    }
}
