import ARKit
import Foundation
import NearbyInteraction
import simd

struct RangingReading {
    let timestamp: Date
    let distance: Float?          // meters
    let direction: simd_float3?   // unit vector in phone coordinates; nil = out of FoV
    let horizontalAngle: Float?   // radians, from camera assistance

    /// Radians off boresight. Boresight = straight out the BACK of the phone,
    /// which is -Z in the device coordinate frame (aim like taking a photo).
    /// U2 devices (iPhone 15/16) often deliver only the camera-assisted
    /// horizontalAngle rather than a full direction vector — use it as the
    /// aim angle so those phones can still shoot.
    var angleOffBoresight: Float? {
        if let d = direction { return acos(max(-1, min(1, -d.z))) }
        if let h = horizontalAngle { return abs(h) }
        return nil
    }
}

protocol RangingManagerDelegate: AnyObject {
    /// The NI session for this peer died and was recreated. Send `tokenData`
    /// to the peer so both sides can re-pair with fresh tokens.
    func ranging(_ manager: RangingManager, resendToken tokenData: Data, to peerName: String)
    /// Ranging stopped for good — permission denial (peerName == nil, all
    /// ranging is down) or a session that keeps dying. Surface it to the user.
    func ranging(_ manager: RangingManager, failedPermanently reason: String, forPeer peerName: String?)
}

/// One NISession per peer — UWB sessions are pairwise, and discovery tokens
/// are per-session, so each peer receives a *different* token from us. The
/// pairing is (our session for X) ⟷ (X's session for us).
///
/// Readings are buffered per peer (~1 s) so hit resolution can look back
/// ~0.3 s and a single nil-direction frame doesn't eat a shot.
final class RangingManager: NSObject, ObservableObject {

    private final class PeerRanging {
        let session: NISession
        var sentToken = false
        var peerToken: NIDiscoveryToken?
        var peerTokenData: Data?          // for duplicate detection
        var readings: [RangingReading] = []
        var latestObject: NINearbyObject? // for worldTransform(for:) lookups
        init(session: NISession) { self.session = session }
    }

    weak var delegate: RangingManagerDelegate?

    /// The viewfinder's ARSession, shared with every NISession so camera
    /// assistance and the on-screen picture come from the same camera feed.
    /// Set by GameEngine right after init.
    var camera: AimCameraManager?

    @Published private(set) var peerNames: [String] = []

    private var peers: [String: PeerRanging] = [:]
    private var invalidationStreaks: [String: Int] = [:]
    private var syntheticReadings: [String: [RangingReading]] = [:]   // solo-practice targets, no NISession

    /// U2 devices aim via camera assistance, which needs ARKit to converge
    /// before direction data flows. Per-peer human-readable hint while not
    /// converged; nil once ready. Polled by the aim timer and debug view.
    private(set) var convergenceHints: [String: String] = [:]

    var anyConvergenceHint: String? { convergenceHints.values.first }

    func convergenceHint(for name: String) -> String? { convergenceHints[name] }

    static var isSupported: Bool {
        NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
    }

    /// Raw UWB angle-of-arrival (U1 chips) OR camera-assisted direction (U2
    /// chips report supportsDirectionMeasurement == false but deliver
    /// direction/horizontalAngle once camera assistance is running).
    static var supportsAiming: Bool {
        NISession.deviceCapabilities.supportsDirectionMeasurement
            || NISession.deviceCapabilities.supportsCameraAssistance
    }

    // MARK: - Token exchange

    /// Ensure a session exists for the peer and return our archived discovery
    /// token for them — or nil if it was already handed out (or unsupported).
    func prepare(peerName: String) -> Data? {
        let pr = peers[peerName] ?? makePeer(peerName)
        guard !pr.sentToken,
              let token = pr.session.discoveryToken,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        else { return nil }
        pr.sentToken = true
        return data
    }

    /// Handle a token arriving from a peer. Returns our own token data to send
    /// back if our side had to (re)create its session, else nil. The
    /// recreate-and-reply rule converges in one round trip and cannot loop:
    /// only a side already ranging against a *stale* token recreates.
    func receiveToken(_ data: Data, from peerName: String) -> Data? {
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) else {
            print("[Ranging] bad token from \(peerName)")
            return nil
        }

        var reply: Data?
        var pr: PeerRanging
        if let existing = peers[peerName] {
            if existing.peerTokenData == data { return nil }   // duplicate, already paired
            if existing.peerTokenData != nil {
                // Peer restarted its session; ours is paired with a stale token.
                existing.session.invalidate()   // manual invalidate → no delegate callback
                pr = makePeer(peerName)
                reply = prepare(peerName: peerName)
            } else {
                pr = existing
            }
        } else {
            pr = makePeer(peerName)
            reply = prepare(peerName: peerName)
        }

        pr.peerToken = token
        pr.peerTokenData = data
        run(pr)
        return reply
    }

    // MARK: - Readings

    func latestReading(for peerName: String) -> RangingReading? {
        readings(for: peerName).last
    }

    /// Freshest reading with a usable aim angle within `window` seconds.
    func latestDirectional(for peerName: String, within window: TimeInterval) -> RangingReading? {
        let cutoff = Date().addingTimeInterval(-window)
        return readings(for: peerName).last {
            $0.timestamp >= cutoff && ($0.direction != nil || $0.horizontalAngle != nil)
        }
    }

    /// Peer's position in the shared ARSession's world coordinates — the
    /// camera-assistance fusion result, re-projectable at frame rate. Nil
    /// until convergence, and always nil for synthetic targets (no NISession
    /// behind them) — callers fall back to the raw readings.
    func worldPosition(for peerName: String) -> simd_float3? {
        guard let pr = peers[peerName],
              let object = pr.latestObject,
              let transform = pr.session.worldTransform(for: object) else { return nil }
        let t = transform.columns.3
        return simd_float3(t.x, t.y, t.z)
    }

    /// Readings per second over the last second — for the debug view.
    func sampleRate(for peerName: String) -> Int {
        let cutoff = Date().addingTimeInterval(-1)
        return readings(for: peerName).filter { $0.timestamp >= cutoff }.count
    }

    // MARK: - Synthetic targets (solo practice)

    func injectSyntheticReading(_ reading: RangingReading, for name: String) {
        var buffer = syntheticReadings[name] ?? []
        buffer.append(reading)
        let cutoff = Date().addingTimeInterval(-1)
        buffer.removeAll { $0.timestamp < cutoff }
        syntheticReadings[name] = buffer
        if !peerNames.contains(name) { peerNames.append(name) }
    }

    func removeSynthetic(_ name: String) {
        syntheticReadings[name] = nil
        peerNames.removeAll { $0 == name }
    }

    // MARK: - Lifecycle

    func removePeer(_ name: String) {
        peers[name]?.session.invalidate()
        peers[name] = nil
        peerNames.removeAll { $0 == name }
        invalidationStreaks[name] = nil
        convergenceHints[name] = nil
    }

    func stopAll() {
        peers.values.forEach { $0.session.invalidate() }
        peers = [:]
        peerNames = []
        invalidationStreaks = [:]
        syntheticReadings = [:]
        convergenceHints = [:]
    }

    // MARK: - Private

    private func makePeer(_ name: String) -> PeerRanging {
        let session = NISession()
        session.delegate = self
        let pr = PeerRanging(session: session)
        peers[name] = pr
        if !peerNames.contains(name) { peerNames.append(name) }
        return pr
    }

    private func run(_ pr: PeerRanging) {
        guard let token = pr.peerToken else { return }
        let config = NINearbyPeerConfiguration(peerToken: token)
        if NISession.deviceCapabilities.supportsCameraAssistance {
            config.isCameraAssistanceEnabled = true   // widens FoV, adds horizontalAngle
            // Hand over the viewfinder's session, already running. Skipping
            // this makes NI create a hidden ARSession of its own, which would
            // then fight the on-screen one for the camera.
            if let arSession = camera?.start() {
                pr.session.setARSession(arSession)
            }
        }
        pr.session.run(config)
    }

    private func peerName(for session: NISession) -> String? {
        peers.first { $0.value.session === session }?.key
    }

    private func readings(for peerName: String) -> [RangingReading] {
        peers[peerName]?.readings ?? syntheticReadings[peerName] ?? []
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

extension RangingManager: NISessionDelegate {
    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        onMain {
            guard let name = self.peerName(for: session),
                  let pr = self.peers[name],
                  let obj = nearbyObjects.first else { return }
            self.invalidationStreaks[name] = 0   // session is healthy again
            pr.latestObject = obj
            pr.readings.append(RangingReading(
                timestamp: Date(),
                distance: obj.distance,
                direction: obj.direction,
                horizontalAngle: obj.horizontalAngle))
            let cutoff = Date().addingTimeInterval(-1)
            if pr.readings.first.map({ $0.timestamp < cutoff }) == true {
                pr.readings.removeAll { $0.timestamp < cutoff }
            }
        }
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        onMain {
            guard let name = self.peerName(for: session), let pr = self.peers[name] else { return }
            pr.readings.removeAll()
            pr.latestObject = nil
            if reason == .timeout {
                self.run(pr)   // retry ranging with the same tokens
            }
        }
    }

    func session(_ session: NISession, didUpdateAlgorithmConvergence convergence: NIAlgorithmConvergence, for object: NINearbyObject?) {
        onMain {
            guard let name = self.peerName(for: session) else { return }
            switch convergence.status {
            case .converged:
                self.convergenceHints[name] = nil
            case .notConverged(let reasons):
                self.convergenceHints[name] = Self.hint(for: reasons)
            case .unknown:
                break
            @unknown default:
                break
            }
        }
    }

    private static func hint(for reasons: [NIAlgorithmConvergenceStatus.Reason]) -> String {
        if reasons.contains(.insufficientLighting) {
            return "aim assist calibrating — too dark, find brighter light"
        }
        if reasons.contains(.insufficientHorizontalSweep) {
            return "aim assist calibrating — sweep the phone slowly left ↔ right"
        }
        if reasons.contains(.insufficientVerticalSweep) {
            return "aim assist calibrating — tilt the phone up ↕ down"
        }
        return "aim assist calibrating — move the phone around slowly"
    }

    func sessionSuspensionEnded(_ session: NISession) {
        onMain {
            guard let name = self.peerName(for: session), let pr = self.peers[name] else { return }
            self.run(pr)
        }
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        onMain {
            guard let name = self.peerName(for: session) else { return }
            print("[Ranging] session for \(name) invalidated: \(error)")

            // Terminal errors are unrecoverable until the user changes
            // Settings — recreating would loop forever, spamming token
            // messages across the mesh.
            switch (error as? NIError)?.code {
            case .userDidNotAllow:
                self.stopAll()
                self.delegate?.ranging(
                    self,
                    failedPermanently: "Nearby Interaction permission denied — enable it in Settings to play.",
                    forPeer: nil)
                return
            case .invalidConfiguration, .unsupportedPlatform, .invalidARConfiguration:
                self.removePeer(name)
                self.delegate?.ranging(
                    self,
                    failedPermanently: "UWB setup failed for \(name.displayCallSign) — their device may not support ranging.",
                    forPeer: name)
                return
            default:
                break
            }

            // Transient: recreate with a fresh token, but cap consecutive
            // failures so a persistently dying session can't retry unbounded.
            let streak = (self.invalidationStreaks[name] ?? 0) + 1
            self.invalidationStreaks[name] = streak
            guard streak <= 3 else {
                self.removePeer(name)
                self.delegate?.ranging(
                    self,
                    failedPermanently: "UWB ranging with \(name.displayCallSign) keeps failing — move closer and have them rejoin.",
                    forPeer: name)
                return
            }
            self.peers[name] = nil
            _ = self.makePeer(name)   // fresh session ⇒ fresh token
            if let data = self.prepare(peerName: name) {
                self.delegate?.ranging(self, resendToken: data, to: name)
            }
        }
    }
}
