import ARKit
import AVFoundation
import Combine
import CoreImage
import CoreMedia
import Foundation
import ImageIO

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

    let session = ARSession()

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
        let scale = 480 / image.extent.width
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: [quality: 0.5])
    }

    /// The configuration NearbyInteraction accepts for camera assistance —
    /// anything else invalidates the NISession with `.invalidARConfiguration`.
    private static func makeConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.isCollaborationEnabled = false
        config.userFaceTrackingEnabled = false
        config.initialWorldMap = nil
        config.planeDetection = []          // nothing is rendered; skip the work
        config.environmentTexturing = .none
        return config
    }
}

extension AimCameraManager: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard frameTap != nil, !encodingInFlight,
              Date().timeIntervalSince(lastTapAt) >= 1.0 / 12.0 else { return }
        lastTapAt = Date()
        encodingInFlight = true
        let buffer = frame.capturedImage
        encodeQueue.async { [weak self] in
            guard let self else { return }
            let jpeg = self.encodeJPEG(buffer)
            DispatchQueue.main.async {
                self.encodingInFlight = false
                if let jpeg { self.frameTap?(jpeg) }
            }
        }
    }
}
