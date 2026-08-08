import AVFoundation
import Foundation
import MultipeerConnectivity
import NearbyInteraction
import UIKit

enum GamePhase: Equatable {
    case menu, lobby, playing
}

/// Source of truth for game state. Hit resolution runs on the SHOOTER's phone
/// (it has the ranging data); the victim applies damage on receipt and
/// broadcasts its own health/death — at hackathon scale, trust the network.
final class GameEngine: NSObject, ObservableObject {

    @Published var playerName: String = ""
    @Published var settings: GameSettings = .indoor
    @Published private(set) var phase: GamePhase = .menu
    @Published private(set) var isHost = false

    @Published private(set) var players: [String: Player] = [:]   // includes self, keyed by name
    @Published private(set) var killFeed: [KillEvent] = []
    @Published private(set) var aimedTarget: String?
    @Published private(set) var lastFireTime: Date?
    @Published private(set) var respawnRemaining: TimeInterval = 0
    @Published private(set) var lastKilledBy: String?
    @Published private(set) var damageFlash = false
    @Published private(set) var uwbWarning: String?
    @Published private(set) var rangingAlert: String?
    @Published private(set) var aimHint: String?

    private(set) var network: NetworkManager?
    let ranging = RangingManager()
    let haptics = HapticsManager()
    let camera = AimCameraManager()
    private let dummy = TargetDummy()

    private var aimTimer: Timer?
    private var respawnTimer: Timer?
    private var pendingSnapshots: [String: (state: PlayerState, at: Date)] = [:]

    var myName: String { network?.myPeerID.displayName ?? playerName }
    var me: Player? { players[myName] }
    var isAlive: Bool { me?.isAlive ?? true }

    var opponents: [Player] {
        players.values.filter { $0.name != myName }.sorted { $0.name < $1.name }
    }

    override init() {
        super.init()
        ranging.delegate = self
        ranging.camera = camera   // one ARSession: viewfinder + camera assistance
        if !RangingManager.isSupported {
            uwbWarning = "This device has no UWB chip (needs iPhone 11+, non-SE). Ranging won't work here."
        } else if !RangingManager.supportsAiming {
            uwbWarning = "This device can't measure UWB direction, so aiming won't work."
        }
    }

    // MARK: - Lobby

    func enterLobby(hosting: Bool) {
        var name = playerName.trimmingCharacters(in: .whitespacesAndNewlines)
        // MCPeerID rejects display names over 63 UTF-8 bytes; leave room for
        // the "#xxxx" uniqueness suffix. removeLast() drops whole graphemes,
        // so emoji are never split.
        while name.utf8.count > 58 { name.removeLast() }
        guard !name.isEmpty else { return }
        isHost = hosting
        let net = NetworkManager(playerName: name)
        net.delegate = self
        network = net
        let wireName = net.myPeerID.displayName
        players = [wireName: Player(name: wireName, hp: settings.maxHP)]
        net.start()
        // Ask now, not at match start — an open permission alert would race
        // the first NISession.run() and the viewfinder's first frame.
        camera.requestAccessIfNeeded()
        phase = .lobby
        UIApplication.shared.isIdleTimerDisabled = true   // auto-lock would drop the mesh
    }

    func leave() {
        network?.stop()
        network = nil
        despawnDummy()
        ranging.stopAll()
        camera.stop()   // after the NI sessions that were using it
        stopTimers()
        players = [:]
        killFeed = []
        aimedTarget = nil
        lastFireTime = nil
        lastKilledBy = nil
        damageFlash = false
        rangingAlert = nil
        pendingSnapshots = [:]
        isHost = false
        phase = .menu
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Host taps Start: broadcast settings, then start locally.
    func startGame() {
        guard phase == .lobby, let net = network else { return }
        net.send(.startGame(settings: settings))
        beginMatch(with: settings)
    }

    private func beginMatch(with settings: GameSettings) {
        self.settings = settings
        for name in players.keys {
            players[name]?.hp = settings.maxHP
            players[name]?.isAlive = true
            players[name]?.kills = 0
            players[name]?.deaths = 0
        }
        killFeed = []
        lastKilledBy = nil
        lastFireTime = nil
        rangingAlert = nil
        // U2 iPhones (15/16) aim exclusively through the camera; if its
        // permission was denied, direction data can never arrive.
        if !NISession.deviceCapabilities.supportsDirectionMeasurement,
           NISession.deviceCapabilities.supportsCameraAssistance,
           AVCaptureDevice.authorizationStatus(for: .video) == .denied {
            rangingAlert = "Camera access is off — this iPhone aims through the camera. Enable it: Settings → Apps → Echo → Camera."
        }
        // Late join: snapshots can arrive before .startGame (different senders,
        // independent ordering). Apply any fresh ones on top of the reset.
        for entry in pendingSnapshots.values where Date().timeIntervalSince(entry.at) < 5 {
            apply(entry.state)
        }
        pendingSnapshots = [:]
        phase = .playing
        UIApplication.shared.isIdleTimerDisabled = true   // UWB needs the app foregrounded
        // Before any NISession.run() below, so ranging attaches to a session
        // that's already delivering frames. Also covers solo practice, where
        // there are no peers and so no NI session to start it.
        camera.start()
        startAimTimer()
        haptics.playGameStart()

        // Pairwise UWB token exchange with every connected peer. Both sides
        // send; ordering races are handled inside RangingManager.
        if let net = network, !net.connectedPeers.isEmpty {
            for peer in net.connectedPeers {
                if let data = ranging.prepare(peerName: peer.displayName) {
                    net.send(.discoveryToken(data), to: [peer])
                }
            }
        } else {
            spawnDummy()   // solo test: nobody to shoot, so conjure a target
        }
    }

    // MARK: - Combat

    func fire() {
        guard phase == .playing, isAlive, let net = network else { return }
        let now = Date()
        if let last = lastFireTime, now.timeIntervalSince(last) < settings.fireCooldown { return }
        lastFireTime = now
        haptics.playFire()
        net.send(.shotFired(by: myName))
        guard let victim = resolveShot() else { return }
        if victim == TargetDummy.name {
            hitDummy()
        } else if let victimPeer = net.peer(named: victim) {
            net.send(.hit(target: victim, by: myName, damage: settings.damage), to: [victimPeer])
            haptics.playHitMarker()
        }
    }

    /// The core algorithm: most-centered live target inside the aim cone and
    /// weapon range, using a 0.3 s reading buffer so a single nil-direction
    /// frame doesn't eat the shot.
    func resolveShot() -> String? {
        var best: (name: String, angle: Float)?
        for player in opponents where player.isAlive {
            guard let reading = ranging.latestDirectional(for: player.name, within: 0.3),
                  let angle = reading.angleOffBoresight else { continue }
            let distance = reading.distance
                ?? ranging.latestReading(for: player.name)?.distance
                ?? .infinity
            guard angle < settings.aimConeRadians, distance < settings.weaponRange else { continue }
            if best == nil || angle < best!.angle {
                best = (player.name, angle)
            }
        }
        return best?.name
    }

    private func applyHit(from shooter: String, damage: Int) {
        guard phase == .playing, isAlive, let net = network else { return }
        let newHP = max(0, (me?.hp ?? 0) - damage)
        players[myName]?.hp = newHP
        haptics.playDamage()
        flashDamage()
        net.send(.healthUpdate(player: myName, hp: newHP))
        if newHP <= 0 {
            die(killedBy: shooter)
        }
    }

    private func die(killedBy killer: String) {
        players[myName]?.isAlive = false
        players[myName]?.deaths += 1
        players[killer]?.kills += 1
        lastKilledBy = killer
        killFeed.insert(KillEvent(killer: killer, victim: myName), at: 0)
        trimFeed()
        network?.send(.death(player: myName, killedBy: killer))
        haptics.playDeath()
        startRespawnCountdown()
    }

    private func startRespawnCountdown() {
        respawnRemaining = settings.respawnDelay
        respawnTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.respawnRemaining -= 0.1
            if self.respawnRemaining <= 0 {
                timer.invalidate()
                self.respawn()
            }
        }
        RunLoop.main.add(timer, forMode: .common)   // keeps ticking during scroll tracking
        respawnTimer = timer
    }

    private func respawn() {
        respawnRemaining = 0
        players[myName]?.hp = settings.maxHP
        players[myName]?.isAlive = true
        network?.send(.respawn(player: myName))
        haptics.playRespawn()
    }

    // MARK: - Aim indicator

    private func startAimTimer() {
        aimTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateAimedTarget()
        }
        RunLoop.main.add(timer, forMode: .common)   // keeps ticking during scroll tracking
        aimTimer = timer
    }

    private func updateAimedTarget() {
        guard phase == .playing, isAlive else {
            if aimedTarget != nil { aimedTarget = nil }
            return
        }
        let target = resolveShot()
        if target != aimedTarget {
            aimedTarget = target
            if target != nil { haptics.playLockTick() }
        }
        let hint = ranging.anyConvergenceHint
        if hint != aimHint { aimHint = hint }
    }

    // MARK: - Target dummy (solo practice)

    private func spawnDummy() {
        players[TargetDummy.name] = Player(name: TargetDummy.name, hp: settings.maxHP)
        dummy.onReading = { [weak self] reading in
            self?.ranging.injectSyntheticReading(reading, for: TargetDummy.name)
        }
        dummy.spawn()
    }

    private func despawnDummy() {
        guard players[TargetDummy.name] != nil else { return }
        dummy.stop()
        ranging.removeSynthetic(TargetDummy.name)
        players[TargetDummy.name] = nil
    }

    /// Victim-side logic, played locally: the dummy takes damage, dies, and
    /// respawns at a new bearing so you have to hunt for it.
    private func hitDummy() {
        guard var target = players[TargetDummy.name], target.isAlive else { return }
        target.hp = max(0, target.hp - settings.damage)
        haptics.playHitMarker()
        if target.hp <= 0 {
            target.isAlive = false
            target.deaths += 1
            players[myName]?.kills += 1
            killFeed.insert(KillEvent(killer: myName, victim: TargetDummy.name), at: 0)
            trimFeed()
            haptics.playKillConfirm()
            dummy.relocate()
            DispatchQueue.main.asyncAfter(deadline: .now() + settings.respawnDelay) { [weak self] in
                guard let self, self.phase == .playing,
                      var revived = self.players[TargetDummy.name] else { return }
                revived.hp = self.settings.maxHP
                revived.isAlive = true
                self.players[TargetDummy.name] = revived
            }
        }
        players[TargetDummy.name] = target
    }

    // MARK: - Helpers

    /// Merge a snapshot row from the wire — each phone is authoritative for
    /// its own row, so never overwrite ours.
    private func apply(_ state: PlayerState) {
        guard state.name != myName else { return }
        var player = players[state.name] ?? Player(name: state.name, hp: state.hp)
        player.hp = state.hp
        player.isAlive = state.isAlive
        player.kills = state.kills
        player.deaths = state.deaths
        players[state.name] = player
    }

    private func flashDamage() {
        damageFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.damageFlash = false
        }
    }

    private func trimFeed() {
        if killFeed.count > 6 { killFeed.removeLast(killFeed.count - 6) }
    }

    private func stopTimers() {
        aimTimer?.invalidate()
        aimTimer = nil
        respawnTimer?.invalidate()
        respawnTimer = nil
        respawnRemaining = 0
    }
}

// MARK: - NetworkManagerDelegate

extension GameEngine: NetworkManagerDelegate {
    func network(_ manager: NetworkManager, peerDidConnect peer: MCPeerID) {
        guard manager === network else { return }   // stale callbacks after leave()
        let name = peer.displayName
        if players[name] == nil {
            players[name] = Player(name: name, hp: settings.maxHP)
        } else {
            players[name]?.isConnected = true       // reconnect: keep their stats
        }
        manager.send(.hello(playerName: myName), to: [peer])
        if phase == .playing {
            despawnDummy()   // a real target arrived — practice is over
            // Late joiner or reconnect mid-match: sync settings + full state
            // (host), our own authoritative row (everyone), and pair up UWB.
            // .reliable unicasts to one peer stay ordered, so the snapshot
            // lands after .startGame on their side.
            if isHost {
                manager.send(.startGame(settings: settings), to: [peer])
                manager.send(.stateSnapshot(players.values.map(PlayerState.init)), to: [peer])
            } else if let mine = me {
                manager.send(.stateSnapshot([PlayerState(mine)]), to: [peer])
            }
            if let data = ranging.prepare(peerName: name) {
                manager.send(.discoveryToken(data), to: [peer])
            }
        }
    }

    func network(_ manager: NetworkManager, peerDidDisconnect peer: MCPeerID) {
        guard manager === network else { return }
        let name = peer.displayName
        if phase == .playing, players[name] != nil {
            // Might be a transient blip — keep stats so reconnect doesn't
            // resurrect them at full HP with zeroed kills.
            players[name]?.isConnected = false
        } else {
            players[name] = nil
        }
        ranging.removePeer(name)
    }

    func network(_ manager: NetworkManager, didReceive message: GameMessage, from peer: MCPeerID) {
        guard manager === network else { return }
        switch message {
        case .hello(let name):
            if players[name] == nil {
                players[name] = Player(name: name, hp: settings.maxHP)
            }

        case .discoveryToken(let data):
            if let reply = ranging.receiveToken(data, from: peer.displayName) {
                manager.send(.discoveryToken(reply), to: [peer])
            }

        case .startGame(let settings):
            if phase == .playing {
                self.settings = settings   // late-join resync; don't reset the match
            } else {
                beginMatch(with: settings)
            }

        case .stateSnapshot(let states):
            if phase == .playing {
                states.forEach(apply)
            } else {
                // Can arrive before .startGame from independent senders; stash
                // and apply after beginMatch resets.
                for state in states where state.name != myName {
                    pendingSnapshots[state.name] = (state, Date())
                }
            }

        case .shotFired(let by):
            if by != myName { haptics.playDistantShot() }

        case .hit(let target, let by, let damage):
            if target == myName { applyHit(from: by, damage: damage) }

        case .healthUpdate(let player, let hp):
            if player != myName { players[player]?.hp = hp }

        case .death(let player, let killedBy):
            guard player != myName else { return }
            players[player]?.isAlive = false
            players[player]?.deaths += 1
            players[killedBy]?.kills += 1
            killFeed.insert(KillEvent(killer: killedBy, victim: player), at: 0)
            trimFeed()
            if killedBy == myName { haptics.playKillConfirm() }

        case .respawn(let player):
            guard player != myName else { return }
            players[player]?.hp = settings.maxHP
            players[player]?.isAlive = true
        }
    }
}

// MARK: - RangingManagerDelegate

extension GameEngine: RangingManagerDelegate {
    func ranging(_ manager: RangingManager, resendToken tokenData: Data, to peerName: String) {
        guard let net = network, let peer = net.peer(named: peerName) else { return }
        net.send(.discoveryToken(tokenData), to: [peer])
    }

    func ranging(_ manager: RangingManager, failedPermanently reason: String, forPeer peerName: String?) {
        rangingAlert = reason
    }
}
