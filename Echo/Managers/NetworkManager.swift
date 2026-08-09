import Foundation
import Network

protocol NetworkManagerDelegate: AnyObject {
    func network(_ manager: NetworkManager, didReceive message: GameMessage, from peerName: String)
    func network(_ manager: NetworkManager, didReceiveCameraFrame jpeg: Data, from peerName: String)
    func network(_ manager: NetworkManager, didReceiveKillClip clip: KillClip, from peerName: String)
    func network(_ manager: NetworkManager, peerDidConnect peerName: String)
    func network(_ manager: NetworkManager, peerDidDisconnect peerName: String)
}

/// What this device is on the network. Hosts advertise a joinable lobby in
/// their TXT record; players and spectators advertise bare presence so
/// lobby-mates can find and dial them once the host's roster names them.
enum NetworkRole {
    case host, player, spectator
}

/// A joinable lobby seen by the browser, straight from a host's TXT record.
struct DiscoveredLobby: Identifiable, Equatable {
    let hostName: String     // wire name; render with .displayCallSign
    let playerCount: Int
    let capacity: Int
    let isLive: Bool         // a match is underway
    let isTeams: Bool        // host has team play switched on

    var id: String { hostName }
    var isFull: Bool { playerCount >= capacity }
}

/// Lobby-scoped mesh over Network.framework — Bonjour discovery and direct
/// TCP connections over peer-to-peer Wi-Fi (AWDL, the AirDrop link), no
/// backend and no shared network required. Every active device publishes a
/// Bonjour service named after its wire name; hosts carry their lobby state
/// (occupancy, capacity, live) in the TXT record, which browsers surface as a
/// pickable lobby list. Nothing is dialed by discovery alone: joiners dial
/// the ONE host they picked, and members dial each other only when the
/// host's roster names them (the lexicographically smaller name dials), so
/// every pair in a lobby connects exactly once and different lobbies never
/// touch. Bonjour's own record removal can't be trusted here — goodbye
/// packets ride lossy AWDL multicast and a crashed host's record sits in
/// the mDNS cache for up to 75 minutes — so hosts prove liveness by bumping
/// a beat in their TXT record and browsers age out lobbies whose record
/// stops changing. A connection joins the mesh only after a hello frame carries the
/// remote's wire name; dropped links self-heal — the dialer redials from
/// cached browse results on a short cadence, and TCP keepalive surfaces
/// silently dead links. Browsing can run alone (`startDiscovery`) so the
/// menu pre-warms the peer cache before the player commits.
final class NetworkManager: ObservableObject {
    static let serviceType = "_lasertag._tcp"   // must match NSBonjourServices in Info.plist

    /// Hosts touch their TXT record this often; browsers hide a lobby after
    /// three missed beats. This pair is the ghost-lobby defense — without it
    /// a vanished host stays listed until the mDNS cache expires.
    private static let heartbeatInterval: TimeInterval = 10
    private static let lobbyStaleAfter: TimeInterval = 30

    @Published private(set) var connectedPeers: [String] = []
    @Published private(set) var lobbies: [DiscoveredLobby] = []

    /// The call sign this manager was built for, without the wire suffix —
    /// lets a pre-warmed manager be reused only while the name still matches.
    let playerName: String
    /// Wire identity: the Bonjour service instance name and the key every
    /// roster/ranging structure uses.
    let myName: String
    private(set) var role: NetworkRole = .player
    weak var delegate: NetworkManagerDelegate?

    // Main-queue-confined: listener, browser, and every connection run their
    // callbacks on .main.
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var isActive = false
    private var isBrowsing = false
    private var retryTimer: Timer?
    private var heartbeatTimer: Timer?                   // hosts: bumps the TXT beat
    private var heartbeat = 0                            // monotonic; "b" in our TXT
    private var advertisingSuspended = false             // backgrounded: record unpublished
    private var lobbySweepTimer: Timer?                  // ages quiet lobbies out of the list
    private var lobbySightings: [String: LobbySighting] = [:]   // hostName → last TXT + when it changed
    private var discovered: [String: NWEndpoint] = [:]   // wire name → Bonjour endpoint
    private var links: [String: PeerLink] = [:]          // established mesh members
    private var pending: [PeerLink] = []                 // dialed or accepted, hello not yet seen
    private var rosterNames: Set<String> = []            // lobby-mates we should be meshed with
    private var chosenHost: String?                      // the lobby we joined (non-hosts)
    private var lobbyTXT: [String: String] = ["r": "p"]  // what our service advertises

    /// Liveness bookkeeping for one advertised lobby: when its TXT record
    /// last changed, and what it said. An unchanged record keeps its old
    /// timestamp, so a frozen advertisement ages out of the lobby list.
    private struct LobbySighting {
        var lobby: DiscoveredLobby
        var txt: [String: String]
        var lastChange: Date
    }

    /// One TCP connection per peer. `name` is the dial target for outbound
    /// links and is confirmed (outbound) or learned (inbound) by the hello.
    private final class PeerLink {
        let connection: NWConnection
        var name: String?
        var isEstablished = false
        var cameraFrameInFlight = false
        var frameAckTimeout: DispatchWorkItem?
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

    /// Browse-only pre-warm: cache nearby peers (and show the lobby list)
    /// while the player is still on the menu, so the multi-second discovery
    /// warmup is already paid when they commit. Invisible to other devices —
    /// no service published, nothing dialed.
    func startDiscovery() {
        guard !isBrowsing else { return }
        isBrowsing = true
        startBrowser()
        // Staleness needs its own clock — no browse event fires when a
        // record merely goes quiet.
        lobbySweepTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            guard let self, self.isBrowsing else {
                timer.invalidate()
                return
            }
            self.publishLobbies()
        }
    }

    /// Go live in a role: publish our service (hosts advertise their lobby in
    /// the TXT record) and start the redial cadence. Nothing is dialed until
    /// a lobby is joined or a roster names mates.
    func start(as role: NetworkRole) {
        startDiscovery()
        guard !isActive else { return }
        self.role = role
        switch role {
        case .host: lobbyTXT = ["r": "h", "c": "1", "x": "6", "s": "open", "b": String(heartbeat)]
        case .player: lobbyTXT = ["r": "p"]
        case .spectator: lobbyTXT = ["r": "s"]
        }
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
        if role == .host {
            // The TXT beat is the browsers' liveness signal (see
            // updateDiscovered): a lobby whose record stops changing ages
            // out of their lists.
            heartbeatTimer = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval, repeats: true) { [weak self] timer in
                guard let self, self.isActive else {
                    timer.invalidate()
                    return
                }
                self.bumpHeartbeat()
            }
        }
    }

    func stop() {
        isActive = false
        isBrowsing = false
        advertisingSuspended = false
        retryTimer?.invalidate()
        retryTimer = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        lobbySweepTimer?.invalidate()
        lobbySweepTimer = nil
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
        lobbySightings = [:]
        connectedPeers = []
        lobbies = []
        rosterNames = []
        chosenHost = nil
    }

    // MARK: - Lobby membership

    /// Join a discovered lobby: dial its host. Everything else (roster, mesh,
    /// capacity denial) follows over messages.
    func join(_ lobby: DiscoveredLobby) {
        guard isActive else { return }
        chosenHost = lobby.hostName
        rosterNames.insert(lobby.hostName)
        dialEligiblePeers()
    }

    /// A join attempt timed out: stop dialing that host and age its lobby
    /// out immediately instead of leaving a dead row tappable. A host that's
    /// actually alive revives the row with its next TXT beat.
    func abandonJoin(_ hostName: String) {
        if chosenHost == hostName { chosenHost = nil }
        rosterNames.remove(hostName)
        for link in pending where link.name == hostName { link.connection.cancel() }
        lobbySightings[hostName]?.lastChange = .distantPast
        publishLobbies()
    }

    /// Host-authoritative membership update: these are the wire names we
    /// should be meshed with.
    func updateRoster(_ names: [String]) {
        rosterNames = Set(names).subtracting([myName])
        if let chosenHost { rosterNames.insert(chosenHost) }
        dialEligiblePeers()
    }

    /// Host only: refresh the advertised occupancy/capacity/live state.
    /// Resetting the listener's service republishes the Bonjour record with
    /// the new TXT — no restart needed.
    func updateLobbyAdvertisement(playerCount: Int, capacity: Int, isLive: Bool, isTeams: Bool) {
        guard role == .host else { return }
        lobbyTXT = [
            "r": "h",
            "c": String(playerCount),
            "x": String(capacity),
            "s": isLive ? "live" : "open",
            "m": isTeams ? "t" : "s",
            "b": String(heartbeat),
        ]
        republishService()
    }

    /// Touch the TXT record so browsers see us alive (any TXT change counts;
    /// the monotonic beat guarantees one even when nothing else moved).
    private func bumpHeartbeat() {
        heartbeat += 1
        lobbyTXT["b"] = String(heartbeat)
        republishService()
    }

    /// The one place our Bonjour record gets (re)published.
    private func republishService() {
        guard !advertisingSuspended else { return }
        listener?.service = NWListener.Service(
            name: myName, type: Self.serviceType, domain: nil, txtRecord: Self.txtData(lobbyTXT))
    }

    /// Backgrounded: unpublish our record (Bonjour sends a goodbye) while
    /// the process can't accept connections — mDNSResponder otherwise keeps
    /// a suspended app's record advertised indefinitely, which is the ghost
    /// lobby other phones see but can't join. The listener socket stays up;
    /// dead links redial on their own once we return.
    func suspendAdvertising() {
        guard isActive, !advertisingSuspended else { return }
        advertisingSuspended = true
        listener?.service = nil
    }

    /// Foregrounded again: republish, with a fresh beat so browsers that
    /// aged our lobby out while we were gone revive it immediately.
    func resumeAdvertising() {
        guard isActive, advertisingSuspended else { return }
        advertisingSuspended = false
        if role == .host { bumpHeartbeat() } else { republishService() }
    }

    /// Bonjour TXT wire format: per entry, one length byte then "key=value".
    private static func txtData(_ entries: [String: String]) -> Data {
        var data = Data()
        for (key, value) in entries {
            let entry = Data("\(key)=\(value)".utf8).prefix(255)
            data.append(UInt8(entry.count))
            data.append(entry)
        }
        return data
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
            republishService()
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
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: parameters)
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
        var currentHosts: Set<String> = []
        let now = Date()
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint,
                  name != myName   // our own advertisement
            else { continue }
            discovered[name] = result.endpoint
            guard case .bonjour(let txt) = result.metadata, txt["r"] == "h" else { continue }
            currentHosts.insert(name)
            // A changed TXT is the host's proof of life (it beats every
            // heartbeatInterval); an unchanged one keeps its old timestamp
            // so a frozen record — dead host, cached forever by mDNS —
            // ages out below.
            if lobbySightings[name]?.txt != txt.dictionary {
                lobbySightings[name] = LobbySighting(
                    lobby: DiscoveredLobby(
                        hostName: name,
                        playerCount: Int(txt["c"] ?? "") ?? 0,
                        capacity: Int(txt["x"] ?? "") ?? 6,
                        isLive: txt["s"] == "live",
                        isTeams: txt["m"] == "t"),
                    txt: txt.dictionary,
                    lastChange: now)
            }
        }
        // Bonjour removal, when it does arrive, still counts immediately.
        lobbySightings = lobbySightings.filter { currentHosts.contains($0.key) }
        publishLobbies()
        if isActive { dialEligiblePeers() }
    }

    /// The lobby list the UI sees: every sighted lobby whose host has proven
    /// life within the staleness window.
    private func publishLobbies() {
        let cutoff = Date().addingTimeInterval(-Self.lobbyStaleAfter)
        let fresh = lobbySightings.values
            .filter { $0.lastChange > cutoff }
            .map(\.lobby)
            .sorted { $0.hostName < $1.hostName }
        if lobbies != fresh { lobbies = fresh }   // sweep ticks mostly change nothing
    }

    // MARK: - Dialing (main queue only)

    /// Whether we're the one who should dial this peer. Joiners always dial
    /// their chosen host; roster-mates use the smaller-name rule so each pair
    /// dials exactly once. Peers outside our lobby are never dialed — and
    /// hosts never dial at all (members dial in, and redial on drops).
    private func shouldDial(_ name: String) -> Bool {
        if role == .host { return false }
        if name == chosenHost { return true }
        return rosterNames.contains(name) && myName < name
    }

    private func dialEligiblePeers() {
        for (name, endpoint) in discovered {
            guard shouldDial(name),
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
    private static let kindFrameAck: UInt8 = 0x03   // spectator → streamer: last camera frame arrived
    private static let kindKillClip: UInt8 = 0x04   // post-match: a kill replay for the spectator
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

    /// Viewfinder frame for a spectator. At most one frame in flight per peer
    /// END-TO-END: the flag clears on the receiver's ack, not on
    /// `.contentProcessed` — that fires when the frame is merely copied into
    /// the TCP send buffer, so a slow radio silently queued seconds of stale
    /// frames there. Ack pacing caps latency at ~one round trip and lets the
    /// frame rate degrade to what the link can actually carry. A timeout
    /// clears the flag if the ack is lost so the stream can't wedge.
    func sendCameraFrame(_ jpeg: Data, to peerName: String) {
        guard let link = links[peerName], !link.cameraFrameInFlight else { return }
        link.cameraFrameInFlight = true
        link.frameAckTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak link] in link?.cameraFrameInFlight = false }
        link.frameAckTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: timeout)
        var body = Data([Self.kindCameraFrame])
        body.append(jpeg)
        link.connection.send(content: Self.frame(body), completion: .contentProcessed { _ in })
    }

    func isConnected(_ peerName: String) -> Bool {
        links[peerName] != nil
    }

    // MARK: - Kill clips (post-match transfer)

    private struct KillClipHeader: Codable {
        let id: UUID
        let killer: String
        let victim: String
        let ts: TimeInterval
        let count: Int
        // HUD overlay per frame + the sounds and hit markers inside the
        // window; a few KB of JSON riding ahead of ~1 MB of JPEG.
        let overlays: [SpectatorOverlayState]
        let sounds: [ClipSoundEvent]
        let markers: [ClipMarkerEvent]
    }

    /// One kill replay for a spectator. Sent only after the match ends, so a
    /// ~1 MB burst can't contend with live game traffic. Body layout:
    /// [2-byte BE header length][header JSON][count × (4-byte BE length + JPEG)].
    ///
    /// A busy scene makes heavy JPEGs, and 56 heavy frames can pack past the
    /// frame cap. Losing the clip is worse than shortening it: trim from the
    /// front (the hunt), never the back (the kill), until it fits.
    func sendKillClip(_ clip: KillClip, to peerName: String) {
        guard let link = links[peerName] else {
            print("[Network] kill clip dropped: no link to \(peerName)")
            return
        }
        var trimmed = clip
        var body = Self.packKillClip(trimmed)
        while let packed = body, packed.count >= Self.maxFrameBytes, trimmed.frames.count > 8 {
            trimmed = Self.droppingLeadingSecond(of: trimmed)
            body = Self.packKillClip(trimmed)
        }
        guard let packed = body, packed.count < Self.maxFrameBytes else { return }
        if trimmed.frames.count != clip.frames.count {
            print("[Network] kill clip trimmed to \(trimmed.frames.count)/\(clip.frames.count) frames to fit the frame cap")
        }
        link.connection.send(content: Self.frame(packed), completion: .contentProcessed { error in
            if let error { print("[Network] kill clip send failed: \(error)") }
        })
    }

    private static func packKillClip(_ clip: KillClip) -> Data? {
        guard let header = try? JSONEncoder().encode(KillClipHeader(
            id: clip.id, killer: clip.killer, victim: clip.victim,
            ts: clip.capturedAt.timeIntervalSince1970, count: clip.frames.count,
            overlays: clip.overlays, sounds: clip.sounds, markers: clip.markers))
        else { return nil }
        var body = Data([kindKillClip])
        var headerLength = UInt16(header.count).bigEndian
        withUnsafeBytes(of: &headerLength) { body.append(contentsOf: $0) }
        body.append(header)
        for jpeg in clip.frames {
            var frameLength = UInt32(jpeg.count).bigEndian
            withUnsafeBytes(of: &frameLength) { body.append(contentsOf: $0) }
            body.append(jpeg)
        }
        return body
    }

    /// A copy of the clip with its first second gone: 8 frames and their
    /// overlays dropped, sound/marker offsets slid back, and events that now
    /// land before the new start discarded.
    private static func droppingLeadingSecond(of clip: KillClip) -> KillClip {
        let n = 8
        let dt = Double(n) * AimCameraManager.clipFrameInterval
        return KillClip(
            id: clip.id, killer: clip.killer, victim: clip.victim,
            capturedAt: clip.capturedAt,
            frames: Array(clip.frames.dropFirst(n)),
            overlays: Array(clip.overlays.dropFirst(n)),
            sounds: clip.sounds.compactMap {
                let offset = $0.offset - dt
                return offset >= 0 ? ClipSoundEvent(name: $0.name, volume: $0.volume,
                                                    rate: $0.rate, offset: offset) : nil
            },
            markers: clip.markers.compactMap {
                let offset = $0.offset - dt
                return offset >= 0 ? ClipMarkerEvent(offset: offset, isKill: $0.isKill) : nil
            })
    }

    private func parseKillClip(_ payload: Data) -> KillClip? {
        var data = payload[payload.startIndex...]
        guard data.count >= 2 else { return nil }
        let headerLength = Int(data[data.startIndex]) << 8 | Int(data[data.index(after: data.startIndex)])
        data = data.dropFirst(2)
        guard data.count >= headerLength,
              let header = try? JSONDecoder().decode(KillClipHeader.self, from: data.prefix(headerLength))
        else { return nil }
        data = data.dropFirst(headerLength)
        var frames: [Data] = []
        for _ in 0..<header.count {
            guard data.count >= 4 else { return nil }
            let bytes = [UInt8](data.prefix(4))
            let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
            data = data.dropFirst(4)
            guard length > 0, data.count >= length else { return nil }
            frames.append(Data(data.prefix(length)))
            data = data.dropFirst(length)
        }
        return KillClip(id: header.id, killer: header.killer, victim: header.victim,
                        capturedAt: Date(timeIntervalSince1970: header.ts), frames: frames,
                        overlays: header.overlays, sounds: header.sounds, markers: header.markers)
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
            // Ack immediately — the streamer's next frame waits on this.
            link.connection.send(content: Self.frame(Data([Self.kindFrameAck])),
                                 completion: .contentProcessed { _ in })
            delegate?.network(self, didReceiveCameraFrame: payload, from: name)
        case Self.kindFrameAck:
            link.frameAckTimeout?.cancel()
            link.frameAckTimeout = nil
            link.cameraFrameInFlight = false
        case Self.kindKillClip:
            guard link.isEstablished, let name = link.name,
                  let clip = parseKillClip(Data(payload)) else { return }
            delegate?.network(self, didReceiveKillClip: clip, from: name)
        default:
            print("[Network] unknown packet kind \(kind)")
        }
    }
}
