import AVFoundation
import Foundation
import MultipeerConnectivity
import NearbyInteraction
import UIKit

enum GamePhase: Equatable {
    case menu, lobby, playing, summary
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
    /// Wall-clock end of our damage immunity. Enforced victim-side because each
    /// phone is authoritative for its own HP — shooters resolve independently
    /// and can't see each other, so this is the only place a crossfire can be
    /// collapsed into one hit.
    @Published private(set) var invulnerableUntil: Date?
    @Published private(set) var damageFlash = false
    @Published private(set) var uwbWarning: String?
    @Published private(set) var rangingAlert: String?
    /// Which peer `rangingAlert` is about (nil = device-wide, e.g. permission
    /// problems), so a recovery for that peer — and only that peer — dismisses it.
    private var rangingAlertPeer: String?
    @Published private(set) var hostEndedNotice: String?   // shown on the menu after a host shutdown
    @Published private(set) var aimHint: String?
    @Published private(set) var matchRemaining: TimeInterval = 0
    @Published private(set) var matchResult: MatchResult?
    @Published private(set) var ammo: Int = 0
    @Published private(set) var reloadRemaining: TimeInterval = 0
    /// Bumped on every confirmed hit we land — the HUD watches it to flash the
    /// hit marker. A counter, not a Bool, so back-to-back hits each register.
    @Published private(set) var hitMarker = HitMarker(count: 0, isKill: false)

    var isReloading: Bool { reloadRemaining > 0 }
    var magazineSize: Int { settings.magazineSize }

    // Spectator mode (the laptop): watches the mesh, never plays.
    // A match already running when the game master arrives locks its setup
    // screen — the laptop must never take over a live game. Solo practice
    // (a one-player "match") doesn't count; it yields on Start instead.
    @Published private(set) var externalMatchPlayers = 0
    private var externalHostName: String?
    var externalMatchInProgress: Bool { isSpectator && isHost && externalMatchPlayers >= 2 }
    @Published private(set) var isSpectator = false
    @Published private(set) var watchingPlayer: String?     // wire name of the streamed player
    @Published private(set) var spectatorFrame: UIImage?
    private var spectators: Set<String> = []                // peers that are spectators, not targets
    private var streamingTo: MCPeerID?                      // player side: who gets our viewfinder

    private(set) var network: NetworkManager?
    let ranging = RangingManager()
    let haptics = HapticsManager()
    let camera = AimCameraManager()
    private let dummy = TargetDummy()

    private var aimTimer: Timer?
    private var respawnTimer: Timer?
    private var matchTimer: Timer?
    private var matchDeadline: Date?
    private var reloadTimer: Timer?
    private var pendingSnapshots: [String: (state: PlayerState, at: Date)] = [:]
    private var dummyInvulnerableUntil: Date?   // the dummy's half of the same rule

    var myName: String { network?.myPeerID.displayName ?? playerName }
    var me: Player? { players[myName] }
    var isAlive: Bool { me?.isAlive ?? true }

    /// Takes the date so the HUD can drive a countdown off a TimelineView tick
    /// — `invulnerableUntil` publishes when the window opens, never when it
    /// lapses, so nothing would repaint on expiry otherwise.
    func isInvulnerable(at date: Date = Date()) -> Bool {
        guard let until = invulnerableUntil else { return false }
        return date < until
    }

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
        // Single entry: the menu stays tappable through the menu→lobby
        // crossfade, so a double-tap ran this twice — orphaning a live
        // NetworkManager that kept advertising and accepting invites. Two
        // meshes in one process discover and fight each other until
        // MultipeerConnectivity falls over.
        guard phase == .menu else { return }
        var name = playerName.trimmingCharacters(in: .whitespacesAndNewlines)
        // MCPeerID rejects display names over 63 UTF-8 bytes; leave room for
        // the "#xxxx" uniqueness suffix. removeLast() drops whole graphemes,
        // so emoji are never split.
        while name.utf8.count > 58 { name.removeLast() }
        guard !name.isEmpty else { return }
        hostEndedNotice = nil
        isHost = hosting
        network?.stop()   // there must never be two live meshes; nil here while the phase guard holds
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
        if isHost, phase != .menu, let net = network {
            // Tell everyone before tearing down, and give the reliable send a
            // beat to flush — disconnect() right after send can drop it.
            net.send(.hostEnded)
            network = nil   // stale-guards drop any further callbacks
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { net.stop() }
        } else {
            network?.stop()
            network = nil
        }
        despawnDummy()
        ranging.stopAll()
        camera.frameTap = nil
        camera.stop()   // after the NI sessions that were using it
        stopTimers()
        players = [:]
        killFeed = []
        aimedTarget = nil
        lastFireTime = nil
        lastKilledBy = nil
        invulnerableUntil = nil
        damageFlash = false
        rangingAlert = nil
        rangingAlertPeer = nil
        pendingSnapshots = [:]
        matchResult = nil
        isHost = false
        isSpectator = false
        watchingPlayer = nil
        spectatorFrame = nil
        spectators = []
        clearExternalMatch()
        streamingTo = nil
        phase = .menu
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Join the mesh as a pure observer — no Player entry, no ranging, no
    /// camera. The laptop's mode: it can still host (Start button, settings,
    /// authoritative match end) because "host" is only a protocol convention.
    func enterSpectator(hosting: Bool) {
        guard phase == .menu else { return }   // same re-entry hazard as enterLobby
        hostEndedNotice = nil
        isSpectator = true
        isHost = hosting
        network?.stop()
        let net = NetworkManager(playerName: "Spectator")
        net.delegate = self
        network = net
        players = [:]
        net.start()
        phase = .lobby
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// Spectator: switch whose viewfinder we're watching (nil = stop).
    func watch(_ name: String?) {
        guard isSpectator, let net = network else { return }
        if let current = watchingPlayer, current != name, let peer = net.peer(named: current) {
            net.send(.cameraRequest(active: false), to: [peer])
        }
        watchingPlayer = name
        spectatorFrame = nil
        if let name, let peer = net.peer(named: name) {
            net.send(.cameraRequest(active: true), to: [peer])
        }
    }

    /// Host taps Start: broadcast settings, then start locally. The game
    /// master can't start while somebody else's real match is running.
    func startGame() {
        guard phase == .lobby, !externalMatchInProgress, let net = network else { return }
        net.send(.startGame(settings: settings))
        beginMatch(with: settings)
    }

    private func clearExternalMatch() {
        externalHostName = nil
        externalMatchPlayers = 0
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
        invulnerableUntil = nil
        rangingAlert = nil
        rangingAlertPeer = nil
        // U2 iPhones (15/16) aim exclusively through the camera; if its
        // permission was denied, direction data can never arrive.
        if !isSpectator,
           !NISession.deviceCapabilities.supportsDirectionMeasurement,
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
        matchResult = nil
        cancelReload()
        ammo = settings.magazineSize
        phase = .playing
        UIApplication.shared.isIdleTimerDisabled = true   // UWB needs the app foregrounded
        startMatchClock(seconds: settings.matchDuration)
        guard !isSpectator else { return }   // observers need only the clock and the mirror

        // Before any NISession.run() below, so ranging attaches to a session
        // that's already delivering frames. Also covers solo practice, where
        // there are no peers and so no NI session to start it.
        camera.start()
        startAimTimer()
        haptics.prepare()
        SoundManager.shared.prepare()
        haptics.playGameStart()

        // Pairwise UWB token exchange with every connected PLAYER (spectators
        // don't range). Both sides send; ordering races are handled inside
        // RangingManager.
        let playerPeers = (network?.connectedPeers ?? []).filter { !spectators.contains($0.displayName) }
        if !playerPeers.isEmpty {
            for peer in playerPeers {
                if let data = ranging.prepare(peerName: peer.displayName) {
                    network?.send(.discoveryToken(data), to: [peer])
                }
            }
        } else {
            spawnDummy()   // solo test: nobody to shoot, so conjure a target
        }
    }

    // MARK: - Combat

    func fire() {
        guard phase == .playing, isAlive, let net = network else { return }
        guard !isReloading else { return }
        // Dry trigger on an empty mag racks the reload instead of firing.
        guard ammo > 0 else { startReload(); return }
        let now = Date()
        if let last = lastFireTime, now.timeIntervalSince(last) < settings.fireCooldown { return }
        lastFireTime = now
        ammo -= 1
        // Resolve BEFORE any feedback. Ranging readings are only good for
        // 0.2 s, and playing audio/haptics first can burn longer than that —
        // the shot would then be scored against stale directions and miss a
        // target the crosshair is plainly locked onto.
        let victim = resolveShot()
        haptics.playFire()
        net.send(.shotFired(by: myName))
        defer { if ammo == 0 { startReload() } }   // auto-reload on the last round
        guard let victim else { return }
        if victim == TargetDummy.name {
            hitDummy()
        } else if let victimPeer = net.peer(named: victim) {
            net.send(.hit(target: victim, by: myName, damage: settings.damage), to: [victimPeer])
            confirmHit()
            // Optimistic: drop their bar now instead of a network round trip
            // later; the victim's authoritative .healthUpdate reconciles it.
            // Never kill optimistically — isAlive, kills, and the feed wait
            // for the real .death, so a hit they didn't accept can't fake one.
            if let hp = players[victim]?.hp {
                players[victim]?.hp = max(0, hp - settings.damage)
            }
        }
    }

    /// Shooter-side hit confirmation — marker, tick, buzz. The kill variant
    /// fires separately when the victim's `.death` comes back over the wire.
    private func confirmHit(kill: Bool = false) {
        hitMarker = HitMarker(count: hitMarker.count + 1, isKill: kill)
        if kill {
            haptics.playKillConfirm()
        } else {
            haptics.playHitMarker()
        }
    }

    /// Manual reload (the button beside FIRE) and the auto-reload on empty.
    func startReload() {
        guard phase == .playing, isAlive, !isReloading, ammo < settings.magazineSize else { return }
        reloadRemaining = settings.reloadDuration
        haptics.playReloadStart()
        reloadTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.reloadRemaining -= 0.05
            if self.reloadRemaining <= 0 {
                timer.invalidate()
                self.finishReload()
            }
        }
        RunLoop.main.add(timer, forMode: .common)   // keeps ticking during scroll tracking
        reloadTimer = timer
    }

    private func finishReload() {
        reloadTimer?.invalidate()
        reloadTimer = nil
        reloadRemaining = 0
        ammo = settings.magazineSize
        haptics.playReloadComplete()
    }

    /// Cancel without loading — death, match end, leaving.
    private func cancelReload() {
        reloadTimer?.invalidate()
        reloadTimer = nil
        reloadRemaining = 0
    }

    /// The core algorithm: most-centered live target inside the aim cone and
    /// weapon range, with a short reading buffer so a single nil-direction
    /// frame doesn't eat the shot. The window is deliberately tight: camera-
    /// assisted NI (U2 chips) can coast on a stale ARKit anchor after the
    /// peer moves, and old readings must not hold a lock.
    func resolveShot() -> String? {
        var best: (name: String, angle: Float)?
        for player in opponents where player.isAlive {
            guard let reading = ranging.latestDirectional(for: player.name, within: 0.2),
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
        // Absorbed: no damage, no flash, no healthUpdate — as far as the rest
        // of the mesh is concerned this shot never landed.
        let now = Date()
        guard !isInvulnerable(at: now) else { return }
        invulnerableUntil = now.addingTimeInterval(settings.hitInvulnerability)
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
        cancelReload()   // respawn hands you a fresh mag anyway
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
        cancelReload()
        ammo = settings.magazineSize
        // Overwrites rather than extends any leftover hit i-frames: whoever
        // killed us shouldn't get a shorter spawn window than anyone else.
        invulnerableUntil = Date().addingTimeInterval(settings.spawnProtection)
        network?.send(.respawn(player: myName))
        haptics.playRespawn()
    }

    // MARK: - Match clock

    /// Everyone counts down locally off a wall-clock deadline (drift-free), but
    /// only the host calls time — its `.endMatch` tallies are what everyone
    /// shows, so two phones can never crown different winners. If the host goes
    /// dark, a grace period lets each phone end on its own tallies rather than
    /// stranding the match.
    private func startMatchClock(seconds: TimeInterval) {
        matchDeadline = Date().addingTimeInterval(seconds)
        matchRemaining = seconds
        matchTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tickMatchClock()
        }
        RunLoop.main.add(timer, forMode: .common)   // keeps ticking during scroll tracking
        matchTimer = timer
    }

    private func tickMatchClock() {
        guard phase == .playing, let deadline = matchDeadline else { return }
        let remaining = deadline.timeIntervalSinceNow
        matchRemaining = max(0, remaining)
        guard remaining <= 0 else { return }
        if isHost {
            let finals = players.values.map(PlayerState.init)
            network?.send(.endMatch(finalStates: finals))
            endMatch(with: Array(players.values))
        } else if remaining <= -5 {
            endMatch(with: Array(players.values))   // host never called it
        }
    }

    private func endMatch(with finalPlayers: [Player]) {
        guard phase == .playing else { return }
        // Snapshot before despawning the dummy — in a solo test it holds the
        // only opponent stats worth showing.
        matchResult = MatchResult(
            players: finalPlayers,
            duration: settings.matchDuration,
            myName: myName)
        matchTimer?.invalidate()
        matchTimer = nil
        matchDeadline = nil
        matchRemaining = 0
        aimTimer?.invalidate()
        aimTimer = nil
        respawnTimer?.invalidate()
        respawnTimer = nil
        respawnRemaining = 0
        cancelReload()
        aimedTarget = nil
        despawnDummy()
        phase = .summary
        haptics.playMatchEnd()
    }

    /// Summary → lobby, mesh intact, so the host can run another match.
    func returnToLobby() {
        guard phase == .summary else { return }
        matchResult = nil
        killFeed = []
        lastKilledBy = nil
        lastFireTime = nil
        invulnerableUntil = nil
        damageFlash = false
        for name in players.keys {
            players[name]?.hp = settings.maxHP
            players[name]?.isAlive = true
        }
        phase = .lobby
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
        dummyInvulnerableUntil = nil
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
        dummyInvulnerableUntil = nil
    }

    /// Victim-side logic, played locally: the dummy takes damage, dies, and
    /// respawns at a new bearing so you have to hunt for it.
    private func hitDummy() {
        guard var target = players[TargetDummy.name], target.isAlive else { return }
        // Unreachable while fireCooldown >= hitInvulnerability (you're the only
        // shooter here), but it keeps practice honest if either is retuned.
        let now = Date()
        if let until = dummyInvulnerableUntil, now < until { return }
        dummyInvulnerableUntil = now.addingTimeInterval(settings.hitInvulnerability)
        target.hp = max(0, target.hp - settings.damage)
        confirmHit()
        if target.hp <= 0 {
            target.isAlive = false
            target.deaths += 1
            players[myName]?.kills += 1
            killFeed.insert(KillEvent(killer: myName, victim: TargetDummy.name), at: 0)
            trimFeed()
            confirmHit(kill: true)
            dummy.relocate()
            DispatchQueue.main.asyncAfter(deadline: .now() + settings.respawnDelay) { [weak self] in
                guard let self, self.phase == .playing,
                      var revived = self.players[TargetDummy.name] else { return }
                revived.hp = self.settings.maxHP
                revived.isAlive = true
                self.dummyInvulnerableUntil = Date().addingTimeInterval(self.settings.spawnProtection)
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
        // A snapshot is the one path that can resurrect a spectator: whoever
        // built it may have added the Mac as a player in peerDidConnect before
        // its .spectatorHello landed, and every receiver would then recreate it
        // as a shootable target even after correctly removing it.
        guard !spectators.contains(state.name) else { return }
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
        matchTimer?.invalidate()
        matchTimer = nil
        matchDeadline = nil
        matchRemaining = 0
        cancelReload()
    }
}

// MARK: - NetworkManagerDelegate

extension GameEngine: NetworkManagerDelegate {
    func network(_ manager: NetworkManager, peerDidConnect peer: MCPeerID) {
        guard manager === network else { return }   // stale callbacks after leave()
        let name = peer.displayName
        if spectators.contains(name) {
            // A reconnecting spectator never becomes a player row.
        } else if players[name] == nil {
            players[name] = Player(name: name, hp: settings.maxHP)
        } else {
            players[name]?.isConnected = true       // reconnect: keep their stats
        }
        manager.send(isSpectator ? .spectatorHello : .hello(playerName: myName), to: [peer])
        if phase == .playing {
            if !isSpectator { despawnDummy() }   // a real target arrived — practice is over
            // Late joiner or reconnect mid-match: sync settings + full state
            // (host), our own authoritative row (everyone), and pair up UWB.
            // .reliable unicasts to one peer stay ordered, so the snapshot
            // lands after .startGame on their side.
            if isHost {
                manager.send(.startGame(settings: settings), to: [peer])
                manager.send(.stateSnapshot(players.values.map(PlayerState.init)), to: [peer])
                // Their clock would otherwise start a full match length from now.
                if let deadline = matchDeadline {
                    manager.send(.matchClock(remaining: max(0, deadline.timeIntervalSinceNow)), to: [peer])
                }
            } else if let mine = me {
                manager.send(.stateSnapshot([PlayerState(mine)]), to: [peer])
            }
            if !isSpectator, !spectators.contains(name),
               let data = ranging.prepare(peerName: name) {
                manager.send(.discoveryToken(data), to: [peer])
            }
        }
    }

    func network(_ manager: NetworkManager, peerDidDisconnect peer: MCPeerID) {
        guard manager === network else { return }
        let name = peer.displayName
        if name == externalHostName { clearExternalMatch() }   // its match can't hold our lock
        if phase == .playing, players[name] != nil {
            // Might be a transient blip — keep stats so reconnect doesn't
            // resurrect them at full HP with zeroed kills.
            players[name]?.isConnected = false
        } else {
            players[name] = nil
        }
        ranging.removePeer(name)
        if streamingTo == peer {
            streamingTo = nil
            camera.frameTap = nil
        }
        if watchingPlayer == name {
            watchingPlayer = nil
            spectatorFrame = nil
        }
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
            let fromSpectator = spectators.contains(peer.displayName)
            if phase == .playing {
                if fromSpectator, isHost, !isSpectator {
                    // The game master started a real match while we were host
                    // of a stale one (typically abandoned solo practice) —
                    // ours yields and we join theirs.
                    isHost = false
                    beginMatch(with: settings)
                } else if !isHost {
                    // Late-join/reconnect resync; don't reset the match. A
                    // host ignores it — its own settings are authoritative,
                    // and a rival's broadcast must not rewrite a live match.
                    self.settings = settings
                }
            } else {
                // The game master (spectator-host) is never dragged into
                // someone else's match — it opens on its setup screen and
                // starts matches itself. Note who runs the live match; the
                // snapshot that follows tells us whether it's a real game
                // (2+ players, locks our setup) or abandoned solo practice.
                if isSpectator, isHost {
                    externalHostName = peer.displayName
                    return
                }
                // Someone else's match is starting — whoever started it calls
                // time. Without dropping the flag, a lobby host pulled into a
                // running match would broadcast rival .endMatch tallies when
                // its own clock hit zero.
                isHost = false
                beginMatch(with: settings)
            }

        case .stateSnapshot(let states):
            if phase == .playing {
                states.forEach(apply)
            } else {
                if isSpectator, isHost, peer.displayName == externalHostName {
                    externalMatchPlayers = states.count
                }
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
            if killedBy == myName { confirmHit(kill: true) }

        case .respawn(let player):
            guard player != myName else { return }
            players[player]?.hp = settings.maxHP
            players[player]?.isAlive = true

        case .endMatch(let finalStates):
            if externalMatchInProgress, peer.displayName == externalHostName {
                clearExternalMatch()   // the running game ended; setup unlocks
                return
            }
            guard phase == .playing else { return }
            // Host's tallies are authoritative for the summary; fall back to
            // our own row if the host somehow never saw us.
            var finals = finalStates.map { state -> Player in
                var player = players[state.name] ?? Player(name: state.name, hp: state.hp)
                player.hp = state.hp
                player.isAlive = state.isAlive
                player.kills = state.kills
                player.deaths = state.deaths
                return player
            }
            if !finals.contains(where: { $0.name == myName }), let mine = me {
                finals.append(mine)
            }
            endMatch(with: finals)

        case .matchClock(let remaining):
            guard phase == .playing, !isHost else { return }
            startMatchClock(seconds: remaining)

        case .spectatorHello:
            // Not a combatant: no roster row, no HP, no UWB session, can't be shot.
            spectators.insert(peer.displayName)
            players[peer.displayName] = nil
            ranging.removePeer(peer.displayName)

        case .cameraRequest(let active):
            if active {
                streamingTo = peer
                camera.start()   // idempotent; covers a lobby preview request
                camera.frameTap = { [weak self] jpeg in
                    guard let self, let target = self.streamingTo else { return }
                    self.network?.sendCameraFrame(jpeg, to: target)
                }
            } else if streamingTo == peer {
                streamingTo = nil
                camera.frameTap = nil
            }

        case .hostEnded:
            guard !isHost else {
                // Two hosts: don't let one kick the other — but a phone host
                // shutting down does unlock the game master's setup screen.
                if peer.displayName == externalHostName { clearExternalMatch() }
                return
            }
            leave()
            hostEndedNotice = "The host ended the game."
        }
    }

    func network(_ manager: NetworkManager, didReceiveCameraFrame jpeg: Data, from peer: MCPeerID) {
        guard manager === network, isSpectator,
              peer.displayName == watchingPlayer,
              let image = UIImage(data: jpeg) else { return }
        spectatorFrame = image
    }
}

// MARK: - RangingManagerDelegate

extension GameEngine: RangingManagerDelegate {
    func ranging(_ manager: RangingManager, resendToken tokenData: Data, to peerName: String) {
        guard let net = network, let peer = net.peer(named: peerName) else { return }
        net.send(.discoveryToken(tokenData), to: [peer])
    }

    func ranging(_ manager: RangingManager, raiseAlert reason: String, forPeer peerName: String?) {
        rangingAlert = reason
        rangingAlertPeer = peerName
    }

    func ranging(_ manager: RangingManager, clearAlertForPeer peerName: String) {
        // A device-wide alert (permission, camera access) can't be dismissed
        // by one peer's recovery — only per-peer alerts clear here.
        guard rangingAlertPeer == peerName else { return }
        rangingAlert = nil
        rangingAlertPeer = nil
    }
}
