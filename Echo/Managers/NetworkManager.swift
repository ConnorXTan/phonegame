import Foundation
import MultipeerConnectivity

protocol NetworkManagerDelegate: AnyObject {
    func network(_ manager: NetworkManager, didReceive message: GameMessage, from peer: MCPeerID)
    func network(_ manager: NetworkManager, peerDidConnect peer: MCPeerID)
    func network(_ manager: NetworkManager, peerDidDisconnect peer: MCPeerID)
}

/// Local mesh networking over MultipeerConnectivity — peer-to-peer Wi-Fi and
/// Bluetooth, no backend. Every device both advertises and browses; for each
/// discovered pair, the lexicographically smaller display name sends the
/// invitation, so every pair connects exactly once and the result is a full
/// mesh (shooter can message victim directly). Dropped links and failed
/// handshakes self-heal: the inviter retries from a cached discovery record
/// with randomized backoff, and browsing restarts to refresh discovery.
final class NetworkManager: NSObject, ObservableObject {
    static let serviceType = "lasertag"   // must match NSBonjourServices in Info.plist

    @Published private(set) var connectedPeers: [MCPeerID] = []

    let myPeerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    weak var delegate: NetworkManagerDelegate?

    // Main-queue-confined recovery state. The browser reports each peer once,
    // so a failed handshake or dropped link would strand the pair forever
    // without a cached record to re-invite from.
    private var discoveredPeers: [String: MCPeerID] = [:]
    private var pendingInvites: Set<String> = []
    private var isActive = false

    init(playerName: String) {
        // Random suffix keeps wire identity unique even when two players type
        // the same call sign; views strip it with .displayCallSign.
        let unique = playerName + "#" + String(format: "%04x", UInt16.random(in: .min ... .max))
        myPeerID = MCPeerID(displayName: unique)
        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    func start() {
        isActive = true
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func stop() {
        isActive = false
        delegate = nil   // neutralizes delegate callbacks already queued on main
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        connectedPeers = []
        discoveredPeers = [:]
        pendingInvites = []
    }

    /// Send to specific peers, or broadcast to everyone when `peers` is nil.
    func send(_ message: GameMessage, to peers: [MCPeerID]? = nil) {
        let targets = peers ?? session.connectedPeers
        guard !targets.isEmpty else { return }
        do {
            let data = try JSONEncoder().encode(message)
            try session.send(data, toPeers: targets, with: .reliable)
        } catch {
            print("[Network] send failed: \(error)")
        }
    }

    func peer(named name: String) -> MCPeerID? {
        session.connectedPeers.first { $0.displayName == name }
    }

    // MARK: - Invitation & recovery (main queue only)

    /// Invite iff we are the designated inviter for this pair and no attempt
    /// is in flight. Unique display names make `<` a strict total order.
    private func invite(_ peerID: MCPeerID) {
        guard isActive,
              myPeerID.displayName < peerID.displayName,
              !session.connectedPeers.contains(peerID),
              !pendingInvites.contains(peerID.displayName)
        else { return }
        let name = peerID.displayName
        pendingInvites.insert(name)
        // Clear the in-flight flag even if the invitation dies without any
        // session-state callback (invitee vanished mid-handshake).
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in
            self?.pendingInvites.remove(name)
        }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
    }

    /// After any drop or failed handshake: refresh browsing so discovery
    /// records regenerate (a restarted browser re-reports every advertiser),
    /// and if we're the inviter, retry from the cached record after a
    /// randomized backoff so both sides don't storm.
    private func recoverConnection(to peerID: MCPeerID) {
        guard isActive else { return }
        browser.stopBrowsingForPeers()
        browser.startBrowsingForPeers()
        guard myPeerID.displayName < peerID.displayName else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 1.0...3.0)) { [weak self] in
            guard let self, self.isActive,
                  let cached = self.discoveredPeers[peerID.displayName] else { return }
            self.invite(cached)
        }
    }
}

extension NetworkManager: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                self.pendingInvites.remove(peerID.displayName)
                if !self.connectedPeers.contains(peerID) {
                    self.connectedPeers.append(peerID)
                    self.delegate?.network(self, peerDidConnect: peerID)
                }
            case .notConnected:
                self.pendingInvites.remove(peerID.displayName)
                if self.connectedPeers.contains(peerID) {
                    self.connectedPeers.removeAll { $0 == peerID }
                    self.delegate?.network(self, peerDidDisconnect: peerID)
                }
                self.recoverConnection(to: peerID)
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? JSONDecoder().decode(GameMessage.self, from: data) else {
            print("[Network] undecodable message from \(peerID.displayName)")
            return
        }
        DispatchQueue.main.async {
            self.delegate?.network(self, didReceive: message, from: peerID)
        }
    }

    // Streams and resources are unused; required by the protocol.
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension NetworkManager: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("[Network] failed to advertise: \(error)")
    }
}

extension NetworkManager: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            self.discoveredPeers[peerID.displayName] = peerID
            self.invite(peerID)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.discoveredPeers[peerID.displayName] = nil
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("[Network] failed to browse: \(error)")
    }
}
