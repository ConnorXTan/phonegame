import ARKit
import AVFoundation
import Combine
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import simd

/// A detected wall flattened to the floor: the vertical plane's footprint as a
/// world-space XZ segment, in metres. Purely visual — walls draw on the
/// minimap, but whether a shot connects through one stays a property of the
/// UWB signal itself, never of this geometry.
struct WallSegment {
    let start: SIMD2<Float>
    let end: SIMD2<Float>
}

/// The camera flattened onto the floor: where the player stands and which way
/// the aim (out the back of the phone) points, in world XZ metres.
struct GroundPose {
    let position: SIMD2<Float>
    let forward: SIMD2<Float>                              // unit
    var right: SIMD2<Float> { SIMD2(-forward.y, forward.x) }
}

/// Owns the one ARSession the app runs. It does double duty: it draws the
/// viewfinder behind the HUD *and* feeds NearbyInteraction's camera assistance.
///
/// This has to be shared. With `isCameraAssistanceEnabled` set, NISession
/// creates its own hidden ARSession unless handed one — and two AR sessions (or
/// an AVCaptureSession alongside ARKit) fight over the back camera, so whoever
/// starts second gets interrupted. RangingManager therefore calls
/// `setARSession(_:)` with this session before every `run(_:)`.
///
/// Main-thread only: `isRunning` drives SwiftUI, and every caller (GameEngine,
/// RangingManager's main-dispatched callbacks, the HUD) is already on main.
final class AimCameraManager: NSObject, ObservableObject {

    /// Live only while the session is delivering frames — the viewfinder falls
    /// back to an explanation panel otherwise.
    @Published private(set) var isRunning = false

    /// Spectator streaming: when set, receives downscaled JPEG frames on the
    /// main queue at ~12 fps. Nil (the normal state) costs nothing per frame.
    var frameTap: ((Data) -> Void)?

    /// Killcam capture: while enabled, a rolling ~5 s of viewfinder JPEGs is
    /// kept (8 fps × 40 frames ≈ 1 MB), each paired with the HUD overlay
    /// (crosshair + enemy tags) at that instant. Snapshotted the moment a
    /// kill confirms; the encode pipeline is shared with the spectator tap.
    var clipBufferEnabled = false {
        didSet { if !clipBufferEnabled { clipBuffer.removeAll() } }
    }
    /// Asked (on main) for the current HUD overlay as each frame lands.
    var clipOverlayProvider: (() -> SpectatorOverlayState?)?
    private var clipBuffer: [(jpeg: Data, overlay: SpectatorOverlayState)] = []
    private var lastClipAt = Date.distantPast
    static let clipFrameInterval: TimeInterval = 1.0 / 8.0
    private static let clipFrameCount = 40

    /// The last ~5 s of viewfinder, oldest first, with per-frame overlays.
    func snapshotClip() -> (frames: [Data], overlays: [SpectatorOverlayState]) {
        (clipBuffer.map(\.jpeg), clipBuffer.map(\.overlay))
    }

    let session = ARSession()

    /// Vertical plane anchors by identifier, from the session delegate. ARKit
    /// grows, merges, and removes these as it sees more of the room, so the
    /// map fills in progressively as the player looks around.
    private var verticalPlanes: [UUID: ARPlaneAnchor] = [:]

    /// Fast-feedback wall marks, keyed by a coarse (0.75 m) world grid cell.
    /// Plane anchors need seconds of parallax and wall texture before ARKit
    /// promotes them — on a phone without LiDAR, often never for blank walls.
    /// Raycasts against *estimated* planes answer from the current feature
    /// cloud in under a second, so aiming at a wall marks it almost at once.
    private var wallChips: [SIMD2<Int>: WallSegment] = [:]
    private var lastChipSampleAt = Date.distantPast

    private let encodeQueue = DispatchQueue(label: "echo.frame-encode")
    private let ciContext = CIContext()
    private var encodingInFlight = false
    private var lastTapAt = Date.distantPast

    override init() {
        super.init()
        session.delegate = self   // NI camera assistance ignores the delegate; safe to claim
    }

    /// ARKit needs an A9+ device; it is also unavailable in the simulator.
    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    var authorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Why there's no picture, or nil when the feed is fine.
    var unavailableReason: String? {
        if isRunning { return nil }
        if !Self.isSupported { return "This device can't run the camera viewfinder." }
        switch authorization {
        case .denied, .restricted:
            return "Camera access is off. Enable it in Settings → Apps → Echo → Camera to see what you're aiming at."
        case .notDetermined:
            return "Waiting for camera access…"
        default:
            return "Starting camera…"
        }
    }

    /// True when sending the player to Settings would actually fix it.
    var isBlockedByPermission: Bool {
        authorization == .denied || authorization == .restricted
    }

    // MARK: - Lifecycle

    /// Prompt for camera access from the lobby, so the alert isn't racing the
    /// first `NISession.run(_:)` at match start.
    func requestAccessIfNeeded() {
        guard Self.isSupported, authorization == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }

    /// Start (idempotently) and return the session to share with NISession, or
    /// nil when the camera is unusable — in which case NI is left to its own
    /// devices, exactly as before.
    @discardableResult
    func start() -> ARSession? {
        guard Self.isSupported, !isBlockedByPermission else {
            stop()
            return nil
        }
        guard !isRunning else { return session }
        // ARKit raises the camera permission prompt itself if it's still
        // undetermined, and starts delivering frames once it's granted.
        verticalPlanes = [:]   // .removeExistingAnchors wipes them in ARKit too
        wallChips = [:]        // chips live in the old world frame; resetTracking orphans them
        session.run(Self.makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
        applyExposureCap()
        isRunning = true
        return session
    }

    /// Re-run after returning from the background, keeping tracking (and so
    /// NI's convergence) rather than resetting it.
    func resume() {
        guard isRunning else { start(); return }
        session.run(Self.makeConfiguration())
        applyExposureCap()
    }

    func stop() {
        guard isRunning else { return }
        session.pause()
        isRunning = false
    }

    // MARK: - Walls (minimap)

    /// Detected walls as floor-plan segments: anchored planes plus raycast
    /// chips. Chips are provisional — once a real anchor covers that wall its
    /// segment draws instead, so the same wall never double-strokes.
    var wallSegments: [WallSegment] {
        let anchored = anchoredSegments
        let chips = wallChips.values.filter { chip in
            let mid = (chip.start + chip.end) / 2
            return !anchored.contains { Self.distance(mid, toSegment: $0.start, $0.end) < 0.7 }
        }
        return anchored + chips
    }

    /// Seen from above, a vertical rectangle collapses to a line — the two
    /// projected corners farthest apart are that line, whichever local axis
    /// ARKit made the "width".
    private var anchoredSegments: [WallSegment] {
        verticalPlanes.values.compactMap { anchor in
            let extent = anchor.planeExtent
            // Corners of the extent rectangle (rotated about local Y) in
            // anchor space, pushed to world and flattened to the floor.
            let rot = extent.rotationOnYAxis
            let axisX = SIMD3<Float>(cos(rot), 0, -sin(rot)) * (extent.width / 2)
            let axisZ = SIMD3<Float>(sin(rot), 0, cos(rot)) * (extent.height / 2)
            let corners = [axisX + axisZ, axisX - axisZ, -axisX + axisZ, -axisX - axisZ]
                .map { corner -> SIMD2<Float> in
                    let world = anchor.transform * SIMD4<Float>(anchor.center + corner, 1)
                    return SIMD2(world.x, world.z)
                }
            var best: (a: SIMD2<Float>, b: SIMD2<Float>, d: Float) = (corners[0], corners[0], -1)
            for i in corners.indices {
                for j in (i + 1)..<corners.count {
                    let d = simd_distance_squared(corners[i], corners[j])
                    if d > best.d { best = (corners[i], corners[j], d) }
                }
            }
            // Only degenerate (near-point) footprints are dropped: an early
            // anchor is small, and hiding it until it grows reads as "wall
            // detection doesn't work" to the player aiming right at it.
            guard best.d > 0.01 else { return nil }
            return WallSegment(start: best.a, end: best.b)
        }
    }

    /// Instant wall feedback where the player aims. Three rays across the
    /// centre of the view a few times a second; each estimated-plane hit
    /// drops a short chip into the world grid. Newest hit wins its cell, so
    /// re-aiming refreshes rather than duplicates.
    private func sampleWallChips(_ frame: ARFrame) {
        guard Date().timeIntervalSince(lastChipSampleAt) >= 0.25 else { return }
        guard case .normal = frame.camera.trackingState else { return }   // initializing/relocalizing rays are garbage
        lastChipSampleAt = Date()
        // Normalized image coordinates; a spread on one image axis crosses
        // the screen whichever way the sensor is rotated under the display.
        for point in [CGPoint(x: 0.5, y: 0.3), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.7)] {
            let query = frame.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .vertical)
            guard let hit = session.raycast(query).first else { continue }
            let t = hit.worldTransform
            let normal = SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z)
            guard abs(normal.y) < 0.5 else { continue }   // slanted surface, not a wall
            let position = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let cam = frame.camera.transform.columns.3
            let range = simd_distance(SIMD3<Float>(cam.x, cam.y, cam.z), position)
            guard range > 0.5, range < 10 else { continue }   // estimated depth degrades fast past ~10 m
            // The wall's horizontal run: up × normal, flattened to the floor.
            var tangent = SIMD2<Float>(normal.z, -normal.x)
            let length = simd_length(tangent)
            guard length > 0.001 else { continue }
            tangent /= length
            let ground = SIMD2<Float>(position.x, position.z)
            let cell = SIMD2<Int>(Int((ground.x / 0.75).rounded()), Int((ground.y / 0.75).rounded()))
            wallChips[cell] = WallSegment(start: ground - tangent * 0.4, end: ground + tangent * 0.4)
        }
    }

    private static func distance(_ p: SIMD2<Float>, toSegment a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 0 else { return simd_distance(p, a) }
        let t = max(0, min(1, simd_dot(p - a, ab) / lengthSquared))
        return simd_distance(p, a + ab * t)
    }

    /// Nil until ARKit delivers frames, or while the phone points straight
    /// up/down (aim has no floor-plane heading to project).
    var groundPose: GroundPose? {
        guard isRunning, let camera = session.currentFrame?.camera else { return nil }
        let t = camera.transform
        // The camera looks along its own -Z regardless of device roll, so
        // this works in portrait without any device-frame gymnastics.
        var forward = SIMD2<Float>(-t.columns.2.x, -t.columns.2.z)
        let length = simd_length(forward)
        guard length > 0.1 else { return nil }
        forward /= length
        return GroundPose(position: SIMD2(t.columns.3.x, t.columns.3.z), forward: forward)
    }

    // MARK: - Exposure cap (U2 aim responsiveness)

    /// Ceiling on auto-exposure's shutter time, or nil to leave ARKit's
    /// auto-exposure untouched (the original behavior — flip here to A/B).
    ///
    /// Why: in low light the camera holds the shutter open, which smears each
    /// frame — and on U2 iPhones (15/16) that same blurry frame is what ARKit
    /// fuses into the aim bearing, so the smear *is* aim lag. Capping only the
    /// *max* means it bites solely when auto-exposure would otherwise go long
    /// (dim light); in good light auto-exposure is already faster, so the
    /// picture is unchanged. When it does bite, the cost is a darker/noisier
    /// frame — the sweet spot is venue-dependent, so tune this on-device.
    /// Too aggressive backfires: dark, noisy frames also degrade ARKit feature
    /// tracking, making the bearing worse instead of better.
    static let maxExposureDuration: CMTime? = CMTime(value: 1, timescale: 120)   // ≤ 1/120 s

    /// ARKit owns the capture device and re-configures it on every run(), so
    /// this is re-applied after each start()/resume(). No-op when the cap is
    /// nil or the device can't be configured (e.g. simulator).
    private func applyExposureCap() {
        guard let cap = Self.maxExposureDuration,
              let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera
        else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            // Clamp into the active format's legal range; setting an out-of-range
            // duration throws and would leave exposure uncapped.
            let format = device.activeFormat
            device.activeMaxExposureDuration = CMTimeMaximum(
                format.minExposureDuration,
                CMTimeMinimum(cap, format.maxExposureDuration))
        } catch {
            print("[Camera] exposure cap failed: \(error)")
        }
    }

    // MARK: - Private

    private func encodeJPEG(_ buffer: CVPixelBuffer) -> Data? {
        // Sensor frames are landscape; the game is portrait.
        var image = CIImage(cvPixelBuffer: buffer).oriented(.right)
        let scale = 416 / image.extent.width
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: [quality: 0.45])
    }

    /// The configuration NearbyInteraction accepts for camera assistance. NI
    /// constrains exactly four properties — gravity alignment, no
    /// collaboration, no face tracking, no initial world map; breaking those
    /// invalidates the NISession with `.invalidARConfiguration`. Plane
    /// detection is outside that set, so wall tracking rides the same session.
    private static func makeConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.isCollaborationEnabled = false
        config.userFaceTrackingEnabled = false
        config.initialWorldMap = nil
        config.planeDetection = [.vertical]   // walls for the minimap; floors stay off — nothing uses them
        config.environmentTexturing = .none
        return config
    }
}

extension AimCameraManager: ARSessionDelegate {
    // Anchor callbacks arrive on the main queue (no delegateQueue is set),
    // matching this class's main-thread-only contract. A merge shows up as a
    // remove of one plane plus a grow of its survivor, so the dictionary
    // never keeps both halves of a merged wall.
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { trackWalls(in: anchors) }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { trackWalls(in: anchors) }
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors { verticalPlanes[anchor.identifier] = nil }
    }

    private func trackWalls(in anchors: [ARAnchor]) {
        for case let plane as ARPlaneAnchor in anchors where plane.alignment == .vertical {
            verticalPlanes[plane.identifier] = plane
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        sampleWallChips(frame)
        // One encode pipeline, two consumers with their own cadences: the
        // spectator tap (≤20 fps; ack pacing is the real governor) and the
        // killcam ring buffer (8 fps).
        let now = Date()
        let tapDue = frameTap != nil && now.timeIntervalSince(lastTapAt) >= 1.0 / 20.0
        let clipDue = clipBufferEnabled && now.timeIntervalSince(lastClipAt) >= Self.clipFrameInterval
        guard tapDue || clipDue, !encodingInFlight else { return }
        if tapDue { lastTapAt = now }
        if clipDue { lastClipAt = now }
        encodingInFlight = true
        let buffer = frame.capturedImage
        encodeQueue.async { [weak self] in
            guard let self else { return }
            let jpeg = self.encodeJPEG(buffer)
            DispatchQueue.main.async {
                self.encodingInFlight = false
                guard let jpeg else { return }
                if tapDue { self.frameTap?(jpeg) }
                if clipDue, self.clipBufferEnabled {
                    let overlay = self.clipOverlayProvider?()
                        ?? SpectatorOverlayState(tags: [], lockedTarget: nil)
                    self.clipBuffer.append((jpeg, overlay))
                    if self.clipBuffer.count > Self.clipFrameCount {
                        self.clipBuffer.removeFirst(self.clipBuffer.count - Self.clipFrameCount)
                    }
                }
            }
        }
    }
}
