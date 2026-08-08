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
    var angleOffBoresight: Float? {
        guard let d = direction else { return nil }
        return acos(max(-1, min(1, -d.z)))
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
        init(session: NISession) { self.session = session }
    }

    weak var delegate: RangingManagerDelegate?
    @Published private(set) var peerNames: [String] = []

    private var peers: [String: PeerRanging] = [:]
    private var invalidationStreaks: [String: Int] = [:]

    static var isSupported: Bool {
        NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
    }

    static var supportsDirection: Bool {
        NISession.deviceCapabilities.supportsDirectionMeasurement
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
        peers[peerName]?.readings.last
    }

    /// Freshest reading with a usable direction within `window` seconds.
    func latestDirectional(for peerName: String, within window: TimeInterval) -> RangingReading? {
        let cutoff = Date().addingTimeInterval(-window)
        return peers[peerName]?.readings.last { $0.timestamp >= cutoff && $0.direction != nil }
    }

    /// Readings per second over the last second — for the debug view.
    func sampleRate(for peerName: String) -> Int {
        let cutoff = Date().addingTimeInterval(-1)
        return peers[peerName]?.readings.filter { $0.timestamp >= cutoff }.count ?? 0
    }

    // MARK: - Lifecycle

    func removePeer(_ name: String) {
        peers[name]?.session.invalidate()
        peers[name] = nil
        peerNames.removeAll { $0 == name }
        invalidationStreaks[name] = nil
    }

    func stopAll() {
        peers.values.forEach { $0.session.invalidate() }
        peers = [:]
        peerNames = []
        invalidationStreaks = [:]
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
        }
        pr.session.run(config)
    }

    private func peerName(for session: NISession) -> String? {
        peers.first { $0.value.session === session }?.key
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
            if reason == .timeout {
                self.run(pr)   // retry ranging with the same tokens
            }
        }
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
