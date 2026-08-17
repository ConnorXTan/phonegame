import ARKit
import CoreGraphics
import simd

/// Screen-space projection through one ARFrame.
///
/// Shared on purpose. Anything that touches a world anchor — the sprite the
/// player sees, the aim test the trigger runs, the size the sprite is drawn at
/// — has to resolve it through the same pose and the same viewport, or the
/// picture and the hit test drift apart and the player is left aiming at empty
/// air next to the target.
struct CameraProjector {
    let frame: ARFrame
    let viewport: CGSize

    init?(frame: ARFrame?, viewport: CGSize) {
        guard let frame, viewport.width > 0, viewport.height > 0 else { return nil }
        self.frame = frame
        self.viewport = viewport
    }

    /// Where the crosshair is. The player aims by what the screen shows, so
    /// the aim point is the reticle's own position — dead center of the
    /// viewport the sprites project into — rather than a re-derived world
    /// axis that only *ought* to land there.
    var aimPoint: CGPoint { CGPoint(x: viewport.width / 2, y: viewport.height / 2) }

    /// Screen point for a world position, or nil when it sits behind the lens
    /// — a point behind the camera plane projects to a mirrored ghost that
    /// would otherwise read as dead ahead.
    func project(_ world: simd_float3) -> CGPoint? {
        let inCamera = frame.camera.transform.inverse * simd_float4(world, 1)
        guard inCamera.z < 0 else { return nil }
        return frame.camera.projectPoint(world, orientation: .portrait, viewportSize: viewport)
    }

    /// `project`, additionally dropping anchors far enough outside the
    /// viewport that laying a sprite out for them is wasted work.
    func visiblePoint(_ world: simd_float3, margin: CGFloat = 80) -> CGPoint? {
        guard let point = project(world),
              point.x > -margin, point.x < viewport.width + margin,
              point.y > -margin, point.y < viewport.height + margin else { return nil }
        return point
    }

    /// On-screen length of a world-space distance at `world`, so sprites size
    /// with perspective under whatever FoV the camera actually has.
    ///
    /// The offset runs along the *camera's* up axis, not gravity's. A
    /// gravity-up twin foreshortens with pitch: tilt the phone 40° down and
    /// the same sphere measures 23% smaller, point it at the floor and the
    /// length collapses to nothing — so every size and offset derived from it
    /// breathes as the player tilts, which reads as the target drifting. The
    /// camera's own up axis is always perpendicular to the view direction, so
    /// the measurement depends on distance alone.
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

    /// An aim cone's radius in viewport points, measured off the live
    /// projection: project the boresight at an arbitrary depth and a second
    /// point exactly `coneRadians` off it. Deriving it rather than assuming a
    /// focal length keeps the cone in the same space the sprites land in.
    func coneRadius(_ coneRadians: Float) -> CGFloat {
        let t = frame.camera.transform
        let origin = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let axis = -simd_float3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        let up = simd_float3(t.columns.1.x, t.columns.1.y, t.columns.1.z)
        let depth: Float = 3   // any depth works — the angle is what's being measured
        let center = origin + axis * depth
        let edge = center + up * (depth * tan(coneRadians))
        let a = frame.camera.projectPoint(center, orientation: .portrait, viewportSize: viewport)
        let b = frame.camera.projectPoint(edge, orientation: .portrait, viewportSize: viewport)
        return hypot(a.x - b.x, a.y - b.y)
    }
}
