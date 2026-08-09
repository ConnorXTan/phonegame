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
    /// Ranging trouble the player should see: permission denial (peerName ==
    /// nil, all ranging is down), an unusable peer device, or a session that
    /// keeps dying. Sessions that keep dying are still retried with backoff
    /// behind the alert.
    func ranging(_ manager: RangingManager, raiseAlert reason: String, forPeer peerName: String?)
    /// Readings resumed for the peer, so any alert raised for them is stale.
    func ranging(_ manager: RangingManager, clearAlertForPeer peerName: String)
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
        var arSessionAttached = false
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

    /// Most recent NISession invalidation per peer, for the debug sheet —
    /// playtests run without Xcode attached, so the raw NIError code has to be
    /// readable on-device. Deliberately not cleared by removePeer: the
    /// terminal-error branch removes the peer, and this record is the only
    /// remaining evidence of why.
    private(set) var lastInvalidations: [String: (message: String, count: Int, at: Date)] = [:]

    func lastInvalidation(for name: String) -> (message: String, count: Int, at: Date)? {
        lastInvalidations[name]
    }

    /// U2 devices aim via camera assistance, which needs ARKit to converge
    /// before direction data flows. Per-peer human-readable hint while not
    /// converged; nil once ready. Polled by the aim timer and debug view.
    private(set) var convergenceHints: [String: String] = [:]

    /// Convergence is a property of *this* device's ARKit session, not of any
    /// one peer, so a hint is only meaningful while nothing is producing
    /// bearings. Live angle data outranks whatever the last convergence
    /// callback said: the callback only fires on status *change*, so a hint
    /// that is never contradicted would otherwise sit on the HUD forever.
    var anyConvergenceHint: String? {
        guard !isCameraAssistanceLive else { return nil }
        // Sorted so the message is stable rather than dictionary-order roulette.
        return convergenceHints.values.sorted().first
    }

    /// True when a peer has yielded a usable bearing in the last second.
    private var isCameraAssistanceLive: Bool {
        peers.keys.contains { latestDirectional(for: $0, within: 1) != nil }
    }

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
    /// until convergence — callers fall back to the raw readings.
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
        convergenceHints = [:]
        lastInvalidations = [:]
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
        let caps = NISession.deviceCapabilities
        // Camera assistance only where aiming needs it: U2 chips report no
        // native direction measurement. A U1 phone (11–14) loses the widened
        // FoV camera assistance would give it, but skips the heavier
        // camera-assisted path — a deliberate exchange to spend less of the
        // NI resource budget per session.
        if caps.supportsCameraAssistance && !caps.supportsDirectionMeasurement {
            config.isCameraAssistanceEnabled = true   // adds direction/horizontalAngle
            // Hand over the viewfinder's session, already running. Skipping
            // this makes NI create a hidden ARSession of its own, which would
            // then fight the on-screen one for the camera. Attach exactly once
            // per NISession: didRemove and suspension-end re-enter run() on a
            // live session, and re-calling setARSession there is undocumented.
            if !pr.arSessionAttached, let arSession = camera?.start() {
                pr.session.setARSession(arSession)
                pr.arSessionAttached = true
            }
        }
        pr.session.run(config)
    }

    private func peerName(for session: NISession) -> String? {
        peers.first { $0.value.session === session }?.key
    }

    private func readings(for peerName: String) -> [RangingReading] {
        peers[peerName]?.readings ?? []
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
            // First reading of this session, or readings resuming after
            // invalidations — either way the pair is provably alive, so any
            // failure alert on the HUD is stale. (The first-reading check
            // covers a peer that recovered after a terminal-looking error:
            // the streak was wiped with the old peer entry, so a nonzero
            // streak alone can't detect that recovery.)
            if pr.latestObject == nil || (self.invalidationStreaks[name] ?? 0) != 0 {
                self.invalidationStreaks[name] = 0
                self.delegate?.ranging(self, clearAlertForPeer: name)
            }
            if obj.direction != nil || obj.horizontalAngle != nil {
                // A bearing arrived, so camera assistance converged for this
                // peer whether or not the convergence callback said so.
                self.convergenceHints[name] = nil
            }
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
                // No status means no diagnosis to show. Leaving the hint in
                // place here (as a bare `break` does) left it asserting a
                // specific fix — "sweep left-right" — long after tracking
                // had recovered.
                self.convergenceHints[name] = nil
            @unknown default:
                self.convergenceHints[name] = nil
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

    /// e.g. "activeSessionsLimitExceeded (-5885)". Names are mapped by raw
    /// value rather than by switching over NIError.Code cases so a code this
    /// SDK doesn't know still prints its number instead of collapsing into a
    /// generic description.
    private static let niErrorNames: [Int: String] = [
        -5889: "unsupportedPlatform",
        -5888: "invalidConfiguration",
        -5887: "sessionFailed",
        -5886: "resourceUsageTimeout",
        -5885: "activeSessionsLimitExceeded",
        -5884: "userDidNotAllow",
        -5883: "invalidARConfiguration",
        -5882: "accessoryPeerDeviceUnavailable",
        -5881: "incompatiblePeerDevice",
        -5880: "activeExtendedDistanceSessionsLimitExceeded",
    ]

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == NIErrorDomain else { return "\(ns.domain) \(ns.code)" }
        return "\(niErrorNames[ns.code] ?? "unknown") (\(ns.code))"
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        onMain {
            guard let name = self.peerName(for: session) else { return }
            print("[Ranging] session for \(name) invalidated: \(error)")

            let code = Self.describe(error)
            let priorCount = self.lastInvalidations[name]?.count ?? 0
            self.lastInvalidations[name] = (code, priorCount + 1, Date())

            // Terminal errors are unrecoverable until the user changes
            // Settings — recreating would loop forever, spamming token
            // messages across the mesh.
            switch (error as? NIError)?.code {
            case .userDidNotAllow:
                self.stopAll()
                self.delegate?.ranging(
                    self,
                    raiseAlert: "Nearby Interaction permission denied — enable it in Settings to play.",
                    forPeer: nil)
                return
            case .invalidConfiguration, .unsupportedPlatform, .invalidARConfiguration:
                self.removePeer(name)
                self.delegate?.ranging(
                    self,
                    raiseAlert: "UWB setup failed for \(name.displayCallSign) — \(code). Their device may not support ranging.",
                    forPeer: name)
                return
            default:
                break
            }

            // Transient: recreate with a fresh token, backing off as the
            // streak grows. Never give the peer up permanently — nothing else
            // re-creates it, so a removed pair could only come back through a
            // network drop-and-reconnect.
            let streak = (self.invalidationStreaks[name] ?? 0) + 1
            self.invalidationStreaks[name] = streak
            if streak == 3 {
                self.delegate?.ranging(
                    self,
                    raiseAlert: "UWB ranging with \(name.displayCallSign) keeps failing — \(code). Retrying; moving closer may help.",
                    forPeer: name)
            }

            let delay: TimeInterval
            if (error as? NIError)?.code == .activeSessionsLimitExceeded {
                // Retrying immediately is guaranteed to fail again — this
                // session's slot was never granted, so nothing was freed.
                // Wait for another session to end somewhere.
                delay = min(2 * pow(2, Double(streak - 1)), 16)              // 2, 4, 8, 16, 16…
            } else {
                delay = streak == 1 ? 0 : min(0.5 * pow(2, Double(streak - 2)), 8)   // 0, 0.5, 1, 2… 8
            }
            self.peers[name] = nil
            self.retryRanging(name, after: delay)
        }
    }

    /// Recreate the dead session for a peer after `delay` — unless the match
    /// ended (stopAll cleared peerNames) or a token exchange already rebuilt
    /// the peer in the meantime.
    private func retryRanging(_ name: String, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.peerNames.contains(name),
                  self.peers[name] == nil
            else { return }
            _ = self.makePeer(name)   // fresh session ⇒ fresh token
            if let data = self.prepare(peerName: name) {
                self.delegate?.ranging(self, resendToken: data, to: name)
            }
        }
    }
}
