import Foundation
import MultipeerConnectivity

protocol NetworkManagerDelegate: AnyObject {
    func network(_ manager: NetworkManager, didReceive message: GameMessage, from peer: MCPeerID)
    func network(_ manager: NetworkManager, didReceiveCameraFrame jpeg: Data, from peer: MCPeerID)
    func network(_ manager: NetworkManager, peerDidConnect peer: MCPeerID)
    func network(_ manager: NetworkManager, peerDidDisconnect peer: MCPeerID)
}

/// What this device is on the network. Hosts advertise a joinable lobby;
/// players and spectators advertise bare presence so lobby-mates can find and
/// connect to them once the host's roster names them.
enum NetworkRole {
    case host, player, spectator
}

/// A joinable lobby seen by the browser, straight from a host's advertisement.
struct DiscoveredLobby: Identifiable, Equatable {
    let peerID: MCPeerID
    let hostName: String     // wire name; render with .displayCallSign
    let playerCount: Int
    let capacity: Int
    let isLive: Bool         // a match is underway

    var id: String { peerID.displayName }
    var isFull: Bool { playerCount >= capacity }
}

/// Lobby-scoped mesh over MultipeerConnectivity — peer-to-peer Wi-Fi and
/// Bluetooth, no backend. Hosts advertise their lobby (name, occupancy,
/// capacity, live state); joiners browse and invite the ONE host they picked.
/// Membership is host-authoritative: when the roster message names the
/// members, they mesh among themselves (smaller wire name invites), so every
/// pair in a lobby connects exactly once and different lobbies never touch.
/// Dropped links self-heal from cached discovery records with backoff;
/// browser/advertiser restarts are throttled onto fresh instances — rapid
/// stop/start cycles corrupt CFNetServiceBrowser's run-loop source and trap.
final class NetworkManager: NSObject, ObservableObject {
    static let serviceType = "lasertag"   // must match NSBonjourServices in Info.plist

    @Published private(set) var connectedPeers: [MCPeerID] = []
    @Published private(set) var lobbies: [DiscoveredLobby] = []

    let myPeerID: MCPeerID
    let role: NetworkRole
    weak var delegate: NetworkManagerDelegate?

    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser
    private var browser: MCNearbyServiceBrowser

    // Main-queue-confined state.
    private var discoveredPeers: [String: MCPeerID] = [:]
    private var pendingInvites: Set<String> = []
    private var rosterNames: Set<String> = []    // lobby-mates we should be meshed with
    private var chosenHost: String?              // the lobby we joined (non-hosts)
    private var isActive = false

    // Restart throttles (see class comment).
    private var browserRefreshPending = false
    private var lastBrowserRefresh = Date.distantPast
    private var advertiserRefreshPending = false
    private var pendingAdvertisement: [String: String]?
    private var lastAdvertiserRefresh = Date.distantPast

    init(playerName: String, role: NetworkRole) {
        // Random suffix keeps wire identity unique even when two players type
        // the same call sign; views strip it with .displayCallSign.
        let unique = playerName + "#" + String(format: "%04x", UInt16.random(in: .min ... .max))
        self.role = role
        myPeerID = MCPeerID(displayName: unique)
        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        let info: [String: String]
        switch role {
        case .host: info = ["r": "h", "c": "0", "x": "6", "s": "open"]
        case .player: info = ["r": "p"]
        case .spectator: info = ["r": "s"]
        }
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: info, serviceType: Self.serviceType)
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
        lobbies = []
        discoveredPeers = [:]
        pendingInvites = []
        rosterNames = []
        chosenHost = nil
    }

    // MARK: - Lobby membership

    /// Join a discovered lobby: invite its host into our session. Everything
    /// else (roster, mesh, capacity denial) follows over messages.
    func join(_ lobby: DiscoveredLobby) {
        guard isActive else { return }
        chosenHost = lobby.peerID.displayName
        rosterNames.insert(lobby.peerID.displayName)
        let name = lobby.peerID.displayName
        pendingInvites.insert(name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in
            self?.pendingInvites.remove(name)
        }
        browser.invitePeer(lobby.peerID, to: session, withContext: nil, timeout: 30)
    }

    /// Host-authoritative membership update: these are the wire names we
    /// should be meshed with. Prunes strangers, invites newly named mates.
    func updateRoster(_ names: [String]) {
        rosterNames = Set(names).subtracting([myPeerID.displayName])
        if let chosenHost { rosterNames.insert(chosenHost) }
        meshTick()
    }

    /// Host only: refresh the advertised occupancy/capacity/live state.
    /// Throttled — the advertisement must be restarted to change, and rapid
    /// restarts are the same trap as rapid browser restarts.
    func updateLobbyAdvertisement(playerCount: Int, capacity: Int, isLive: Bool) {
        guard role == .host else { return }
        pendingAdvertisement = [
            "r": "h",
            "c": String(playerCount),
            "x": String(capacity),
            "s": isLive ? "live" : "open",
        ]
        scheduleAdvertiserRefresh()
    }

    // MARK: - Sending

    // First byte of every packet tags its kind, so bulky camera frames skip
    // JSON entirely. '{' (0x7B) is accepted bare for builds predating the tag.
    private static let kindJSON: UInt8 = 0x00
    private static let kindCameraFrame: UInt8 = 0x01

    /// Send to specific peers, or broadcast to everyone when `peers` is nil.
    func send(_ message: GameMessage, to peers: [MCPeerID]? = nil) {
        let targets = peers ?? session.connectedPeers
        guard !targets.isEmpty else { return }
        do {
            var data = Data([Self.kindJSON])
            data.append(try JSONEncoder().encode(message))
            try session.send(data, toPeers: targets, with: .reliable)
        } catch {
            print("[Network] send failed: \(error)")
        }
    }

    /// Viewfinder frame for a spectator. Unreliable: a dropped frame is better
    /// than a late one, and it can't head-of-line-block game messages.
    func sendCameraFrame(_ jpeg: Data, to peer: MCPeerID) {
        guard session.connectedPeers.contains(peer) else { return }
        var data = Data([Self.kindCameraFrame])
        data.append(jpeg)
        try? session.send(data, toPeers: [peer], with: .unreliable)
    }

    func peer(named name: String) -> MCPeerID? {
        session.connectedPeers.first { $0.displayName == name }
    }

    // MARK: - Mesh formation & recovery (main queue only)

    /// Connect to every roster-mate we've discovered but aren't linked to.
    /// The lexicographically smaller wire name invites, so each pair connects
    /// exactly once; unique names make `<` a strict total order.
    private func meshTick() {
        guard isActive else { return }
        for name in rosterNames where name != chosenHost {
            guard myPeerID.displayName < name,
                  let record = discoveredPeers[name],
                  !session.connectedPeers.contains(record),
                  !pendingInvites.contains(name)
            else { continue }
            pendingInvites.insert(name)
            DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in
                self?.pendingInvites.remove(name)
            }
            browser.invitePeer(record, to: session, withContext: nil, timeout: 30)
        }
    }

    /// After a drop or failed handshake with someone we should be linked to:
    /// refresh browsing so discovery records regenerate, and retry from the
    /// cached record after a randomized backoff so both sides don't storm.
    private func recoverConnection(to peerID: MCPeerID) {
        let name = peerID.displayName
        guard isActive, rosterNames.contains(name) || name == chosenHost else { return }
        scheduleBrowserRefresh()
        let isMyInvite = name == chosenHost || myPeerID.displayName < name
        guard isMyInvite else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 1.0...3.0)) { [weak self] in
            guard let self, self.isActive,
                  let cached = self.discoveredPeers[name],
                  !self.session.connectedPeers.contains(cached),
                  !self.pendingInvites.contains(name)
            else { return }
            self.pendingInvites.insert(name)
            DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in
                self?.pendingInvites.remove(name)
            }
            self.browser.invitePeer(cached, to: self.session, withContext: nil, timeout: 30)
        }
    }

    /// At most one browser restart per ~5 s, coalescing bursts, and always
    /// onto a FRESH browser instance — restarting the same one after churn
    /// corrupts its run-loop source and crashes (EXC_BREAKPOINT, _BrowserCancel).
    private func scheduleBrowserRefresh() {
        guard isActive, !browserRefreshPending else { return }
        browserRefreshPending = true
        let wait = max(0.5, 5.0 - Date().timeIntervalSince(lastBrowserRefresh))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.browserRefreshPending = false
            guard self.isActive else { return }
            self.lastBrowserRefresh = Date()
            self.browser.stopBrowsingForPeers()
            self.browser.delegate = nil
            self.browser = MCNearbyServiceBrowser(peer: self.myPeerID, serviceType: Self.serviceType)
            self.browser.delegate = self
            self.browser.startBrowsingForPeers()
        }
    }

    /// Same throttle-and-recreate discipline for the advertiser; the latest
    /// pending advertisement wins when the window opens.
    private func scheduleAdvertiserRefresh() {
        guard isActive, !advertiserRefreshPending else { return }
        advertiserRefreshPending = true
        let wait = max(0.5, 2.0 - Date().timeIntervalSince(lastAdvertiserRefresh))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.advertiserRefreshPending = false
            guard self.isActive, let info = self.pendingAdvertisement else { return }
            self.pendingAdvertisement = nil
            self.lastAdvertiserRefresh = Date()
            self.advertiser.stopAdvertisingPeer()
            self.advertiser.delegate = nil
            self.advertiser = MCNearbyServiceAdvertiser(peer: self.myPeerID, discoveryInfo: info, serviceType: Self.serviceType)
            self.advertiser.delegate = self
            self.advertiser.startAdvertisingPeer()
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
        guard let first = data.first else { return }
        switch first {
        case Self.kindCameraFrame:
            let jpeg = data.dropFirst()
            DispatchQueue.main.async {
                self.delegate?.network(self, didReceiveCameraFrame: jpeg, from: peerID)
            }
        case Self.kindJSON, UInt8(ascii: "{"):
            let payload = first == Self.kindJSON ? data.dropFirst() : data[...]
            guard let message = try? JSONDecoder().decode(GameMessage.self, from: payload) else {
                print("[Network] undecodable message from \(peerID.displayName)")
                return
            }
            DispatchQueue.main.async {
                self.delegate?.network(self, didReceive: message, from: peerID)
            }
        default:
            print("[Network] unknown packet kind \(first) from \(peerID.displayName)")
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
        // Joiners invite the host they picked; roster-mates invite each other.
        // Capacity and membership are enforced at the message layer (the host
        // answers an over-capacity join with .joinDenied), so accepting here
        // is safe and gives rejected joiners a clean, explicit answer instead
        // of a silent timeout.
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
            if info?["r"] == "h" {
                let lobby = DiscoveredLobby(
                    peerID: peerID,
                    hostName: peerID.displayName,
                    playerCount: Int(info?["c"] ?? "") ?? 0,
                    capacity: Int(info?["x"] ?? "") ?? 6,
                    isLive: info?["s"] == "live")
                self.lobbies.removeAll { $0.id == lobby.id }
                self.lobbies.append(lobby)
                self.lobbies.sort { $0.hostName < $1.hostName }
            }
            self.meshTick()
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.discoveredPeers[peerID.displayName] = nil
            self.lobbies.removeAll { $0.id == peerID.displayName }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("[Network] failed to browse: \(error)")
    }
}
