import Foundation
import Network

protocol NetworkManagerDelegate: AnyObject {
    func network(_ manager: NetworkManager, didReceive message: GameMessage, from peerName: String)
    func network(_ manager: NetworkManager, didReceiveCameraFrame jpeg: Data, from peerName: String)
    func network(_ manager: NetworkManager, peerDidConnect peerName: String)
    func network(_ manager: NetworkManager, peerDidDisconnect peerName: String)
}

/// Local mesh networking over Network.framework — Bonjour discovery and direct
/// TCP connections over peer-to-peer Wi-Fi (AWDL, the AirDrop link), no
/// backend and no shared network required. Every active device publishes a
/// Bonjour service named after its wire name and browses for everyone else's;
/// for each discovered pair, the lexicographically smaller name dials, so
/// every pair connects exactly once and the result is a full mesh (shooter
/// can message victim directly). A connection joins the mesh only after a
/// hello frame carries the remote's wire name; dropped links self-heal — the
/// dialer redials from cached browse results on a short cadence, and TCP
/// keepalive surfaces silently dead links. Browsing can run alone
/// (`startDiscovery`) so the menu pre-warms the peer cache before the player
/// commits to a lobby, while staying invisible (no service published, nothing
/// dialed).
final class NetworkManager: ObservableObject {
    static let serviceType = "_lasertag._tcp"   // must match NSBonjourServices in Info.plist

    @Published private(set) var connectedPeers: [String] = []

    /// The call sign this manager was built for, without the wire suffix —
    /// lets a pre-warmed manager be reused only while the name still matches.
    let playerName: String
    /// Wire identity: the Bonjour service instance name and the key every
    /// roster/ranging structure uses.
    let myName: String
    weak var delegate: NetworkManagerDelegate?

    // Main-queue-confined: listener, browser, and every connection run their
    // callbacks on .main.
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var isActive = false
    private var isBrowsing = false
    private var retryTimer: Timer?
    private var discovered: [String: NWEndpoint] = [:]   // wire name → Bonjour endpoint
    private var links: [String: PeerLink] = [:]          // established mesh members
    private var pending: [PeerLink] = []                 // dialed or accepted, hello not yet seen

    /// One TCP connection per peer. `name` is the dial target for outbound
    /// links and is confirmed (outbound) or learned (inbound) by the hello.
    private final class PeerLink {
        let connection: NWConnection
        var name: String?
        var isEstablished = false
        var cameraFrameInFlight = false
        let createdAt = Date()
        init(connection: NWConnection, name: String?) {
            self.connection = connection
            self.name = name
        }
    }

    init(playerName: String) {
        self.playerName = playerName
        // Random suffix keeps wire identity unique even when two players type
        // the same call sign; views strip it with .displayCallSign.
        myName = playerName + "#" + String(format: "%04x", UInt16.random(in: .min ... .max))
    }

    // MARK: - Lifecycle

    /// Browse-only pre-warm: cache nearby peers while the player is still on
    /// the menu, so the multi-second discovery warmup is already paid when
    /// they tap Host/Join. Invisible to other devices — no service published,
    /// nothing dialed — so a phone sitting on the menu can never be pulled
    /// into someone's lobby.
    func startDiscovery() {
        guard !isBrowsing else { return }
        isBrowsing = true
        startBrowser()
    }

    /// Go live: publish our service, dial every cached peer immediately, and
    /// keep redialing on a cadence until the mesh forms.
    func start() {
        startDiscovery()
        guard !isActive else { return }
        isActive = true
        startListener()
        dialEligiblePeers()
        // Redial on a cadence instead of only on discovery events: a dial can
        // die against a stale Bonjour record with nothing but a timeout, and
        // dialEligiblePeers() gates on connected/pending/dialer-role, so
        // ticks are no-ops once the mesh is up.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            guard let self, self.isActive else {
                timer.invalidate()
                return
            }
            // A dial that never handshakes holds its slot forever without
            // this: cancel it so the next tick can start a fresh one.
            for link in self.pending where Date().timeIntervalSince(link.createdAt) > 8 {
                link.connection.cancel()
            }
            self.dialEligiblePeers()
        }
    }

    func stop() {
        isActive = false
        isBrowsing = false
        retryTimer?.invalidate()
        retryTimer = nil
        delegate = nil   // neutralizes callbacks already queued on main
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        for link in pending { link.connection.cancel() }
        for link in links.values { link.connection.cancel() }
        pending = []
        links = [:]
        discovered = [:]
        connectedPeers = []
    }

    /// Plain TCP over peer-to-peer Wi-Fi. Keepalive surfaces links that died
    /// without a FIN (phone locked, walked out of range) within ~8 s; noDelay
    /// because game messages are tiny and latency-critical. NOTE: unlike
    /// MultipeerConnectivity's `.required` encryption this is plaintext on
    /// the air — when a join secret exists, TLS-PSK slots in here.
    private static func connectionParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 8
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    private func startListener() {
        do {
            let listener = try NWListener(using: Self.connectionParameters())
            listener.service = NWListener.Service(name: myName, type: Self.serviceType)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.isActive else {
                    connection.cancel()
                    return
                }
                let link = PeerLink(connection: connection, name: nil)
                self.pending.append(link)
                self.configure(link)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    print("[Network] listener failed: \(error)")
                    self?.restartListenerLater()
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            print("[Network] failed to listen: \(error)")
            restartListenerLater()
        }
    }

    private func restartListenerLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.isActive else { return }
            self.listener?.cancel()
            self.startListener()
        }
    }

    private func startBrowser() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.updateDiscovered(with: results)
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                print("[Network] browser failed: \(error)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard let self, self.isBrowsing else { return }
                    self.browser?.cancel()
                    self.startBrowser()
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func updateDiscovered(with results: Set<NWBrowser.Result>) {
        discovered = [:]
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint,
                  name != myName   // our own advertisement
            else { continue }
            discovered[name] = result.endpoint
        }
        if isActive { dialEligiblePeers() }
    }

    // MARK: - Dialing (main queue only)

    /// Dial iff we are the designated dialer for the pair and no link or
    /// attempt exists. Unique wire names make `<` a strict total order.
    private func dialEligiblePeers() {
        for (name, endpoint) in discovered {
            guard myName < name,
                  links[name] == nil,
                  !pending.contains(where: { $0.name == name })
            else { continue }
            let link = PeerLink(connection: NWConnection(to: endpoint, using: Self.connectionParameters()),
                                name: name)
            pending.append(link)
            configure(link)
        }
    }

    private func configure(_ link: PeerLink) {
        link.connection.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link else { return }
            switch state {
            case .ready:
                self.sendHello(on: link)
                self.receiveFrame(on: link)
            case .failed, .cancelled:
                self.remove(link)
            default:
                break
            }
        }
        link.connection.start(queue: .main)
    }

    private func remove(_ link: PeerLink) {
        pending.removeAll { $0 === link }
        // Identity check: a newest-wins replacement cancels the old link for
        // a name AFTER installing the new one — tearing the entry down by
        // name alone would disconnect the healthy replacement.
        guard let name = link.name, links[name] === link else { return }
        links[name] = nil
        connectedPeers.removeAll { $0 == name }
        delegate?.network(self, peerDidDisconnect: name)
    }

    /// Hello received: the link joins the mesh under the remote's wire name.
    private func establish(_ link: PeerLink, as name: String) {
        pending.removeAll { $0 === link }
        guard !link.isEstablished else { return }
        guard name != myName else {   // paranoia: a loop-back would shadow us in our own mesh
            link.connection.cancel()
            return
        }
        link.name = name
        link.isEstablished = true
        let replaced = links[name]
        links[name] = link
        // A second connection for a live name means the peer decided the old
        // link is dead (redial after a drop we haven't noticed yet): adopt
        // the new one silently so the roster never blips.
        replaced?.connection.cancel()
        if replaced == nil {
            connectedPeers.append(name)
            delegate?.network(self, peerDidConnect: name)
        }
    }

    // MARK: - Wire format

    // Every frame is a 4-byte big-endian length, then a 1-byte kind tag and
    // the payload. Length prefix because TCP is a byte stream — unlike
    // MultipeerConnectivity, message boundaries are ours to draw.
    private static let kindJSON: UInt8 = 0x00
    private static let kindCameraFrame: UInt8 = 0x01
    private static let kindHello: UInt8 = 0x02
    private static let maxFrameBytes: UInt32 = 4 << 20   // sanity cap; largest real frame is a camera JPEG

    private static func frame(_ body: Data) -> Data {
        var frame = Data(capacity: 4 + body.count)
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(body)
        return frame
    }

    private func sendHello(on link: PeerLink) {
        var body = Data([Self.kindHello])
        body.append(Data(myName.utf8))
        link.connection.send(content: Self.frame(body), completion: .contentProcessed { _ in })
    }

    /// Send to specific peers, or broadcast to everyone when `peers` is nil.
    /// Unknown or disconnected names are silently skipped.
    func send(_ message: GameMessage, to peers: [String]? = nil) {
        let targets = peers ?? Array(links.keys)
        guard !targets.isEmpty else { return }
        do {
            var body = Data([Self.kindJSON])
            body.append(try JSONEncoder().encode(message))
            let frame = Self.frame(body)
            for name in targets {
                links[name]?.connection.send(content: frame, completion: .contentProcessed { error in
                    if let error { print("[Network] send to \(name) failed: \(error)") }
                })
            }
        } catch {
            print("[Network] send failed: \(error)")
        }
    }

    /// Viewfinder frame for a spectator. At most one frame in flight per
    /// peer — a congested link skips frames instead of queueing a backlog
    /// ahead of game messages, which is the old `.unreliable` send's
    /// "dropped beats late" behavior on a reliable transport.
    func sendCameraFrame(_ jpeg: Data, to peerName: String) {
        guard let link = links[peerName], !link.cameraFrameInFlight else { return }
        link.cameraFrameInFlight = true
        var body = Data([Self.kindCameraFrame])
        body.append(jpeg)
        link.connection.send(content: Self.frame(body), completion: .contentProcessed { [weak link] _ in
            link?.cameraFrameInFlight = false
        })
    }

    func isConnected(_ peerName: String) -> Bool {
        links[peerName] != nil
    }

    // MARK: - Receiving

    private func receiveFrame(on link: PeerLink) {
        link.connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self, weak link] data, _, _, error in
            // A short or failed read is the link dying (error, or a clean FIN
            // that would otherwise leave a ghost peer until keepalive fires) —
            // cancel so the state handler tears it down promptly.
            guard let self, let link, error == nil, let data, data.count == 4 else {
                link?.connection.cancel()
                return
            }
            let bytes = [UInt8](data)
            let length = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            guard length > 0, length <= Self.maxFrameBytes else {
                link.connection.cancel()   // garbage or hostile framing: drop the link
                return
            }
            link.connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self, weak link] data, _, _, error in
                guard let self, let link, error == nil, let data, data.count == Int(length) else {
                    link?.connection.cancel()
                    return
                }
                self.handleFrame(data, on: link)
                self.receiveFrame(on: link)
            }
        }
    }

    private func handleFrame(_ body: Data, on link: PeerLink) {
        guard let kind = body.first else { return }
        let payload = body.dropFirst()
        switch kind {
        case Self.kindHello:
            let name = String(decoding: payload, as: UTF8.self)
            guard !name.isEmpty else {
                link.connection.cancel()
                return
            }
            establish(link, as: name)
        case Self.kindJSON:
            // Hello is the first frame both directions (sent on .ready, TCP
            // preserves order), so game traffic before it is a broken peer.
            guard link.isEstablished, let name = link.name else { return }
            guard let message = try? JSONDecoder().decode(GameMessage.self, from: payload) else {
                print("[Network] undecodable message from \(name)")
                return
            }
            delegate?.network(self, didReceive: message, from: name)
        case Self.kindCameraFrame:
            guard link.isEstablished, let name = link.name else { return }
            delegate?.network(self, didReceiveCameraFrame: payload, from: name)
        default:
            print("[Network] unknown packet kind \(kind)")
        }
    }
}
