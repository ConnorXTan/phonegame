import CoreMotion
import Foundation

/// Solo-practice virtual target. Anchored at a fixed bearing in the real
/// world via CoreMotion, so rotating the phone sweeps it across your sights
/// exactly like a stationary player would — turn away and it stays put.
/// Distance is fixed (rotation only is simulated); readings feed the normal
/// ranging pipeline as synthetic samples, so aim lock, hit resolution, the
/// radar, and the debug sheet all treat it like a real peer.
final class TargetDummy {
    static let name = "Target Dummy"
    static let distance: Float = 5.0
    private static let fov = Double.pi / 3   // ±60°, ≈ the UWB FoV cone

    var onReading: ((RangingReading) -> Void)?

    private let motion = CMMotionManager()
    private var fallbackTimer: Timer?
    private var bearing: Double?    // world bearing the dummy is pinned to
    private var lastAim: Double?

    func spawn() {
        bearing = nil
        lastAim = nil
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 30.0
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] deviceMotion, _ in
                guard let self, let deviceMotion else { return }
                self.emit(from: deviceMotion)
            }
        } else {
            // No motion hardware (simulator): dummy sits dead ahead.
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.onReading?(RangingReading(
                    timestamp: Date(), distance: Self.distance,
                    direction: nil, horizontalAngle: 0))
            }
            RunLoop.main.add(timer, forMode: .common)
            fallbackTimer = timer
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    /// Jump the dummy 60–180° away so you have to hunt for it after a kill.
    func relocate() {
        guard let b = bearing else { return }
        let jump = Double.random(in: (.pi / 3)...(.pi)) * (Bool.random() ? 1 : -1)
        bearing = Self.wrapToPi(b + jump)
    }

    private func emit(from deviceMotion: CMDeviceMotion) {
        // Aim = the back of the phone (device -Z) in world coordinates.
        // attitude.rotationMatrix maps world -> device, so device -Z expressed
        // in the world frame is the negated third row.
        let m = deviceMotion.attitude.rotationMatrix
        let bx = -m.m31, by = -m.m32
        var aim: Double
        if bx * bx + by * by > 0.04 {       // back vector horizontal enough
            aim = atan2(by, bx)
            lastAim = aim
        } else if let held = lastAim {
            aim = held                       // phone near-flat: hold last aim
        } else {
            return                           // no usable aim yet
        }
        if bearing == nil { bearing = aim }  // spawn straight ahead of you
        let delta = Self.wrapToPi(aim - bearing!)   // signed; + = to your right
        let visible = abs(delta) < Self.fov
        onReading?(RangingReading(
            timestamp: Date(),
            distance: Self.distance,
            direction: nil,
            horizontalAngle: visible ? Float(delta) : nil))
    }

    private static func wrapToPi(_ x: Double) -> Double {
        var r = x.truncatingRemainder(dividingBy: 2 * .pi)
        if r > .pi { r -= 2 * .pi }
        if r < -.pi { r += 2 * .pi }
        return r
    }
}
